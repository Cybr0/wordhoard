/// Where a `Sense` itself came from (requirements A1, W1).
///
/// A sense entered by hand has no source (`Sense.senseSource == nil`) and gets no badge.
public enum SenseSource: String, Codable, Sendable, CaseIterable {
    /// The sense was taken from the bundled Simple English Wiktionary (Phase 7), the first source.
    case wiktionary
    /// The sense was taken from the Open English WordNet inventory.
    case wordnet
    /// The sense was proposed by the language model (stoplist or model-only path).
    case model
}
