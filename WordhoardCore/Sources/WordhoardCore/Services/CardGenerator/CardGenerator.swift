import Foundation

/// The seam between the app and whatever writes a card (requirements A8, ADR 0001).
///
/// Two stages, so the queue (plan 2.3) can persist the *first card* before any topic example exists:
/// `generateCard` returns senses with a definition, translation, synonyms, antonyms and one neutral
/// example each (A2); `generateTopicExamples` then streams one example per sense × requested topic.
/// Per-field degradation is data on the card (`GenerationNote`, A6), never an error. No Foundation
/// Models, WordNet, Translation or SwiftData type appears in any signature: the generator never sees
/// a stored word, and tests drive everything above it with `StubCardGenerator`.
public protocol CardGenerator: Sendable {
    /// Checked by the queue (2.3) before a call and by the card (2.5) before offering "Fill in".
    /// `async` so a real implementation may read the system model's availability off the main actor.
    func availability() async -> CardGeneratorAvailability

    /// Stage 1, the "first card": senses with definition, translation, synonyms, antonyms and one
    /// neutral example each. Returns when every sense has been written; no topic examples yet.
    /// Throws `CardGeneratorError`; a `path == .notFound` card with no senses is a success (A1).
    func generateCard(_ request: CardRequest) async throws -> GeneratedCard

    /// Stage 2: one example per (sense, requested topic), yielded as each completes, in any order.
    /// `senseIndex` indexes `card.senses`. A sense/topic the model says does not fit yields nothing.
    /// The example's `grammarTopic` is always the requested key, never the model's guess.
    func generateTopicExamples(
        for card: GeneratedCard,
        request: CardRequest
    ) -> AsyncThrowingStream<GeneratedTopicExample, any Error>
}

/// Whether a generator can be called right now (requirements §6, availability fallback).
public enum CardGeneratorAvailability: Equatable, Sendable {
    case available
    case unavailable(UnavailableReason)

    /// Mirrors the system model's reasons so the card (2.3/2.5) can explain in one line.
    public enum UnavailableReason: String, Sendable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }
}

/// What a `CardGenerator` call can fail with.
public enum CardGeneratorError: Error, Equatable, Sendable {
    /// The model is not available; nothing was called. Card state becomes `unavailable` (2.3).
    case unavailable(CardGeneratorAvailability.UnavailableReason)
    /// A call the card cannot do without was refused by the guardrail (the model-only senses call).
    /// A refused *field* is never an error: it is a `GenerationNote` on a card that is still produced (A6).
    case refused
    /// Anything else, with a one-line description for the log and the `failed` card state.
    case failed(String)
}

/// Everything a generator needs for one word.
///
/// `topics` are resolved `GrammarTopic`s (name and description for the prompt), not keys: the caller
/// (2.3) resolves `UserSettings.activeGrammarTopics` through `GrammarCatalog.english.topic(for:)` and
/// drops unknown keys, so the generator never touches the catalog. `nativeLanguage` is a BCP-47 tag
/// from `UserSettings.nativeLanguage`; `nil` means no translation step at all (A9).
public struct CardRequest: Equatable, Sendable {
    public var headword: String
    public var nativeLanguage: String?
    public var topics: [GrammarTopic]

    public init(headword: String, nativeLanguage: String?, topics: [GrammarTopic]) {
        self.headword = headword
        self.nativeLanguage = nativeLanguage
        self.topics = topics
    }
}
