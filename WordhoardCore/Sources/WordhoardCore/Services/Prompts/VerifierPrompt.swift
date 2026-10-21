// swiftlint:disable line_length
// Prompt text is kept on its original lines so it can be diffed against the spike (`665d06d`) verbatim.
import FoundationModels

/// The yes/no verifier: one cheap call per proposed sense. Small models verify better than they
/// generate (ADR 0001 appendix D): the senses call pads its list with paraphrases and inventions, so
/// every proposed sense is checked in its own call before anything is written for it.
public enum VerifierPrompt {
    public static let instructions = """
    You check entries for a learner's dictionary of English.
    You are given an English word, a part of speech and a short definition.
    Answer whether the word is commonly used with exactly that part of speech and that meaning, as a learner's dictionary would list it.
    Answer no for invented meanings, for rare or technical meanings, and when the part of speech is wrong for that meaning.
    Answer yes or no only.
    """

    public static func prompt(headword: String, partOfSpeech: PartOfSpeech, definition: String) -> String {
        let role = switch partOfSpeech {
        case .phrase: "as an idiom or fixed phrase"
        case .other, .preposition, .conjunction: "as a preposition, conjunction, determiner or pronoun"
        case .adjective, .adverb: "as an \(partOfSpeech.rawValue)"
        case .noun, .verb: "as a \(partOfSpeech.rawValue)"
        }
        return "Is the English word \"\(headword)\" commonly used \(role) meaning \"\(definition)\"? Answer yes or no."
    }
}

/// The verdict is a single `Bool`: guided generation pins the model to the JSON boolean tokens, so
/// there is nothing to parse and no "Yes." / "No, because…" to normalise.
@Generable(description: "Verdict on whether one dictionary sense is real.")
struct SenseVerdict {
    @Guide(description: "true if the word is commonly used with this part of speech and this meaning; false otherwise.")
    var isCommonlyUsed: Bool
}

// swiftlint:enable line_length
