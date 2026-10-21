// swiftlint:disable line_length
// Prompt text is kept on its original lines so it can be diffed against the spike (`665d06d`) verbatim.
import FoundationModels

/// One example sentence per call, neutral or for one grammar topic (A2). The topic is chosen by the
/// caller and named in the prompt with its one-line description; the model never classifies grammar.
/// The sense is passed as part of speech + definition so model and WordNet senses share one prompt.
/// A topic the sense cannot use naturally comes back as an empty string (plan 2.9 types this).
public enum ExamplePrompt {
    public static let instructions = """
    You write example sentences for a learner's dictionary of English.
    Reply with exactly one complete, natural English sentence of 6 to 14 words.
    The sentence must contain the given word itself (an inflected form is fine) and must use it in the given sense and part of speech, not in another meaning of the word.
    When a grammar topic is given, the sentence must clearly show that grammar:
    - Present Perfect: have/has + past participle — "She has booked a table for tonight."
    - Second Conditional: if + past simple, would + verb — "If I had more time, I would read every day."
    - Passive Voice: be + past participle, the subject receives the action — "The room was lit by candles."
    When a grammar topic is given and the word in this sense cannot be used naturally in that grammar, return an empty string instead of forcing a sentence.
    Do not explain, do not add quotes, do not write more than one sentence, never write the word "empty".
    """

    /// `topic == nil` asks for the neutral example.
    public static func prompt(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?
    ) -> String {
        var prompt = "Write one natural English sentence (6–14 words) that contains \"\(headword)\" used as a \(partOfSpeech.rawValue) in the sense \"\(definition)\""
        if let topic {
            prompt += " in the \(topic.name) (\(topic.description))."
            prompt += " If \"\(headword)\" in this sense cannot be used naturally in this grammar, return an empty string."
        } else {
            prompt += ". Use everyday language with no special grammar."
        }
        return prompt
    }
}

/// What an example call returns.
@Generable(description: "One example sentence.")
struct ExampleText {
    @Guide(
        description: "A complete, natural English sentence using the word in the requested sense, 6 to 14 words. Empty only when the prompt allows it because the sense does not fit the requested grammar."
    )
    var text: String
}

// swiftlint:enable line_length
