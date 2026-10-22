import FoundationModels

/// The part-of-speech vocabulary the model sees in the senses call (ADR 0001 point 1, plan 2.7).
/// `preposition` and `conjunction` have their own cases because *despite* came back as `adverb` in
/// 6/6 runs when the schema offered only `other`; determiners and pronouns stay `other` until a
/// regression word needs them (#19). The mapping onto `PartOfSpeech` is total.
@Generable(
    description: """
    Part of speech. Use preposition for prepositions, conjunction for conjunctions, phrase for idioms and \
    multi-word expressions, other for determiners and pronouns.
    """
)
public enum ModelPartOfSpeech: String, CaseIterable, Sendable {
    case noun
    case verb
    case adjective
    case adverb
    case preposition
    case conjunction
    case phrase
    case other

    /// The stored part of speech for a sense the model proposed.
    public var partOfSpeech: PartOfSpeech {
        switch self {
        case .noun: .noun
        case .verb: .verb
        case .adjective: .adjective
        case .adverb: .adverb
        case .preposition: .preposition
        case .conjunction: .conjunction
        case .phrase: .phrase
        case .other: .other
        }
    }
}
