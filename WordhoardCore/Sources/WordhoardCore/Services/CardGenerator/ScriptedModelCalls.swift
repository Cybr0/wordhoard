import Foundation
import Synchronization

/// A `ModelCalls` for tests: every method answers from a `Script` closure and records the call.
///
/// **Isolation: none.** A `Sendable` class whose recorded calls sit behind a `Mutex`, so tests read
/// them synchronously. A script closure throws `ModelCallError` to play a refusal or a failure for
/// exactly the call it recognises (by headword, gloss, definition or topic); everything else answers.
/// Anything else a closure throws (not a `ModelCallError`) passes through, like cancellation would.
public final class ScriptedModelCalls: ModelCalls {
    /// One recorded call, with everything the generator passed.
    public enum Call: Equatable, Sendable {
        case proposeSenses(headword: String, wordClass: FunctionWordClass?)
        case verify(headword: String, sense: ProposedSense, wordClass: FunctionWordClass?)
        case writeDefinition(headword: String, sense: WordNetSense)
        case writeExample(
            headword: String,
            partOfSpeech: PartOfSpeech,
            definition: String,
            topic: GrammarTopic?,
            mustContainHeadword: Bool
        )

        /// The method name, for counting.
        public var method: Method {
            switch self {
            case .proposeSenses: .proposeSenses
            case .verify: .verify
            case .writeDefinition: .writeDefinition
            case .writeExample: .writeExample
            }
        }
    }

    public enum Method: Equatable, Sendable {
        case proposeSenses
        case verify
        case writeDefinition
        case writeExample
    }

    /// The answers. Defaults: no proposed senses, every verdict yes, `"def:<gloss>"`,
    /// `"I <part of speech> the <headword>"` for every example (it contains the headword, so the
    /// generator's headword check passes). The example closure's last argument is `mustContainHeadword`.
    public struct Script: Sendable {
        public var proposeSenses: @Sendable (_ headword: String) throws -> [ProposedSense]
        public var verify: @Sendable (_ headword: String, _ sense: ProposedSense) throws -> Bool
        public var writeDefinition: @Sendable (_ headword: String, _ sense: WordNetSense) throws -> String
        public var writeExample: @Sendable (
            _ headword: String,
            _ partOfSpeech: PartOfSpeech,
            _ definition: String,
            _ topic: GrammarTopic?,
            _ mustContainHeadword: Bool
        ) throws -> ExampleAnswer

        public init(
            proposeSenses: @escaping @Sendable (String) throws -> [ProposedSense] = { _ in [] },
            verify: @escaping @Sendable (String, ProposedSense) throws -> Bool = { _, _ in true },
            writeDefinition: @escaping @Sendable (String, WordNetSense) throws -> String = { _, sense in
                "def:\(sense.gloss)"
            },
            writeExample: @escaping @Sendable (String, PartOfSpeech, String, GrammarTopic?, Bool) throws
                -> ExampleAnswer = { headword, partOfSpeech, _, _, _ in
                    .text("I \(partOfSpeech.rawValue) the \(headword)")
                }
        ) {
            self.proposeSenses = proposeSenses
            self.verify = verify
            self.writeDefinition = writeDefinition
            self.writeExample = writeExample
        }
    }

    private let storedAvailability: CardGeneratorAvailability
    private let script: Script
    private let delay: Duration
    private let recorded = Mutex<[Call]>([])

    /// `delay` is slept before every call (after it is recorded), so a test can cancel mid-stream.
    public init(
        availability: CardGeneratorAvailability = .available,
        script: Script = Script(),
        delay: Duration = .zero
    ) {
        storedAvailability = availability
        self.script = script
        self.delay = delay
    }

    /// Every call, in order.
    public var calls: [Call] {
        recorded.withLock { $0 }
    }

    /// The recorded calls of one method, in order.
    public func calls(_ method: Method) -> [Call] {
        calls.filter { $0.method == method }
    }

    public func availability() async -> CardGeneratorAvailability {
        storedAvailability
    }

    public func proposeSenses(headword: String, wordClass: FunctionWordClass?) async throws -> [ProposedSense] {
        try await record(.proposeSenses(headword: headword, wordClass: wordClass))
        return try script.proposeSenses(headword)
    }

    public func verify(headword: String, sense: ProposedSense, wordClass: FunctionWordClass?) async throws -> Bool {
        try await record(.verify(headword: headword, sense: sense, wordClass: wordClass))
        return try script.verify(headword, sense)
    }

    public func writeDefinition(headword: String, sense: WordNetSense) async throws -> String {
        try await record(.writeDefinition(headword: headword, sense: sense))
        return try script.writeDefinition(headword, sense)
    }

    public func writeExample(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?,
        mustContainHeadword: Bool
    ) async throws -> ExampleAnswer {
        try await record(.writeExample(
            headword: headword,
            partOfSpeech: partOfSpeech,
            definition: definition,
            topic: topic,
            mustContainHeadword: mustContainHeadword
        ))
        return try script.writeExample(headword, partOfSpeech, definition, topic, mustContainHeadword)
    }

    /// Records, then sleeps `delay` (a cancelled sleep throws `CancellationError`, as the real call would).
    private func record(_ call: Call) async throws {
        recorded.withLock { $0.append(call) }
        guard delay > .zero else { return }
        try await Task.sleep(for: delay)
    }
}
