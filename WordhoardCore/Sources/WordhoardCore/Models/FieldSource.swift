/// Provenance of a generated-or-edited field (requirements A4).
///
/// Regeneration fills `.auto` fields and never touches `.user` fields.
public enum FieldSource: String, Codable, Sendable, CaseIterable {
    /// Written by the generator; may be overwritten by regeneration.
    case auto
    /// Written or edited by the user; never overwritten.
    case user
}
