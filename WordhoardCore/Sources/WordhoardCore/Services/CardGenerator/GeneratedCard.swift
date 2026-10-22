import Foundation

/// The first card as a generator produced it (requirements A1, A2, A6). Plain values: the merge into
/// `Word` (plan 2.4) maps `GeneratedSense` onto `Sense` by `senseSource` + `gloss`.
public struct GeneratedCard: Equatable, Sendable {
    public var headword: String
    public var path: GenerationPath
    /// `path == .notFound` ⇔ `senses.isEmpty`: nothing was invented (A1).
    public var senses: [GeneratedSense]
    /// Per-field degradation records, so the card and the regression runner can show what was skipped.
    public var notes: [GenerationNote]

    public init(headword: String, path: GenerationPath, senses: [GeneratedSense], notes: [GenerationNote] = []) {
        self.headword = headword
        self.path = path
        self.senses = senses
        self.notes = notes
    }
}

/// Which route the sense inventory took (ADR 0001 point 1). Recorded by the regression runner.
public enum GenerationPath: String, Equatable, Sendable {
    /// WordNet knows the lemma; its senses are the only senses.
    case wordnet
    /// A function word from the stoplist: model-only senses, verified.
    case stoplist
    /// WordNet lacks the lemma: model-only senses, verified.
    case modelOnly
    /// Every proposed sense was rejected (or the lemma is nonsense): a success with no senses.
    case notFound
}

/// One sense of the first card.
public struct GeneratedSense: Equatable, Sendable {
    public var partOfSpeech: PartOfSpeech
    /// `.wordnet` or `.model`; never nil for a generated sense (a nil `Sense.senseSource` means hand-entered).
    public var senseSource: SenseSource
    /// The WordNet gloss; nil for model senses.
    public var gloss: String?
    public var definition: String
    /// nil: no native language, pack missing, or not translated. Never unverified model text (A9): a
    /// model proposal lands here only after the framework's back-translation confirmed it (plan 2.10).
    public var translation: String?
    /// `true` when `translation` is the framework's translation of the definition because the proposed
    /// equivalent was rejected or could not be written (plan 2.10).
    public var translationIsFallback: Bool
    public var synonyms: [String]
    public var antonyms: [String]
    /// nil only after a refusal or a drop (A6, 2.9); see `GenerationNote.exampleRefused` / `.exampleDropped`.
    public var neutralExample: GeneratedExample?

    public init(
        partOfSpeech: PartOfSpeech,
        senseSource: SenseSource,
        gloss: String?,
        definition: String,
        translation: String?,
        translationIsFallback: Bool = false,
        synonyms: [String],
        antonyms: [String],
        neutralExample: GeneratedExample?
    ) {
        self.partOfSpeech = partOfSpeech
        self.senseSource = senseSource
        self.gloss = gloss
        self.definition = definition
        self.translation = translation
        self.translationIsFallback = translationIsFallback
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.neutralExample = neutralExample
    }
}

/// One example sentence. `grammarTopic == nil` is the neutral example.
public struct GeneratedExample: Equatable, Sendable {
    public var text: String
    public var grammarTopic: GrammarTopicID?

    public init(text: String, grammarTopic: GrammarTopicID?) {
        self.text = text
        self.grammarTopic = grammarTopic
    }
}

/// A stage-2 example addressed to `card.senses[senseIndex]`.
public struct GeneratedTopicExample: Equatable, Sendable {
    public var senseIndex: Int
    public var example: GeneratedExample

    public init(senseIndex: Int, example: GeneratedExample) {
        self.senseIndex = senseIndex
        self.example = example
    }
}

/// A field the generator could not fill (A6).
public enum GenerationNote: Equatable, Sendable {
    /// The sense-selection call (plan 2.6) failed or answered nothing usable; the senses are the
    /// 2-per-part-of-speech fallback (`WordNetLookup.select`).
    case senseSelectionFellBack
    /// The definition call was refused; the gloss is kept as the definition.
    case definitionRefused(senseIndex: Int)
    /// That example was skipped: the call was refused or failed, or the model said the sense does not
    /// fit; `topic == nil` is the neutral example.
    case exampleRefused(senseIndex: Int, topic: GrammarTopicID?)
    /// That example was written twice without the headword and dropped (2.9); `topic == nil` is the
    /// neutral example. Topic examples are not on the card when they drop, so only neutral ones occur.
    case exampleDropped(senseIndex: Int, topic: GrammarTopicID?)
    /// The language pack is not installed (or a batch failed); those translations are nil.
    case translationUnavailable(language: String)
    /// That sense's proposed equivalent was rejected by back-translation (`rejectedProposal` is the
    /// model's text, for the regression runner; `nil` when the proposal call was refused or failed), so
    /// its translation is the translated definition, flagged `translationIsFallback` (plan 2.10).
    case translationFallback(senseIndex: Int, rejectedProposal: String?)
}
