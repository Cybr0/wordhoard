// Phase 0 spike: everything the model sees lives in this one file so it is easy
// to iterate on — the instructions, the prompts, the @Generable types and the
// individual model calls. Orchestration (lazy split-call flow, timings, UI state)
// is in CardGenerationModel.swift.
//
// Two paths are kept side by side (issue #4):
//   - "Split calls" (default, the one to measure): call 1 returns the senses only;
//     then one tiny call per (sense, topic) returns a single example sentence.
//     The grammar topic is assigned by the caller, never classified by the model.
//   - "Single call": the PR #9 shape, one big call returning the whole card.
//     Kept for comparison; it overflowed the 4096-token context on "however".
//
// Throwaway code. Not held to the root CLAUDE.md conventions (print is fine here).

import Foundation
import FoundationModels

// MARK: - Grammar topics (hard-coded stand-in for the real catalog)

/// A namespaced grammar topic with the text the prompt uses to describe it.
/// The real app loads these from a JSON catalog (`docs/requirements.md` Appendix A).
struct GrammarTopic: Hashable, Sendable {
    /// Namespaced key, e.g. `en.present_perfect`.
    let key: String
    /// Human-readable name used in the prompt and on screen.
    let name: String
    /// One line put into the example prompt so the model knows what the topic is.
    let description: String

    static let neutral = GrammarTopic(
        key: "en.neutral",
        name: "Neutral",
        description: "No specific grammar; a plain everyday sentence."
    )

    /// Default topics for the regression run (`docs/regression-words.md`).
    static let active: [GrammarTopic] = [
        GrammarTopic(
            key: "en.present_perfect",
            name: "Present Perfect",
            description: "have/has + past participle, for actions with a result or relevance now"
        ),
        GrammarTopic(
            key: "en.second_conditional",
            name: "Second Conditional",
            description: "If + past simple, would + base verb, for hypothetical or unlikely situations"
        ),
        GrammarTopic(
            key: "en.passive_voice",
            name: "Passive Voice",
            description: "be + past participle, the subject receives the action"
        ),
    ]

    static let all = [neutral] + active

    static var guideText: String {
        all.map(\.key).joined(separator: ", ")
    }
}

// MARK: - Shared

@Generable(description: "Part of speech.")
enum PartOfSpeech: String {
    case noun
    case verb
    case adjective
    case adverb
    case phrase
    case other
}

let generationOptions = GenerationOptions(temperature: 0.3)

// MARK: - Split path, call 1: senses only

let sensesInstructions = """
You are a lexicographer writing dictionary entries for a learner of English whose native language is Russian.
Be concise, accurate and natural. Prefer everyday usage over rare senses.
Rules:
- List 1 to 3 distinct senses (meanings) of the word, most common first.
- Most words have one or two senses. Return only senses a learner's dictionary would list.
- Do not invent a sense to fill the list; if the word has one meaning, return exactly one.
- Senses must be different meanings, not rephrasings. If two candidate senses could share one definition, keep one.
- Cover every common part of speech of the word. If the word is commonly used both as a noun and as a verb, include one sense for each.
- Each sense has exactly one part of speech.
- Definitions are short, learner-friendly English, one sentence, no example sentences.
- Translations are in Russian, 1 to 3 comma-separated equivalents, lowercase.
- Synonyms and antonyms are single English words or short phrases. Give at least one synonym when any exists. Use an empty list only when there truly are none.
- Do not write example sentences in this entry.

Worked example — "run" has three different meanings across two parts of speech:
1. noun — "a period of running, for exercise or sport" — пробежка
2. verb — "to move fast on foot" — бежать
3. verb — "to manage or operate something, such as a business" — управлять

Worked example — "nevertheless" has exactly one meaning, so the entry has exactly one sense:
1. adverb — "in spite of what has just been said" — тем не менее
"""

func sensesPrompt(for word: String) -> String {
    "Write the dictionary entry for the English word: \"\(word)\""
}

@Generable(description: "A dictionary entry for one English word: its senses, without example sentences.")
struct GeneratedSenses {
    @Guide(description: "The headword exactly as given by the user.")
    var headword: String

    @Guide(description: "Distinct meanings of the word, most common first. Include both the noun and the verb sense when the word has both.", .count(1...3))
    var senses: [GeneratedSenseCore]

    @Guide(description: "A short English prompt for a simple illustration of the most common sense, suitable for a flashcard. Under 20 words, no text in the image.")
    var imagePrompt: String
}

@Generable(description: "One meaning of the word, without examples.")
struct GeneratedSenseCore {
    @Guide(description: "Part of speech for this sense.")
    var partOfSpeech: PartOfSpeech

    @Guide(description: "Short learner-friendly definition in English, one sentence.")
    var definition: String

    @Guide(description: "Russian translation of this sense: 1 to 3 comma-separated equivalents, lowercase.")
    var translation: String

    @Guide(description: "English synonyms for this sense. Empty only if none exist.", .maximumCount(5))
    var synonyms: [String]

    @Guide(description: "English antonyms for this sense. Empty if none exist.", .maximumCount(5))
    var antonyms: [String]
}

// MARK: - Split path, calls 2…N: one example per (sense, topic)

let exampleInstructions = """
You write example sentences for a learner's dictionary of English.
Reply with exactly one complete, natural English sentence of 6 to 14 words.
The sentence must use the given word in the given sense and part of speech; an inflected form of the word is fine.
When a grammar topic is given, the sentence must clearly demonstrate that grammar.
Do not explain, do not add quotes, do not write more than one sentence.
"""

/// Prompt for one example. The topic is chosen by the caller; `nil` means a neutral example.
func examplePrompt(word: String, sense: GeneratedSenseCore, topic: GrammarTopic?) -> String {
    var prompt = "Write one natural English sentence (6–14 words) using \"\(word)\" as a \(sense.partOfSpeech.rawValue) in the sense \"\(sense.definition)\""
    if let topic {
        prompt += " in the \(topic.name) (\(topic.description))."
    } else {
        prompt += ". Use everyday language with no special grammar."
    }
    return prompt
}

@Generable(description: "One example sentence.")
struct GeneratedExampleText {
    @Guide(description: "A complete, natural English sentence using the word in the requested sense, 6 to 14 words.")
    var text: String
}

// MARK: - Single path (PR #9 shape, kept for comparison)

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
- For each sense, write one en.neutral example and then one example for each of these topics: \(GrammarTopic.active.map(\.key).joined(separator: ", ")).
"""

func cardPrompt(for word: String) -> String {
    "Write the dictionary card for the English word: \"\(word)\""
}

@Generable(description: "A dictionary card for one English word, split into senses.")
struct GeneratedCard {
    @Guide(description: "The headword exactly as given by the user.")
    var headword: String

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

    @Guide(description: "Example sentences, each tagged with a grammar topic. First one is en.neutral, then one per active topic.", .count(1...4))
    var examples: [GeneratedExample]
}

@Generable(description: "An example sentence with a grammar topic tag.")
struct GeneratedExample {
    @Guide(description: "A complete, natural English sentence using the word in this sense, 6 to 14 words.")
    var text: String

    @Guide(description: "Grammar topic key the sentence demonstrates. One of: \(GrammarTopic.guideText). Use en.neutral when no specific grammar is demonstrated.", .anyOf(GrammarTopic.all.map(\.key)))
    var grammarTopic: String
}

// MARK: - Model calls

/// Result of one model call: the decoded value, the raw JSON and how long it took.
struct ModelCallResult<Content: Sendable>: Sendable {
    let content: Content
    /// JSON the model produced, before it was decoded.
    let rawJSON: String
    let elapsed: Duration
}

/// Runs one structured generation in a fresh `LanguageModelSession`, so no transcript
/// accumulates between calls and the context never grows. Caller must check
/// `SystemLanguageModel.default.availability` first; this does not.
private func respond<Content: Generable & Sendable>(
    instructions: String,
    prompt: String,
    generating type: Content.Type,
    label: String
) async throws -> ModelCallResult<Content> {
    let session = LanguageModelSession(instructions: instructions)
    let clock = ContinuousClock()
    let start = clock.now

    let response = try await session.respond(to: prompt, generating: type, options: generationOptions)

    let elapsed = clock.now - start
    let rawJSON = response.rawContent.jsonString
    print("=== \(label) (\(elapsed.spikeFormatted)) ===")
    print(rawJSON)
    return ModelCallResult(content: response.content, rawJSON: rawJSON, elapsed: elapsed)
}

/// Split path, call 1.
func generateSenses(for word: String) async throws -> ModelCallResult<GeneratedSenses> {
    try await respond(
        instructions: sensesInstructions,
        prompt: sensesPrompt(for: word),
        generating: GeneratedSenses.self,
        label: "senses for \"\(word)\""
    )
}

/// Split path, calls 2…N. One fresh session per example.
func generateExample(
    word: String,
    sense: GeneratedSenseCore,
    topic: GrammarTopic?
) async throws -> ModelCallResult<GeneratedExampleText> {
    try await respond(
        instructions: exampleInstructions,
        prompt: examplePrompt(word: word, sense: sense, topic: topic),
        generating: GeneratedExampleText.self,
        label: "example for \"\(word)\" (\(sense.partOfSpeech.rawValue)) / \(topic?.key ?? GrammarTopic.neutral.key)"
    )
}

/// Single path: the whole card in one call.
func generateCard(for word: String) async throws -> ModelCallResult<GeneratedCard> {
    try await respond(
        instructions: cardInstructions,
        prompt: cardPrompt(for: word),
        generating: GeneratedCard.self,
        label: "single-call card for \"\(word)\""
    )
}

extension Duration {
    var spikeFormatted: String {
        formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
    }
}
