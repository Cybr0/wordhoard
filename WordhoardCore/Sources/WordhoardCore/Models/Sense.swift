import Foundation
import SwiftData

/// One meaning of a `Word`. Everything that depends on meaning hangs off this type (requirements §5).
@Model
public final class Sense {
    public var id: UUID = UUID()
    public var word: Word?
    public var partOfSpeech: PartOfSpeech = PartOfSpeech.other
    /// Where the sense came from; `nil` means it was entered by hand (W2) and gets no badge (W1).
    public var senseSource: SenseSource?
    /// The WordNet gloss the definition was written from, kept for regeneration and fallback (A6).
    public var gloss: String?
    public var definition: String = ""
    public var translation: String?
    /// `true` when `translation` is the framework's translation of the definition, not a verified
    /// 1–3-word equivalent (A9, plan 2.10); the card captions it. Cleared by any edit of the field.
    public var translationIsFallback: Bool = false
    public var synonyms: [String] = []
    public var antonyms: [String] = []
    /// Field name (`SenseField` raw value) → provenance. A missing key means `.auto` (A4).
    public var fieldSources: [String: FieldSource] = [:]
    /// Position within `Word.senses`; the relationship itself is unordered.
    public var order: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Example.sense)
    public var examples: [Example] = []

    public init(
        partOfSpeech: PartOfSpeech,
        definition: String = "",
        order: Int = 0,
        senseSource: SenseSource? = nil,
        gloss: String? = nil,
        translation: String? = nil,
        translationIsFallback: Bool = false,
        synonyms: [String] = [],
        antonyms: [String] = [],
        fieldSources: [String: FieldSource] = [:]
    ) {
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.order = order
        self.senseSource = senseSource
        self.gloss = gloss
        self.translation = translation
        self.translationIsFallback = translationIsFallback
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.fieldSources = fieldSources
    }

    /// `examples` in `Example.order`; the relationship itself is unordered.
    public var sortedExamples: [Example] {
        examples.sorted { $0.order < $1.order }
    }

    /// Provenance of one field; a missing entry means nothing user-protected (`.auto`).
    public func fieldSource(for field: SenseField) -> FieldSource {
        fieldSources[field.rawValue] ?? .auto
    }
}
