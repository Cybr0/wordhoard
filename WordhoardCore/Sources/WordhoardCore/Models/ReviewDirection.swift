/// Direction of a review prompt in a `ReviewEvent` (post-v1).
public enum ReviewDirection: String, Codable, Sendable, CaseIterable {
    case wordToMeaning
    case meaningToWord
}
