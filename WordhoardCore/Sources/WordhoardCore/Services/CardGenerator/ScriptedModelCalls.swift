import Foundation
import Synchronization

/// A `ModelCalls` for tests: every method answers from a `Script` closure and records the call.
///
/// **Isolation: none.** A `Sendable` class whose recorded calls and in-flight counts sit behind a
/// `Mutex`, so tests read them synchronously. A script closure throws `ModelCallError` to play a refusal or a failure
/// for
/// exactly the call it recognises (by headword, gloss, definition or topic); everything else answers.
/// Anything else a closure throws (not a `ModelCallError`) passes through, like cancellation would.
public final class ScriptedModelCalls: ModelCalls {
    /// One recorded call, with everything the generator passed.
    public enum Call: Equatable, Sendable {
        case proposeSenses(headword: String, wordClass: FunctionWordClass?)
        case verify(headword: String, sense: ProposedSense, wordClass: FunctionWordClass?)
        case selectSenses(headword: String, candidates: [WordNetSense])
        case writeDefinition(headword: String, sense: WordNetSense)
        case proposeTranslation(headword: String, sense: GeneratedSense, nativeLanguage: String)
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
            case .selectSenses: .selectSenses
            case .writeDefinition: .writeDefinition
            case .proposeTranslation: .proposeTranslation
            case .writeExample: .writeExample
            }
        }
    }

    public enum Method: Hashable, Sendable {
        case proposeSenses
        case verify
        case selectSenses
        case writeDefinition
        case proposeTranslation
        case writeExample
    }

    /// The answers. Defaults: no proposed senses, every verdict yes, the first four candidates (rank 1
    /// of every part of speech first, as the round-robin lists them), `"def:<gloss>"`, the proposal
    /// `"<native>:<headword>"` (it contains the headword, so the generator rejects it and falls back
    /// to the translated definition; script a native word and a `StubTranslator` table to accept one),
    /// `"I <part of speech> the <headword>"` for every example (it contains the headword, so the
    /// generator's headword check passes). The example closure's last argument is `mustContainHeadword`.
    public struct Script: Sendable {
        public var proposeSenses: @Sendable (_ headword: String) throws -> [ProposedSense]
        public var verify: @Sendable (_ headword: String, _ sense: ProposedSense) throws -> Bool
        public var selectSenses: @Sendable (_ headword: String, _ candidates: [WordNetSense]) throws -> [Int]
        public var writeDefinition: @Sendable (_ headword: String, _ sense: WordNetSense) throws -> String
        public var proposeTranslation: @Sendable (
            _ headword: String,
            _ sense: GeneratedSense,
            _ nativeLanguage: String
        ) throws -> String
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
            selectSenses: @escaping @Sendable (String, [WordNetSense]) throws -> [Int] = { _, candidates in
                Array(candidates.indices.prefix(4))
            },
            writeDefinition: @escaping @Sendable (String, WordNetSense) throws -> String = { _, sense in
                "def:\(sense.gloss)"
            },
            proposeTranslation: @escaping @Sendable (String, GeneratedSense, String) throws
                -> String = { headword, _, nativeLanguage in
                    "\(nativeLanguage):\(headword)"
                },
            writeExample: @escaping @Sendable (String, PartOfSpeech, String, GrammarTopic?, Bool) throws
                -> ExampleAnswer = { headword, partOfSpeech, _, _, _ in
                    .text("I \(partOfSpeech.rawValue) the \(headword)")
                }
        ) {
            self.proposeSenses = proposeSenses
            self.verify = verify
            self.selectSenses = selectSenses
            self.writeDefinition = writeDefinition
            self.proposeTranslation = proposeTranslation
            self.writeExample = writeExample
        }
    }

    private let storedAvailability: CardGeneratorAvailability
    private let script: Script
    private let delay: Duration
    private let delays: [Method: Duration]
    private let state = Mutex(State())

    private struct State {
        var calls: [Call] = []
        var inFlight: [Method: Int] = [:]
        var maxInFlight: [Method: Int] = [:]
    }

    /// `delay` is slept in every call (after it is recorded), so a test can cancel mid-stream;
    /// `delays` overrides it per method (plan 2.8: only `writeExample` slow).
    public init(
        availability: CardGeneratorAvailability = .available,
        script: Script = Script(),
        delay: Duration = .zero,
        delays: [Method: Duration] = [:]
    ) {
        storedAvailability = availability
        self.script = script
        self.delay = delay
        self.delays = delays
    }

    /// Every call, in order of start.
    public var calls: [Call] {
        state.withLock(\.calls)
    }

    /// The most calls of `method` that were in flight at once (plan 2.8).
    public func maxInFlight(_ method: Method) -> Int {
        state.withLock { $0.maxInFlight[method] ?? 0 }
    }

    /// The recorded calls of one method, in order.
    public func calls(_ method: Method) -> [Call] {
        calls.filter { $0.method == method }
    }

    public func availability() async -> CardGeneratorAvailability {
        storedAvailability
    }

    public func proposeSenses(headword: String, wordClass: FunctionWordClass?) async throws -> [ProposedSense] {
        try await perform(.proposeSenses(headword: headword, wordClass: wordClass)) {
            try script.proposeSenses(headword)
        }
    }

    public func verify(headword: String, sense: ProposedSense, wordClass: FunctionWordClass?) async throws -> Bool {
        try await perform(.verify(headword: headword, sense: sense, wordClass: wordClass)) {
            try script.verify(headword, sense)
        }
    }

    public func selectSenses(headword: String, candidates: [WordNetSense]) async throws -> [Int] {
        try await perform(.selectSenses(headword: headword, candidates: candidates)) {
            try script.selectSenses(headword, candidates)
        }
    }

    public func writeDefinition(headword: String, sense: WordNetSense) async throws -> String {
        try await perform(.writeDefinition(headword: headword, sense: sense)) {
            try script.writeDefinition(headword, sense)
        }
    }

    public func proposeTranslation(
        headword: String,
        sense: GeneratedSense,
        nativeLanguage: String
    ) async throws -> String {
        try await perform(.proposeTranslation(headword: headword, sense: sense, nativeLanguage: nativeLanguage)) {
            try script.proposeTranslation(headword, sense, nativeLanguage)
        }
    }

    public func writeExample(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?,
        mustContainHeadword: Bool
    ) async throws -> ExampleAnswer {
        try await perform(.writeExample(
            headword: headword,
            partOfSpeech: partOfSpeech,
            definition: definition,
            topic: topic,
            mustContainHeadword: mustContainHeadword
        )) {
            try script.writeExample(headword, partOfSpeech, definition, topic, mustContainHeadword)
        }
    }

    /// Records the call and counts it in flight, sleeps its delay (a cancelled sleep throws
    /// `CancellationError`, as the real call would), answers, and counts it out again.
    private func perform<Answer>(_ call: Call, answer: () throws -> Answer) async throws -> Answer {
        state.withLock { state in
            state.calls.append(call)
            let inFlight = state.inFlight[call.method, default: 0] + 1
            state.inFlight[call.method] = inFlight
            state.maxInFlight[call.method] = max(state.maxInFlight[call.method] ?? 0, inFlight)
        }
        defer {
            state.withLock { $0.inFlight[call.method, default: 1] -= 1 }
        }
        let wait = delays[call.method] ?? delay
        if wait > .zero {
            try await Task.sleep(for: wait)
        }
        return try answer()
    }
}
