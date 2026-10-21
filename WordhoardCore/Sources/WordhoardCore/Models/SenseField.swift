/// The `Sense` fields that carry provenance in `Sense.fieldSources`.
///
/// The stored form is `[String: FieldSource]` keyed by these raw values; this enum only keeps callers
/// from misspelling a key.
public enum SenseField: String, Codable, Sendable, CaseIterable {
    case definition
    case translation
    case synonyms
    case antonyms
}
