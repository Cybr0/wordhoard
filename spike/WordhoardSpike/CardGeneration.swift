// Phase 0 spike: everything the model sees lives in this one file so it is easy
// to iterate on — the instructions, the prompt, the @Generable types and the call.
//
// Throwaway code. Not held to the root CLAUDE.md conventions (print is fine here).

import Foundation
import FoundationModels

// MARK: - Grammar topics (hard-coded stand-in for the real catalog)

/// A handful of namespaced keys. The real app loads these from a JSON catalog
/// (`docs/requirements.md` Appendix A); for the spike the list is inlined.
enum GrammarTopic {
    static let neutral = "en.neutral"

    /// Topics the user is "currently learning" — the prompt asks for one example per topic per sense.
    static let active = [
        "en.present_perfect",
        "en.past_simple",
        "en.first_conditional",
        "en.second_conditional",
        "en.passive_voice",
        "en.phrasal_verbs",
    ]

    static let all = [neutral] + active

    static var guideText: String {
        all.joined(separator: ", ")
    }
}

// MARK: - Instructions and prompt

let cardInstructions = """
You are a lexicographer writing dictionary cards for a learner of English whose native language is Russian.
Be concise, accurate and natural. Prefer everyday usage over rare senses.
Rules:
- Split the word into distinct senses (meanings). Give the most common sense first. Use 1 to 4 senses.
- Each sense has exactly one part of speech.
- Definitions are short, learner-friendly English, one sentence, no examples inside.
- Translations are in Russian, 1 to 3 comma-separated equivalents, lowercase.
- Synonyms and antonyms are single English words or short phrases. Use an empty list when there are none.
- Examples are complete, natural English sentences of 6 to 14 words that use the word in this sense.
- Every example is tagged with exactly one grammar topic key. Use the key only when the sentence clearly demonstrates that grammar; otherwise tag it en.neutral.
- For each sense, write one en.neutral example and then one example for each of these topics: \(GrammarTopic.active.joined(separator: ", ")).
"""

func cardPrompt(for word: String) -> String {
    "Write the dictionary card for the English word: \"\(word)\""
}

// MARK: - @Generable types

@Generable(description: "A dictionary card for one English word, split into senses.")
struct GeneratedCard {
    @Guide(description: "The headword exactly as given by the user.")
    var headword: String

    @Guide(description: "IPA pronunciation of the headword in British English, between slashes, e.g. /bʊk/.")
    var pronunciation: String

    @Guide(description: "Distinct meanings of the word, most common first.", .count(1...4))
    var senses: [GeneratedSense]

    @Guide(description: "A short English prompt for a simple illustration of the most common sense, suitable for a flashcard. Under 20 words, no text in the image.")
    var imagePrompt: String
}

@Generable(description: "One meaning of the word.")
struct GeneratedSense {
    @Guide(description: "Part of speech for this sense.")
    var partOfSpeech: PartOfSpeech

    @Guide(description: "Short learner-friendly definition in English, one sentence.")
    var definition: String

    @Guide(description: "Russian translation of this sense: 1 to 3 comma-separated equivalents, lowercase.")
    var translation: String

    @Guide(description: "English synonyms for this sense. Empty if none.", .maximumCount(5))
    var synonyms: [String]

    @Guide(description: "English antonyms for this sense. Empty if none.", .maximumCount(5))
    var antonyms: [String]

    @Guide(description: "Example sentences, each tagged with a grammar topic. First one is en.neutral, then one per active topic.", .count(2...8))
    var examples: [GeneratedExample]
}

@Generable(description: "Part of speech.")
enum PartOfSpeech: String {
    case noun
    case verb
    case adjective
    case adverb
    case phrase
    case other
}

@Generable(description: "An example sentence with a grammar topic tag.")
struct GeneratedExample {
    @Guide(description: "A complete, natural English sentence using the word in this sense, 6 to 14 words.")
    var text: String

    @Guide(description: "Grammar topic key the sentence demonstrates. One of: \(GrammarTopic.guideText). Use en.neutral when no specific grammar is demonstrated.", .anyOf(GrammarTopic.all))
    var grammarTopic: String
}

// MARK: - Generation

struct CardGenerationResult: Sendable {
    let card: GeneratedCard
    /// JSON the model produced, before it was decoded into `GeneratedCard`.
    let rawJSON: String
    let elapsed: Duration
}

/// Runs one generation in a fresh session. Caller must check
/// `SystemLanguageModel.default.availability` first; this does not.
func generateCard(for word: String) async throws -> CardGenerationResult {
    let session = LanguageModelSession(instructions: cardInstructions)
    let clock = ContinuousClock()
    let start = clock.now

    let response = try await session.respond(
        to: cardPrompt(for: word),
        generating: GeneratedCard.self,
        options: GenerationOptions(temperature: 0.3)
    )

    let elapsed = clock.now - start
    let rawJSON = response.rawContent.jsonString

    print("=== raw JSON for \"\(word)\" (\(elapsed)) ===")
    print(rawJSON)
    print("=== decoded card ===")
    dump(response.content)

    return CardGenerationResult(card: response.content, rawJSON: rawJSON, elapsed: elapsed)
}

// MARK: - Readable dump (shape of requirements.md Appendix B)

extension GeneratedCard {
    var readableDescription: String {
        var lines: [String] = []
        lines.append("Word: \(headword)  \(pronunciation)")
        for (index, sense) in senses.enumerated() {
            lines.append("")
            lines.append("Sense \(index + 1) — \(sense.partOfSpeech.rawValue)")
            lines.append("  definition:  \(sense.definition)")
            lines.append("  translation: \(sense.translation)")
            lines.append("  synonyms:    \(sense.synonyms.isEmpty ? "—" : sense.synonyms.joined(separator: ", "))")
            lines.append("  antonyms:    \(sense.antonyms.isEmpty ? "—" : sense.antonyms.joined(separator: ", "))")
            lines.append("  examples:")
            for example in sense.examples {
                let tag = "[\(example.grammarTopic.replacingOccurrences(of: "en.", with: ""))]"
                lines.append("    \(tag.padding(toLength: 22, withPad: " ", startingAt: 0))\(example.text)")
            }
        }
        lines.append("")
        lines.append("Image prompt: \"\(imagePrompt)\"")
        return lines.joined(separator: "\n")
    }
}
