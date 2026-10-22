// swiftlint:disable line_length
// Prompt text is kept on its original lines so it can be diffed against the spike (`665d06d`) verbatim.
import FoundationModels

/// One example sentence per call, neutral or for one grammar topic (A2). The topic is chosen by the
/// caller and named in the prompt with its one-line description; the model never classifies grammar.
/// The sense is passed as part of speech + definition so model and WordNet senses share one prompt.
/// A topic the sense cannot use naturally comes back as `fits == false` (plan 2.9): the spike's
/// unmarked escape hatch was never used and its wording made the model write the placeholder word
/// itself (ADR 0001, iteration 1), so the skip is a typed field and that word appears nowhere in here.
/// `mustContainHeadword` is the one retry after `HeadwordMatcher` rejected the first sentence.
public enum ExamplePrompt {
    public static let instructions = """
    You write example sentences for a learner's dictionary of English.
    Reply with exactly one complete, natural English sentence of 6 to 14 words.
    The sentence must contain the given word itself (an inflected form is fine) and must use it in the given sense and part of speech, not in another meaning of the word.
    When a grammar topic is given, the sentence must clearly show that grammar:
    - Present Perfect: have/has + past participle — "She has booked a table for tonight."
    - Second Conditional: if + past simple, would + verb — "If I had more time, I would read every day."
    - Passive Voice: be + past participle, the subject receives the action — "The room was lit by candles."
    When a grammar topic is given and the word in this sense cannot be used naturally in that grammar, set fits to false instead of forcing a sentence.
    When no grammar topic is given, a natural sentence always exists: set fits to true and write it.
    Do not explain, do not add quotes, do not write more than one sentence.
    """

    /// `topic == nil` asks for the neutral example. `mustContainHeadword` adds the retry line.
    public static func prompt(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?,
        mustContainHeadword: Bool = false
    ) -> String {
        var prompt = "Write one natural English sentence (6–14 words) that contains \"\(headword)\" used as a \(partOfSpeech.rawValue) in the sense \"\(definition)\""
        if let topic {
            prompt += " in the \(topic.name) (\(topic.description))."
            prompt += " If \"\(headword)\" in this sense cannot be used naturally in this grammar, set fits to false instead of forcing a sentence."
        } else {
            prompt += ". Use everyday language with no special grammar."
        }
        if mustContainHeadword {
            prompt += "\n\(mustContainLine(headword: headword))"
        }
        return prompt
    }

    /// The line the retry adds (plan 2.9), so tests can look for exactly it.
    public static func mustContainLine(headword: String) -> String {
        "The sentence must contain the word \"\(headword)\" itself."
    }
}

/// What an example call returns: the sentence first, then the verdict on it. The order matters and
/// was measured on the host model: with `fits` declared first the model decided before writing and
/// answered `false` on 9/9 topic calls, including the worked example (*book*, Present Perfect); with
/// `text` first it wrote the sentence and then judged it, `true` on 14/16 with sensible refusals.
/// `ExampleAnswer` is the `ModelCalls`-side form (`fits == false` or a blank `text` → `.doesNotFit`).
@Generable(description: "One example sentence and whether it is a natural fit for the requested grammar.")
struct ExampleReply {
    @Guide(
        description: "A complete, natural English sentence using the word in the requested sense, 6 to 14 words; blank when no natural sentence in this grammar exists for this sense."
    )
    var text: String

    @Guide(
        description: "true when text holds a natural sentence in the requested grammar; false when the word in this sense cannot be used naturally in that grammar."
    )
    var fits: Bool
}

// swiftlint:enable line_length
