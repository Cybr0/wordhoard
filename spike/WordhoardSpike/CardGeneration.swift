// Phase 0 spike: everything the model sees lives in this one file so it is easy
// to iterate on — the instructions, the prompts, the @Generable types and the
// individual model calls. Orchestration (lazy split-call flow, timings, UI state)
// is in CardGenerationModel.swift.
//
// Two paths are kept side by side (issue #4):
//   - "Split calls" (default, the one to measure): call 1 returns the senses only;
//     one cheap yes/no call per sense drops invented or paraphrased senses (iteration 2);
//     then one tiny call per (sense, topic) returns a single example sentence.
//     The grammar topic is assigned by the caller, never classified by the model.
//   - "Single call": the PR #9 shape, one big call returning the whole card.
//     Kept for comparison; it overflowed the 4096-token context on "however".
//   - "WordNet + model" (issue #11): the senses come from the bundled WordNet
//     (WordNetLookup.swift); the model only writes — one call per sense for the
//     learner definition and translation, then the same example calls as split mode.
//     Falls back to the split path when WordNet has no entry for the word.
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

extension PartOfSpeech {
    init(_ wordNet: WordNetPartOfSpeech) {
        switch wordNet {
        case .noun: self = .noun
        case .verb: self = .verb
        case .adjective: self = .adjective
        case .adverb: self = .adverb
        }
    }
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

// MARK: - Split path, verification: one yes/no call per sense

// Small models verify better than they generate (issue #4): the senses call pads
// `.count(1...3)` with paraphrases and inventions, so each sense is checked in its own
// cheap call before any example is written for it. Senses that get "no" are dropped.

let verificationInstructions = """
You check entries for a learner's dictionary of English.
You are given an English word, a part of speech and a short definition.
Answer whether the word is commonly used with exactly that part of speech and that meaning, as a learner's dictionary would list it.
Answer no for invented meanings, for rare or technical meanings, and when the part of speech is wrong for that meaning.
Answer yes or no only.
"""

func verificationPrompt(word: String, sense: GeneratedSenseCore) -> String {
    let article = ["a", "e", "i", "o", "u"].contains(String(sense.partOfSpeech.rawValue.prefix(1))) ? "an" : "a"
    return "Is the English word \"\(word)\" commonly used as \(article) \(sense.partOfSpeech.rawValue) meaning \"\(sense.definition)\"? Answer yes or no."
}

/// The verdict is a single `Bool`. Guided generation constrains the model to the JSON
/// boolean tokens, so there is nothing to parse and no "Yes."/"No, because…" to normalise;
/// a `String` with `.anyOf(["yes", "no"])` would work too but adds a string compare for no gain.
@Generable(description: "Verdict on whether one dictionary sense is real.")
struct SenseVerdict {
    @Guide(description: "true if the word is commonly used with this part of speech and this meaning; false otherwise.")
    var isCommonlyUsed: Bool
}

// MARK: - WordNet path: one writing call per WordNet sense

// WordNet supplies the sense (part of speech, gloss, synonyms, antonyms); the model is
// only asked to rewrite the terse gloss for a learner and to translate the word in that
// sense. Synonyms and antonyms on the card come from WordNet, never from this call.

let senseWritingInstructions = """
You write entries for a learner's dictionary of English. The learner's native language is Russian.
You are given one sense of an English word: the word, its part of speech, the dictionary gloss and its synonyms.
Write a learner-friendly definition of this sense: exactly one short English sentence in simple everyday words that explains the meaning. Rewrite the gloss in your own words; do not copy it and do not use the word itself in the definition.
Give the Russian translation of the word in this sense: 1 to 3 comma-separated equivalents, lowercase.
Stay with the given sense; do not describe other meanings of the word.
"""

func senseWritingPrompt(word: String, sense: WordNetSense) -> String {
    var lines = [
        "Word: \"\(word)\"",
        "Part of speech: \(sense.partOfSpeech.name)",
        "Dictionary gloss: \(sense.gloss)",
    ]
    if !sense.synonyms.isEmpty {
        lines.append("Synonyms: \(sense.synonyms.joined(separator: ", "))")
    }
    return lines.joined(separator: "\n")
}

@Generable(description: "Learner-facing text for one dictionary sense of an English word.")
struct SenseWriting {
    @Guide(description: "Learner-friendly definition of this sense in simple English, one short sentence, in your own words rather than the gloss.")
    var learnerDefinition: String

    @Guide(description: "Russian translation of the word in this sense: 1 to 3 comma-separated equivalents, lowercase.")
    var translation: String
}

// MARK: - Split path, calls 2…N: one example per (sense, topic)

let exampleInstructions = """
You write example sentences for a learner's dictionary of English.
Reply with exactly one complete, natural English sentence of 6 to 14 words.
The sentence must use the given word in the given sense and part of speech; an inflected form of the word is fine.
When a grammar topic is given, the sentence must clearly demonstrate that grammar.
When a grammar topic is given and the word in this sense cannot be used naturally in that grammar, return an empty string instead of forcing a sentence.
Do not explain, do not add quotes, do not write more than one sentence.
"""

/// Prompt for one example. The topic is chosen by the caller; `nil` means a neutral example.
/// The sense is passed as part of speech + definition so model-generated and WordNet
/// senses (with the model's learner definition) share one prompt.
func examplePrompt(word: String, partOfSpeech: PartOfSpeech, definition: String, topic: GrammarTopic?) -> String {
    var prompt = "Write one natural English sentence (6–14 words) using \"\(word)\" as a \(partOfSpeech.rawValue) in the sense \"\(definition)\""
    if let topic {
        prompt += " in the \(topic.name) (\(topic.description))."
        prompt += " If this sense cannot be used naturally in this grammar, return an empty string."
    } else {
        prompt += ". Use everyday language with no special grammar."
    }
    return prompt
}

@Generable(description: "One example sentence.")
struct GeneratedExampleText {
    @Guide(description: "A complete, natural English sentence using the word in the requested sense, 6 to 14 words. Empty only when the prompt allows it because the sense does not fit the requested grammar.")
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

/// Split path, verification. One fresh session per sense.
func verifySense(word: String, sense: GeneratedSenseCore) async throws -> ModelCallResult<SenseVerdict> {
    try await respond(
        instructions: verificationInstructions,
        prompt: verificationPrompt(word: word, sense: sense),
        generating: SenseVerdict.self,
        label: "verify \"\(word)\" as \(sense.partOfSpeech.rawValue): \(sense.definition)"
    )
}

/// WordNet path: learner definition + translation for one WordNet sense. One fresh session per sense.
func writeSense(word: String, sense: WordNetSense) async throws -> ModelCallResult<SenseWriting> {
    try await respond(
        instructions: senseWritingInstructions,
        prompt: senseWritingPrompt(word: word, sense: sense),
        generating: SenseWriting.self,
        label: "write \"\(word)\" as \(sense.partOfSpeech.name): \(sense.gloss)"
    )
}

/// Split and WordNet paths: one example. One fresh session per example.
func generateExample(
    word: String,
    partOfSpeech: PartOfSpeech,
    definition: String,
    topic: GrammarTopic?
) async throws -> ModelCallResult<GeneratedExampleText> {
    try await respond(
        instructions: exampleInstructions,
        prompt: examplePrompt(word: word, partOfSpeech: partOfSpeech, definition: definition, topic: topic),
        generating: GeneratedExampleText.self,
        label: "example for \"\(word)\" (\(partOfSpeech.rawValue)) / \(topic?.key ?? GrammarTopic.neutral.key)"
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
