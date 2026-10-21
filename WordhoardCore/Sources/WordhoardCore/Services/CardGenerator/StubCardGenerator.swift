import Foundation
import Synchronization

/// A fixture-driven `CardGenerator` for tests and for the app under `--ui-testing` (2.3).
///
/// **Isolation: none.** A `Sendable` class whose mutable state (recorded requests, fixtures, overrides)
/// sits behind a `Mutex`, so tests read `requests` synchronously and set overrides without `await`.
/// `generateCard` answers from `fixtures` by `Word.normalize(headword)`; a miss returns `fallback`
/// with `StubFixtures.headwordPlaceholder` replaced by the normalized headword, or throws
/// `.failed("no fixture")` when there is no fallback. `delay` is honoured once per stage so a UI test
/// can see the `filling` state.
public final class StubCardGenerator: CardGenerator {
    /// A (sense, topic) slot of the topic-example stream.
    public struct SenseTopic: Hashable, Sendable {
        public var senseIndex: Int
        public var topic: GrammarTopicID

        public init(_ senseIndex: Int, _ topic: GrammarTopicID) {
            self.senseIndex = senseIndex
            self.topic = topic
        }
    }

    /// What the stream does for one slot instead of the default `"<headword> example for <topic>."`.
    public enum TopicExampleOverride: Equatable, Sendable {
        /// Yield nothing for this slot, like a model answering "does not fit".
        case doesNotFit
        /// Yield this text, with the requested key.
        case text(String)
        /// Finish the stream with this error when the slot is reached, after the examples before it.
        case failure(CardGeneratorError)
    }

    private struct State {
        var fixtures: [String: GeneratedCard]
        var fallback: GeneratedCard?
        var requests: [CardRequest] = []
        var topicRequests: [CardRequest] = []
        var topicExampleOverrides: [SenseTopic: TopicExampleOverride] = [:]
    }

    private let state: Mutex<State>
    private let storedAvailability: CardGeneratorAvailability
    private let delay: Duration

    public init(
        fixtures: [String: GeneratedCard] = StubFixtures.cards,
        fallback: GeneratedCard? = StubFixtures.generic,
        availability: CardGeneratorAvailability = .available,
        delay: Duration = .zero
    ) {
        state = Mutex(State(fixtures: fixtures, fallback: fallback))
        storedAvailability = availability
        self.delay = delay
    }

    /// Every `generateCard` request, in call order; appended before the delay.
    public var requests: [CardRequest] {
        state.withLock(\.requests)
    }

    /// Every `generateTopicExamples` request, in call order; appended when the stream starts.
    public var topicRequests: [CardRequest] {
        state.withLock(\.topicRequests)
    }

    /// Cards by normalized headword. Replaceable, so a test can change what a retry (2.5) returns.
    public var fixtures: [String: GeneratedCard] {
        get { state.withLock(\.fixtures) }
        set { state.withLock { $0.fixtures = newValue } }
    }

    /// Per-slot behaviour of the topic-example stream; set by tests, read when the slot is reached.
    public var topicExampleOverrides: [SenseTopic: TopicExampleOverride] {
        get { state.withLock(\.topicExampleOverrides) }
        set { state.withLock { $0.topicExampleOverrides = newValue } }
    }

    public func availability() async -> CardGeneratorAvailability {
        storedAvailability
    }

    public func generateCard(_ request: CardRequest) async throws -> GeneratedCard {
        try throwIfUnavailable()
        let key = Word.normalize(request.headword)
        let (fixture, fallback) = state.withLock { state in
            state.requests.append(request)
            return (state.fixtures[key], state.fallback)
        }
        try await sleepIfDelayed()
        if let fixture {
            return fixture
        }
        guard let fallback else {
            throw CardGeneratorError.failed("no fixture")
        }
        return Self.rebuilt(fallback, headword: key)
    }

    public func generateTopicExamples(
        for card: GeneratedCard,
        request: CardRequest
    ) -> AsyncThrowingStream<GeneratedTopicExample, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try throwIfUnavailable()
                    state.withLock { $0.topicRequests.append(request) }
                    try await sleepIfDelayed()
                    try yieldTopicExamples(for: card, request: request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func yieldTopicExamples(
        for card: GeneratedCard,
        request: CardRequest,
        into continuation: AsyncThrowingStream<GeneratedTopicExample, any Error>.Continuation
    ) throws {
        for senseIndex in card.senses.indices {
            for topic in request.topics {
                try Task.checkCancellation()
                let override = state.withLock { $0.topicExampleOverrides[SenseTopic(senseIndex, topic.key)] }
                let text: String
                switch override {
                case .doesNotFit:
                    continue
                case let .text(custom):
                    text = custom
                case let .failure(error):
                    throw error
                case nil:
                    text = "\(card.headword) example for \(topic.name)."
                }
                continuation.yield(GeneratedTopicExample(
                    senseIndex: senseIndex,
                    example: GeneratedExample(text: text, grammarTopic: topic.key)
                ))
            }
        }
    }

    private func throwIfUnavailable() throws {
        if case let .unavailable(reason) = storedAvailability {
            throw CardGeneratorError.unavailable(reason)
        }
    }

    private func sleepIfDelayed() async throws {
        guard delay > .zero else { return }
        try await Task.sleep(for: delay)
    }

    /// `template` with every `StubFixtures.headwordPlaceholder` replaced by `headword`.
    private static func rebuilt(_ template: GeneratedCard, headword: String) -> GeneratedCard {
        func fill(_ text: String) -> String {
            text.replacingOccurrences(of: StubFixtures.headwordPlaceholder, with: headword)
        }
        var card = template
        card.headword = fill(card.headword)
        card.senses = card.senses.map { sense in
            var sense = sense
            sense.gloss = sense.gloss.map(fill)
            sense.definition = fill(sense.definition)
            sense.translation = sense.translation.map(fill)
            sense.synonyms = sense.synonyms.map(fill)
            sense.antonyms = sense.antonyms.map(fill)
            sense.neutralExample = sense.neutralExample.map { example in
                GeneratedExample(text: fill(example.text), grammarTopic: example.grammarTopic)
            }
            return sense
        }
        return card
    }
}
