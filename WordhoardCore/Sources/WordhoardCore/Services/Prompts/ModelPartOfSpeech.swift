import FoundationModels

/// The part-of-speech vocabulary the model sees in the senses call (ADR 0001 point 1). Smaller than
/// `PartOfSpeech`: prepositions and conjunctions are `other` until plan 2.7 adds their own cases, so
/// the prompt and the schema stay exactly what scored best at `665d06d`.
@Generable(
    description: """
    Part of speech. Use phrase for idioms and multi-word expressions, other for prepositions, conjunctions, \
    determiners and pronouns.
    """
)
enum ModelPartOfSpeech: String {
    case noun
    case verb
    case adjective
    case adverb
    case phrase
    case other

    /// The stored part of speech for a sense the model proposed.
    var partOfSpeech: PartOfSpeech {
        switch self {
        case .noun: .noun
        case .verb: .verb
        case .adjective: .adjective
        case .adverb: .adverb
        case .phrase: .phrase
        case .other: .other
        }
    }
}
