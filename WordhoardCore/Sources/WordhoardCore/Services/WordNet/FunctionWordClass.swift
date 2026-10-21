/// The word class of a stoplist entry, read from the six `#` section headers of `function-words.txt`
/// (plan 2.7). WordNet has no prepositions or conjunctions, so for a stoplist word the section is the
/// only part-of-speech evidence the pipeline has; the senses and verifier prompts state it as a hint.
/// Membership on the stoplist is independent of the class: a lemma listed before the first header is a
/// function word with no class.
public enum FunctionWordClass: String, Equatable, Sendable, CaseIterable {
    case determiner
    case pronoun
    case preposition
    case conjunction
    case auxiliary
    case adverb

    /// The exact header text in `function-words.txt` (compared case-insensitively, trimmed). Other
    /// comment lines leave the current section unchanged.
    var sectionHeader: String {
        switch self {
        case .determiner: "Articles and determiners"
        case .pronoun: "Pronouns"
        case .preposition: "Prepositions"
        case .conjunction: "Conjunctions"
        case .auxiliary: "Auxiliaries and modals"
        case .adverb: "Discourse adverbs and connectives"
        }
    }

    /// The class for a `#` comment line's text, when it is one of the six headers.
    static func forSectionHeader(_ text: String) -> FunctionWordClass? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.sectionHeader.lowercased() == key }
    }
}
