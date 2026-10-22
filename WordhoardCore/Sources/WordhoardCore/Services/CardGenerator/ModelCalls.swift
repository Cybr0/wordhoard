import Foundation

/// The typed calls the generator makes to the language model (ADR 0001 point 2), so the pipeline
/// above them is unit-tested with `ScriptedModelCalls` and never the real model.
///
/// Every call is for one headword and, except `proposeSenses` and `selectSenses`, for one sense: no
/// call writes prose for more than one sense.
public protocol ModelCalls: Sendable {
    /// Whether the model can be called right now; the generator checks it before any other method.
    func availability() async -> CardGeneratorAvailability

    /// Model-only path: 1…3 proposed senses for a headword WordNet cannot serve. No examples.
    /// `wordClass` is the stoplist section of a function word, stated as a hint in the prompt (2.7).
    func proposeSenses(headword: String, wordClass: FunctionWordClass?) async throws -> [ProposedSense]

    /// Yes/no: is the headword commonly used with this part of speech and meaning? Same `wordClass` hint.
    func verify(headword: String, sense: ProposedSense, wordClass: FunctionWordClass?) async throws -> Bool

    /// WordNet path, only when the lemma has more than four bundled senses (plan 2.6): the 0-based
    /// indices into `candidates` of the ≤ 4 senses a learner's dictionary would list first, in the
    /// model's order. Unchecked: the caller drops invalid indices and guarantees part-of-speech coverage.
    func selectSenses(headword: String, candidates: [WordNetSense]) async throws -> [Int]

    /// WordNet path: the learner definition for one WordNet sense, written from gloss + synonyms + example.
    func writeDefinition(headword: String, sense: WordNetSense) async throws -> String

    /// One example sentence for one sense; `topic == nil` is the neutral example. `mustContainHeadword`
    /// is the generator's one retry after the first sentence lacked the headword (2.9).
    func writeExample(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?,
        mustContainHeadword: Bool
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
    /// The sense cannot use this grammar naturally: the model set `fits` to false (plan 2.9).
    case doesNotFit

    /// The model's typed reply as the seam sees it: `fits == false` **or** a blank `text` is
    /// `.doesNotFit` (belt and braces), anything else `.text(trimmed)`.
    public init(fits: Bool, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self = fits && !trimmed.isEmpty ? .text(trimmed) : .doesNotFit
    }
}

/// How a model call fails. Cancellation is not a `ModelCallError`: `CancellationError` passes through.
public enum ModelCallError: Error, Equatable, Sendable {
    /// The guardrail refused the request or the model declined to answer (`LanguageModelError`
    /// `.guardrailViolation` / `.refusal`). The generator degrades the field it was for (A6).
    case refused
    /// Anything else, with a one-line description for the log.
    case failed(String)
}
