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

    /// `wordClass` is the stoplist section of a function word (plan 2.7); it adds the same hint line
    /// the senses prompt carries.
    public static func prompt(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        wordClass: FunctionWordClass? = nil
    ) -> String {
        let role = switch partOfSpeech {
        case .phrase: "as an idiom or fixed phrase"
        case .other: "as a determiner, pronoun or other function word"
        case .adjective, .adverb: "as an \(partOfSpeech.rawValue)"
        case .noun, .verb, .preposition, .conjunction: "as a \(partOfSpeech.rawValue)"
        }
        var prompt = "Is the English word \"\(headword)\" commonly used \(role) meaning \"\(definition)\"? Answer yes or no."
        if let hint = WordClassHint.line(for: wordClass) {
            prompt += " \(hint)"
        }
        return prompt
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
