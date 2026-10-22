import Foundation

/// The example stages of `FoundationModelsCardGenerator` (A2, plans 2.8 and 2.9): the neutral example
/// of every sense before the first card returns, and the topic stream after it. Both run their calls
/// through `forEachConcurrently`, at most `maxConcurrentExampleCalls` in flight; every call is a fresh
/// session in `ModelCalls`, so no `LanguageModelSession` is ever shared. Results carry the sense index
/// (and topic) they were asked for, so completion order never changes where an example lands.
extension FoundationModelsCardGenerator {
    // MARK: - Step 6: neutral examples

    /// One example per sense through `requestExample`, applied in sense order once all are back.
    /// Refused, failed or "does not fit" → no example and `.exampleRefused`; written twice without the
    /// headword → no example and `.exampleDropped`; the card is still returned (A6).
    func writeNeutralExamples(_ card: inout GeneratedCard) async throws {
        let headword = card.headword
        var outcomes: [Int: ExampleOutcome] = [:]
        try await forEachConcurrently(Array(card.senses.enumerated())) { index, sense in
            try await (index, self.requestExample(headword: headword, sense: sense, topic: nil))
        } onResult: { index, outcome in
            outcomes[index] = outcome
        }
        for index in card.senses.indices {
            switch outcomes[index] {
            case let .text(text):
                card.senses[index].neutralExample = GeneratedExample(text: text, grammarTopic: nil)
            case .doesNotFit:
                Self.logger.notice("neutral example \(index, privacy: .public) came back as not fitting")
                card.notes.append(.exampleRefused(senseIndex: index, topic: nil))
            case let .failed(error):
                Self.logger.notice(
                    "neutral example \(index, privacy: .public) skipped: \(String(describing: error), privacy: .public)"
                )
                card.notes.append(.exampleRefused(senseIndex: index, topic: nil))
            case .dropped:
                Self.logger.notice("neutral example \(index, privacy: .public) dropped: no headword after a retry")
                card.notes.append(.exampleDropped(senseIndex: index, topic: nil))
            case nil:
                card.notes.append(.exampleRefused(senseIndex: index, topic: nil))
            }
        }
    }

    // MARK: - Stage 2: topic examples

    /// Every (sense, topic) slot exactly once, sense-major, `maxConcurrentExampleCalls` at a time;
    /// `yield` receives each example as its call completes. Cancellation stops the window: in-flight
    /// calls are cancelled and no new one starts.
    func streamTopicExamples(
        for card: GeneratedCard,
        request: CardRequest,
        yield: (GeneratedTopicExample) -> Void
    ) async throws {
        let headword = Self.trimmed(request.headword)
        let slots = card.senses.enumerated().flatMap { senseIndex, sense in
            request.topics.map { TopicSlot(senseIndex: senseIndex, sense: sense, topic: $0) }
        }
        try await forEachConcurrently(slots) { slot in
            try await self.topicExample(
                headword: headword, senseIndex: slot.senseIndex, sense: slot.sense, topic: slot.topic
            )
        } onResult: { example in
            if let example {
                yield(example)
            }
        }
    }

    /// One slot through `requestExample`; the example carries the requested key, never anything the
    /// model said. Anything but a sentence → nil, logged (the card is finished, so there is no note to
    /// attach it to).
    private func topicExample(
        headword: String,
        senseIndex: Int,
        sense: GeneratedSense,
        topic: GrammarTopic
    ) async throws -> GeneratedTopicExample? {
        switch try await requestExample(headword: headword, sense: sense, topic: topic) {
        case let .text(text):
            return GeneratedTopicExample(
                senseIndex: senseIndex,
                example: GeneratedExample(text: text, grammarTopic: topic.key)
            )
        case .doesNotFit:
            return nil
        case let .failed(error):
            Self.logger.notice(
                """
                topic example \(senseIndex, privacy: .public)/\(topic.key, privacy: .public) skipped: \
                \(String(describing: error), privacy: .public)
                """
            )
            return nil
        case .dropped:
            Self.logger.notice(
                "topic example \(senseIndex, privacy: .public)/\(topic.key, privacy: .public) dropped: no headword"
            )
            return nil
        }
    }

    // MARK: - One example, checked

    /// One `writeExample` call. A sentence without the headword (`HeadwordMatcher`) is asked for once
    /// more with the "must contain the word" line; a second miss drops it. `.doesNotFit` is final on
    /// either call. Cancellation passes through.
    private func requestExample(
        headword: String,
        sense: GeneratedSense,
        topic: GrammarTopic?
    ) async throws -> ExampleOutcome {
        do {
            for mustContainHeadword in [false, true] {
                try Task.checkCancellation()
                let answer = try await calls.writeExample(
                    headword: headword,
                    partOfSpeech: sense.partOfSpeech,
                    definition: sense.definition,
                    topic: topic,
                    mustContainHeadword: mustContainHeadword
                )
                guard case let .text(text) = answer else { return .doesNotFit }
                if HeadwordMatcher.contains(headword: headword, in: text) {
                    return .text(text)
                }
                let slot = topic?.key ?? "neutral"
                Self.logger.debug("example \(slot, privacy: .public) lacks the headword; retry \(mustContainHeadword)")
            }
            return .dropped
        } catch let error as ModelCallError {
            return .failed(error)
        }
    }

    // MARK: - The window

    /// Runs `work` for every item with at most `maxConcurrentExampleCalls` child tasks in flight,
    /// starting the next item as each one finishes, and hands every result to `onResult` in completion
    /// order on the calling task. A thrown error (cancellation included) cancels the remaining children
    /// and starts no new one.
    private func forEachConcurrently<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        work: @escaping @Sendable (Item) async throws -> Result,
        onResult: (Result) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Result.self) { group in
            var pending = items.makeIterator()
            for _ in 0 ..< maxConcurrentExampleCalls {
                guard let item = pending.next() else { break }
                group.addTask { try await work(item) }
            }
            while let result = try await group.next() {
                onResult(result)
                try Task.checkCancellation()
                if let item = pending.next() {
                    group.addTask { try await work(item) }
                }
            }
        }
    }
}

/// One (sense, topic) slot of the topic stream.
private struct TopicSlot: Sendable {
    var senseIndex: Int
    var sense: GeneratedSense
    var topic: GrammarTopic
}

/// How one example slot of `FoundationModelsCardGenerator` ended.
enum ExampleOutcome: Sendable {
    /// A sentence that contains the headword.
    case text(String)
    /// The model set `fits` to false; never retried.
    case doesNotFit
    /// Two sentences, neither with the headword (2.9).
    case dropped
    /// The call was refused or failed.
    case failed(ModelCallError)
}
