import WordhoardCore

/// Everything the word list's one `NavigationStack` can push (ADR 0002): a card, the topics
/// settings screen (plan 3.1), the Topics browse screen and one topic's examples (plan 3.3). Typed and
/// `Equatable`, so the list's reload-on-empty-path rule keeps working; no tab bar, no second stack.
enum Route: Hashable {
    case word(Word)
    case topicSettings
    case topics
    case topic(GrammarTopicID)
}
