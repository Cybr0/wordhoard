import Foundation

/// One WordNet sense of a lemma, ready to be handed to the model for writing (ADR 0001 point 1).
public struct WordNetSense: Sendable, Equatable {
    public var partOfSpeech: PartOfSpeech
    /// The synset's `Definition` text: terse lexicographer English, kept as `Sense.gloss`.
    public var gloss: String
    /// The synset's other members, in WordNet order; never contains the lemma itself.
    public var synonyms: [String]
    public var antonyms: [String]
    /// The synset's first example sentence from the release, if any. It may use a synonym rather than
    /// the lemma; it goes into the writing prompt so a terse gloss is not misread.
    public var example: String?

    public init(partOfSpeech: PartOfSpeech, gloss: String, synonyms: [String], antonyms: [String], example: String?) {
        self.partOfSpeech = partOfSpeech
        self.gloss = gloss
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.example = example
    }
}

/// What the bundle knows about one lemma.
public struct WordNetEntry: Sendable, Equatable {
    /// Every bundled sense, nouns → verbs → adjectives → adverbs, WordNet rank within each part of speech.
    public var senses: [WordNetSense]
    /// `WordNetLookup.select(senses)`: the 2-per-part-of-speech / 4-in-all policy, the fallback when the
    /// selection call (plan 2.6) fails.
    public var selected: [WordNetSense]

    /// `WordNetLookup.candidates(senses)`: what the selection call is shown, round-robin by part of speech.
    public var candidates: [WordNetSense] {
        WordNetLookup.candidates(senses)
    }

    public init(senses: [WordNetSense], selected: [WordNetSense]) {
        self.senses = senses
        self.selected = selected
    }
}
