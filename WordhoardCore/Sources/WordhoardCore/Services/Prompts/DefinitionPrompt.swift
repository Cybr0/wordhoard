// swiftlint:disable line_length
// Prompt text is kept on its original lines so it can be diffed against the spike (`665d06d`) verbatim.
import FoundationModels

/// The writing call for one WordNet sense: the model turns the terse gloss into a learner definition
/// (ADR 0001 point 2). Synonyms and antonyms on the card come from WordNet, never from this call. The
/// WordNet example sentence and synonyms are in the prompt because the gloss alone was misread on the
/// first device run ("engage for a performance" → *rehearse*). Ported from the spike's
/// `senseWritingInstructions` with the native-language sentence removed.
public enum DefinitionPrompt {
    public static let instructions = """
    You write entries for a learner's dictionary of English.
    You are given one sense of an English word: the word, its part of speech, the dictionary gloss, its synonyms and an example sentence from the dictionary that shows this sense (the example may use a synonym instead of the word).
    Use the gloss, the synonyms and the example only to understand exactly which meaning is intended.
    Write a learner-friendly definition of this sense: one short phrase or sentence in simple everyday words that explains the meaning in general terms, as a dictionary would.
    Rules:
    - A definition is not a sentence about a particular person, place, thing or event. Never retell, paraphrase or reuse the example sentence or anything in it (its people, objects, places).
    - For a verb, start with "to": "to give food to a person or an animal". For a noun, write a noun phrase: "a small animal with soft fur and long ears". For an adjective, describe the quality: "very large". For an adverb, describe the manner: "in a quiet way, without much noise".
    - Define the given word, not a synonym from the example sentence. The definition must fit the headword in the part of speech given; an adverb's definition must differ from the related adjective's.
    - Keep facts that are the meaning itself: a proper name keeps its real referent (a city stays the capital of its real country), a species stays that species.
    - Rewrite the gloss in your own simple words; do not copy it, and do not use the word itself in the definition.
    - Stay with the given sense; do not describe other meanings of the word.
    - Explain the meaning the way a good learner's dictionary does for an intermediate learner: the simplest natural explanation, usually under 12 words. Do not follow the structure of the gloss or keep its technical details.
    Examples of what to avoid and what to write:
    - "run", verb, gloss "move fast by using one's feet, with one foot off the ground at any given time". Bad: "to move quickly by lifting one leg off the ground at times". Good: "to move very quickly on your feet".
    - "light", noun, gloss "(physics) electromagnetic radiation that can produce a visual sensation". Bad: "a wave that makes things appear bright". Good: "the brightness from the sun or a lamp that lets you see".
    - "issue", noun, gloss "an important question that is in dispute and must be settled". Bad: "a question in dispute that must be settled". Good: "an important problem or subject that people discuss".
    """

    public static func prompt(headword: String, sense: WordNetSense) -> String {
        var lines = [
            "Word: \"\(headword)\"",
            "Part of speech: \(sense.partOfSpeech.rawValue)",
            "Dictionary gloss: \(sense.gloss)",
        ]
        // Not the usual idiom on purpose: #21 greps this directory for the word it bans from prompts.
        if sense.synonyms.first != nil {
            lines.append("Synonyms: \(sense.synonyms.joined(separator: ", "))")
        }
        if let example = sense.example {
            lines.append("Example of this sense (for understanding only, do not reuse it): \(example)")
        }
        lines
            .append(
                "Write the learner definition of \"\(headword)\" as a \(sense.partOfSpeech.rawValue) in this sense."
            )
        return lines.joined(separator: "\n")
    }
}

/// What the writing call returns.
@Generable(description: "Learner-facing text for one dictionary sense of an English word.")
struct SenseWriting {
    @Guide(
        description: "A general dictionary-style definition of this sense in simple English (verbs start with \"to\", nouns are a noun phrase), in your own words, never a sentence about a particular person or event."
    )
    var learnerDefinition: String
}

// swiftlint:enable line_length
