/// Part of speech of a `Sense`.
///
/// Exactly the eight cases of `requirements.md` §5. `preposition` and `conjunction` are present from the
/// start (ADR 0001); `determiner` / `pronoun` are decided by plan task 2.7. The raw value is the case
/// name and is part of the export format (1.7), so cases are never renamed.
public enum PartOfSpeech: String, Codable, Sendable, CaseIterable {
    case noun
    case verb
    case adjective
    case adverb
    case preposition
    case conjunction
    case phrase
    case other
}
