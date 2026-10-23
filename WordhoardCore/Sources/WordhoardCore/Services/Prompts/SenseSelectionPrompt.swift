// swiftlint:disable line_length
import FoundationModels

/// The sense-selection call (plan 2.6, #18; reworked in Phase 7 after the owner's feedback): WordNet
/// lists senses in an order that puts *run*'s baseball score before *move fast* and *manage*; the model
/// ranks them by how common they are in everyday English and leaves out rare, technical and
/// near-duplicate ones. Code never trusts the answer blindly: `WordNetLookup.selection(_:from:)` drops
/// invalid and duplicate numbers and caps the result; a failed or unusable answer falls back to
/// `WordNetLookup.select`.
///
/// The candidates are numbered from 1 in the prompt, the way a list reads; `FoundationModelCalls` turns
/// the numbers back into 0-based candidate indices.
public enum SenseSelectionPrompt {
    public static let instructions = """
    You rank the meanings of an English word for a learner's dictionary.
    You are given an English word and a numbered list of its dictionary senses, each with its part of speech and a short definition. The list is not in order of how common the senses are.
    Choose the meanings an intermediate learner is most likely to meet in everyday modern English, and list them from the most common to the least common.
    Leave out rare, old-fashioned, technical, scientific, legal, sports-specific and other specialised meanings, even when they come first in the list.
    Do not choose two senses that mean almost the same thing; keep only the clearer one.
    Usually choose 2 or 3. Choose 4 only for a very common word with four clearly different everyday meanings. Choose 1 if only one meaning is common.
    Answer with the numbers of the chosen senses only, the most common meaning first.
    """

    /// One line per candidate, `n. (part of speech) gloss`, numbered from 1.
    public static func prompt(headword: String, candidates: [WordNetSense]) -> String {
        var lines = ["Word: \"\(headword)\"", "Senses:"]
        for (index, candidate) in candidates.enumerated() {
            lines.append("\(index + 1). (\(candidate.partOfSpeech.rawValue)) \(candidate.gloss)")
        }
        lines
            .append(
                "Which of these meanings of \"\(headword)\" are common in everyday English? List them from the most common to the least common (at most 4)."
            )
        return lines.joined(separator: "\n")
    }
}

/// What the selection call returns: the chosen candidate numbers, 1-based as in the prompt.
@Generable(description: "The everyday meanings of a word, from the most common to the least common.")
struct SenseSelection {
    @Guide(
        description: "The numbers of the chosen senses from the list, the most common meaning first; at most 4.",
        .count(1 ... 4)
    )
    var numbers: [Int]
}

// swiftlint:enable line_length
