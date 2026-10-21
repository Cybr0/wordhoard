/// The one-line word-class hint the senses and verifier prompts add for a stoplist word (plan 2.7):
/// "This word is usually a preposition." The class comes from the stoplist's section header, the only
/// part-of-speech evidence there is for a word WordNet does not cover.
public enum WordClassHint {
    /// The noun phrase after "usually": "a preposition", "an auxiliary or modal verb".
    public static func phrase(for wordClass: FunctionWordClass) -> String {
        switch wordClass {
        case .determiner: "a determiner"
        case .pronoun: "a pronoun"
        case .preposition: "a preposition"
        case .conjunction: "a conjunction"
        case .auxiliary: "an auxiliary or modal verb"
        case .adverb: "an adverb"
        }
    }

    /// The full line, or `nil` when the word has no class (not on the stoplist, or listed before the
    /// first section header).
    public static func line(for wordClass: FunctionWordClass?) -> String? {
        wordClass.map { "This word is usually \(phrase(for: $0))." }
    }
}
