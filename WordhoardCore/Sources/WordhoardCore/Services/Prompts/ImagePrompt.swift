// swiftlint:disable line_length
import FoundationModels

/// The picture prompt (plan 4.2, I1, I5): the model turns a word and, when the card has one, its first
/// definition into a short, concrete visual description for Image Playground, or says there is nothing
/// to draw. Not covered by the card regression runner: the 7-word device table on #47 is this prompt's
/// regression, re-run whenever the text below changes.
public enum ImagePrompt {
    public static let instructions = """
    You write picture prompts for a vocabulary app for learners of English.
    You are given an English word and, when known, the meaning to show.
    Describe one simple picture that shows this meaning the way a learner would picture it: a single concrete object or one simple scene.
    Rules:
    - At most 20 words, plain English, no quotation marks.
    - A flat, friendly, child-safe illustration.
    - No words, letters, numbers or signs in the picture. No faces in close-up and no real or famous people.
    - Show the meaning, not the spelling of the word.
    - If the word names nothing concrete a picture can show (a function word such as "however", "despite" or "the", or an abstract idea), write an empty prompt and set drawable to false.
    """

    public static func prompt(headword: String, definition: String?) -> String {
        var lines = ["Word: \"\(headword)\""]
        if let definition, !definition.isEmpty {
            lines.append("Meaning: \(definition)")
        }
        lines.append("Write the picture prompt for \"\(headword)\".")
        return lines.joined(separator: "\n")
    }

    /// The reply as the writer returns it: `nil` when the model says there is nothing to draw or wrote
    /// nothing, otherwise the trimmed prompt.
    package static func result(prompt: String, drawable: Bool) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return drawable && !trimmed.isEmpty ? trimmed : nil
    }
}

/// What the picture prompt call returns. The text comes before the verdict: with the boolean first the
/// model answered the verdict without having written anything (the 2.9 `fits` finding).
@Generable(description: "A picture prompt for one English word.")
struct ImagePromptSuggestion {
    @Guide(
        description: "One scene or object to draw, at most 20 words, no text and no faces; empty when there is nothing concrete to draw."
    )
    var prompt: String

    @Guide(description: "false when the word names nothing concrete to draw")
    var drawable: Bool
}

// swiftlint:enable line_length
