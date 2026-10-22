// swiftlint:disable line_length
import FoundationModels

/// The sense-selection call (plan 2.6, #18): WordNet lists more senses than a learner needs, in an order
/// that puts *run*'s baseball score before *manage*; the model picks the ≤ 4 a learner's dictionary would
/// list first. Code never trusts the answer blindly: `WordNetLookup.selection(_:from:)` drops invalid and
/// duplicate numbers, guarantees one sense per part of speech and caps the result; a failed or unusable
/// answer falls back to `WordNetLookup.select`.
///
/// The candidates are numbered from 1 in the prompt, the way a list reads; `FoundationModelCalls` turns
/// the numbers back into 0-based candidate indices.
public enum SenseSelectionPrompt {
    public static let instructions = """
    You choose senses for a learner's dictionary of English.
    You are given an English word and a numbered list of its dictionary senses, each with its part of speech and a short definition.
    Pick the senses a learner's dictionary would list first: the everyday meanings a learner meets most often, not technical, rare or specialised ones.
    Pick at most 4. Include every part of speech that has a common sense.
    Answer with the numbers of the chosen senses only, most useful first.
    """

    /// One line per candidate, `n. (part of speech) gloss`, numbered from 1.
    public static func prompt(headword: String, candidates: [WordNetSense]) -> String {
        var lines = ["Word: \"\(headword)\"", "Senses:"]
        for (index, candidate) in candidates.enumerated() {
            lines.append("\(index + 1). (\(candidate.partOfSpeech.rawValue)) \(candidate.gloss)")
        }
        lines.append("Which of these senses (at most 4) should a learner's dictionary list for \"\(headword)\"?")
        return lines.joined(separator: "\n")
    }
}

/// What the selection call returns: the chosen candidate numbers, 1-based as in the prompt.
@Generable(description: "The senses of a word a learner's dictionary should list.")
struct SenseSelection {
    @Guide(
        description: "The numbers of the chosen senses from the list, most useful first; at most 4.",
        .count(1 ... 4)
    )
    var numbers: [Int]
}

// swiftlint:enable line_length
