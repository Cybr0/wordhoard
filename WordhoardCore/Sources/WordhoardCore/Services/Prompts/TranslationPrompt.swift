// swiftlint:disable line_length
import Foundation
import FoundationModels

/// The translation-proposal call (plan 2.10, #22; A9). The model proposes a 1–3-word equivalent of one
/// sense in the user's native language; it is **never shown as is**: the generator back-translates
/// every proposal with Apple's Translation framework and keeps it only when the English comes back as
/// the headword or a synonym of that sense. A rejected proposal is replaced by the framework's
/// translation of the learner definition. The spike showed the model's own Russian prose contained
/// non-words, which is why the model only proposes and the framework decides.
public enum TranslationPrompt {
    public static let instructions = """
    You help a learner's dictionary of English give the equivalent of one sense of an English word in the learner's own language.
    You are given the English word, its part of speech, the definition of one sense, its synonyms and an example sentence, and the language to answer in.
    Reply with the dictionary equivalent of the word in exactly this sense: 1 to 3 words in the requested language, lowercase, in its dictionary form.
    Use the same part of speech as the English word: a verb for a verb, a noun for a noun.
    Never write a sentence, an explanation, a transliteration or English words.
    """

    /// `nativeLanguage` is a BCP-47 tag; the prompt names the language in English (`ru` → Russian).
    public static func prompt(headword: String, sense: GeneratedSense, nativeLanguage: String) -> String {
        let language = languageName(nativeLanguage)
        var lines = [
            "Word: \"\(headword)\"",
            "Part of speech: \(sense.partOfSpeech.rawValue)",
            "Definition of this sense: \(sense.definition)",
        ]
        if let gloss = sense.gloss, gloss != sense.definition {
            lines.append("Dictionary gloss: \(gloss)")
        }
        if sense.synonyms.first != nil {
            lines.append("Synonyms: \(sense.synonyms.joined(separator: ", "))")
        }
        if let example = sense.neutralExample?.text {
            lines.append("Example: \(example)")
        }
        lines
            .append(
                "Give the \(language) equivalent of \"\(headword)\" as a \(sense.partOfSpeech.rawValue) in this sense, 1 to 3 words."
            )
        return lines.joined(separator: "\n")
    }

    /// The English name of a BCP-47 language (`ru` → "Russian"); the tag itself when unknown.
    public static func languageName(_ tag: String) -> String {
        let code = Locale.Language(identifier: tag).languageCode?.identifier ?? tag
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? tag
    }
}

/// What the proposal call returns: one short equivalent. A single field, so there is no ordering
/// question of the kind `ExampleReply` had (text before verdict).
@Generable(description: "The equivalent of one sense of an English word in the learner's language.")
struct TranslationProposal {
    @Guide(description: "1 to 3 words in the requested language, lowercase, dictionary form; never a sentence.")
    var equivalent: String
}

// swiftlint:enable line_length
