// swiftlint:disable line_length
// Prompt text is kept on its original lines so it can be diffed against the spike (`665d06d`) verbatim.
import FoundationModels

/// The model-only senses call: for a headword on the function-word stoplist or missing from WordNet,
/// the model proposes 1…3 senses (ADR 0001 point 1). Ported from the spike's `sensesInstructions`
/// with the native-language lines removed (the model never writes in the learner's language, A9) and
/// the illustration prompt dropped (plan 4.2 adds its own call). Plan 2.7 gave prepositions and
/// conjunctions their own part-of-speech values and added the stoplist word-class hint.
public enum SensesPrompt {
    public static let instructions = """
    You are a lexicographer writing dictionary entries for a learner of English.
    Be concise, accurate and natural. Prefer everyday usage over rare senses.
    Rules:
    - List 1 to 3 distinct senses (meanings) of the word, most common first.
    - Most words have one or two senses. Return only senses a learner's dictionary would list.
    - Do not invent a sense to fill the list; if the word has one meaning, return exactly one.
    - Senses must be different meanings, not rephrasings. If two candidate senses could share one definition, keep one.
    - Cover every common part of speech of the word. If the word is commonly used both as a noun and as a verb, include one sense for each.
    - Each sense has exactly one part of speech. Prepositions are "preposition", conjunctions are "conjunction", determiners and pronouns are "other"; idioms and multi-word expressions are "phrase". A preposition is never an adverb.
    - Definitions are short, learner-friendly English, one sentence, no example sentences. A definition describes the meaning in general terms; it is never a sentence about a particular person or event.
    - Synonyms and antonyms are single English words or short phrases. Give at least one synonym when any exists; give none only when there truly are none.
    - Do not write example sentences in this entry.

    Worked example — "run" has three different meanings across two parts of speech:
    1. noun — "a period of running, for exercise or sport"
    2. verb — "to move fast on foot"
    3. verb — "to manage or operate something, such as a business"

    Worked example — "nevertheless" has exactly one meaning, so the entry has exactly one sense:
    1. adverb — "in spite of what has just been said"

    Worked example — "during" is a preposition with one meaning:
    1. preposition — "throughout the whole time that something lasts"

    Worked example — "with regard to" is a fixed phrase that works like a preposition, with one meaning:
    1. phrase — "about; concerning (used to say what something is connected with)"
    """

    /// `wordClass` is the stoplist section of a function word (plan 2.7); it adds one hint line.
    public static func prompt(headword: String, wordClass: FunctionWordClass? = nil) -> String {
        var prompt = "Write the dictionary entry for the English word: \"\(headword)\""
        if let hint = WordClassHint.line(for: wordClass) {
            prompt += "\n\(hint)"
        }
        return prompt
    }
}

/// What the senses call returns: the headword and its senses, nothing else.
@Generable(description: "A dictionary entry for one English word: its senses, without example sentences.")
struct ProposedEntry {
    @Guide(description: "The headword exactly as given by the user.")
    var headword: String

    @Guide(
        description: "Distinct meanings of the word, most common first. Include both the noun and the verb sense when the word has both.",
        .count(1 ... 3)
    )
    var senses: [ProposedSenseContent]
}

/// One proposed sense as the model writes it; `ProposedSense` is its stored form.
@Generable(description: "One meaning of the word, without examples.")
struct ProposedSenseContent {
    @Guide(
        description: "Part of speech for this sense: noun, verb, adjective, adverb, preposition or conjunction; phrase for an idiom or multi-word expression; other for a determiner or pronoun."
    )
    var partOfSpeech: ModelPartOfSpeech

    @Guide(description: "Short learner-friendly definition in English, one sentence.")
    var definition: String

    @Guide(description: "English synonyms for this sense; none only if none exist.", .maximumCount(5))
    var synonyms: [String]

    @Guide(description: "English antonyms for this sense; none if none exist.", .maximumCount(5))
    var antonyms: [String]
}

// swiftlint:enable line_length
