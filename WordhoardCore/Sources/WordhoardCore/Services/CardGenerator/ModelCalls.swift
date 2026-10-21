import Foundation

/// The five typed calls the generator makes to the language model (ADR 0001 point 2), so the pipeline
/// above them is unit-tested with `ScriptedModelCalls` and never the real model.
///
/// Every call is for one headword and, except `proposeSenses`, for one sense: no call writes prose
/// for more than one sense. Later tasks add methods here (`selectSenses` 2.6, `proposeTranslation` 2.10).
public protocol ModelCalls: Sendable {
    /// Whether the model can be called right now; the generator checks it before any other method.
    func availability() async -> CardGeneratorAvailability

    /// Model-only path: 1…3 proposed senses for a headword WordNet cannot serve. No examples.
    func proposeSenses(headword: String) async throws -> [ProposedSense]

    /// Yes/no: is the headword commonly used with this part of speech and meaning?
    func verify(headword: String, sense: ProposedSense) async throws -> Bool

    /// WordNet path: the learner definition for one WordNet sense, written from gloss + synonyms + example.
    func writeDefinition(headword: String, sense: WordNetSense) async throws -> String

    /// One example sentence for one sense; `topic == nil` is the neutral example.
    func writeExample(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?
    ) async throws -> ExampleAnswer
}

/// A sense the model proposed on the model-only path, before verification.
public struct ProposedSense: Equatable, Sendable {
    public var partOfSpeech: PartOfSpeech
    public var definition: String
    public var synonyms: [String]
    public var antonyms: [String]

    public init(partOfSpeech: PartOfSpeech, definition: String, synonyms: [String] = [], antonyms: [String] = []) {
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.synonyms = synonyms
        self.antonyms = antonyms
    }
}

/// What an example call answers.
public enum ExampleAnswer: Equatable, Sendable {
    /// A sentence, trimmed.
    case text(String)
    /// The sense cannot use this grammar naturally (an empty answer in 2.2; plan 2.9 types it).
    case doesNotFit
}

/// How a model call fails. Cancellation is not a `ModelCallError`: `CancellationError` passes through.
public enum ModelCallError: Error, Equatable, Sendable {
    /// The guardrail refused the request or the model declined to answer (`LanguageModelError`
    /// `.guardrailViolation` / `.refusal`). The generator degrades the field it was for (A6).
    case refused
    /// Anything else, with a one-line description for the log.
    case failed(String)
}
