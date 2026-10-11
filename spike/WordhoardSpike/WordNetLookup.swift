// Phase 0 spike: offline sense inventory from the bundled Open English WordNet 2024
// (Resources/oewn-2024.json, CC BY 4.0, produced by tools/convert_oewn.py).
//
// The bundle gives, per lemma, up to four senses ranked by SemCor tag count across all parts of
// speech (issue #14, decision B; WordNet order for lemmas without counts — see
// tools/convert_oewn.py), each with its part of speech, count, gloss, the synset's other members
// (synonyms), antonyms and the synset's example sentence. The model never
// sees this file; CardGenerationModel asks it for a headword's senses and lets the model
// write the learner definition, translation and examples for each one (issue #11).
//
// Headwords on the closed-class stoplist (Resources/function-words.txt) never reach the
// bundle: `isFunctionWord` says so and CardGenerationModel takes the model-only path.
//
// No FoundationModels import here on purpose. Throwaway code.

import Foundation

/// WordNet parts of speech; satellite adjectives are folded into `adjective` by the converter.
enum WordNetPartOfSpeech: String, Sendable, CaseIterable {
    case noun = "n"
    case verb = "v"
    case adjective = "a"
    case adverb = "r"

    var name: String {
        switch self {
        case .noun: "noun"
        case .verb: "verb"
        case .adjective: "adjective"
        case .adverb: "adverb"
        }
    }
}

/// One WordNet sense of a headword, ready to be handed to the model for writing.
struct WordNetSense: Sendable {
    let partOfSpeech: WordNetPartOfSpeech
    /// SemCor tag count of this sense (0 when the corpus never tagged it); the rank key.
    let count: Int
    /// The synset's `Definition` text, terse lexicographer English.
    let gloss: String
    /// Other members of the synset, in WordNet order; never contains the headword.
    let synonyms: [String]
    let antonyms: [String]
    /// The synset's example sentences from the release (the bundle keeps at most one). They may
    /// use a synonym rather than the headword; they go into the writing prompt so the model does
    /// not misread a terse gloss ("engage for a performance" was read as *rehearse*).
    let examples: [String]
}

/// What the bundle knows about one headword.
struct WordNetEntry: Sendable {
    /// Senses in the bundle per part of speech (the bundle keeps at most
    /// `WordNetLookup.maxSensesTotal` per lemma, so this is a floor, not WordNet's full count).
    let senseCounts: [(partOfSpeech: WordNetPartOfSpeech, count: Int)]
    /// The senses the card will show, in the bundle's rank order (SemCor count, highest first).
    let top: [WordNetSense]
    /// Whether `top` is ranked by count (false: WordNet-order fallback, no SemCor count for the lemma).
    let rankedByCount: Bool

    var bundledSenseCount: Int { senseCounts.reduce(0) { $0 + $1.count } }
}

/// Loads the bundle once, on first use, on its own executor so the main actor never
/// waits for the JSON decode. The load time is printed.
actor WordNetLookup {
    static let shared = WordNetLookup()

    /// How many senses a card shows (issue #14: 1 ≤ senses ≤ 4, and five model calls per sense).
    /// The converter already ranks and caps the bundle's list; this is the display cap.
    static let maxSensesTotal = 4

    private var bundle: WordNetBundle?
    private var loadTask: Task<WordNetBundle?, Never>?
    private var functionWords: FunctionWords?

    /// Starts loading in the background so the first lookup does not pay for it.
    func warmUp() async {
        _ = await loadedBundle()
    }

    /// Whether the headword is on the closed-class stoplist (`function-words.txt`): determiners,
    /// pronouns, prepositions, conjunctions, auxiliaries, discourse adverbs. WordNet is useless
    /// or misleading for these, so the caller takes the model-only path (issue #11, decision 3).
    func isFunctionWord(_ headword: String) -> Bool {
        if functionWords == nil { functionWords = FunctionWords.load() }
        return functionWords?.contains(headword) ?? false
    }

    /// The top senses for a headword, or `nil` when WordNet has no entry for it.
    func senses(for headword: String) async -> [WordNetSense]? {
        await entry(for: headword)?.top
    }

    func entry(for headword: String) async -> WordNetEntry? {
        guard let bundle = await loadedBundle() else { return nil }
        let key = Self.normalise(headword)
        guard let refs = bundle.lemmas[key], !refs.isEmpty else { return nil }

        // The bundle's list is already ranked (SemCor count across parts of speech, WordNet order
        // when the lemma has no counts) and capped by the converter; show its first
        // `maxSensesTotal` rows as they are. For "run" that is four verbs (move fast, flee, extend,
        // direct or control); for "book" three nouns and the verb "engage for a performance".
        var counts: [(partOfSpeech: WordNetPartOfSpeech, count: Int)] = []
        for partOfSpeech in WordNetPartOfSpeech.allCases {
            let total = refs.filter { $0.partOfSpeech == partOfSpeech }.count
            if total > 0 { counts.append((partOfSpeech, total)) }
        }
        let top = refs.prefix(Self.maxSensesTotal).map { ref in
            let synset = bundle.synsets[ref.synset]
            return WordNetSense(
                partOfSpeech: ref.partOfSpeech,
                count: ref.count,
                gloss: synset.gloss,
                synonyms: synset.members.filter { Self.normalise($0) != key },
                antonyms: ref.antonyms,
                examples: synset.examples
            )
        }
        return WordNetEntry(senseCounts: counts, top: top, rankedByCount: top.contains { $0.count > 0 })
    }

    /// Trim, lowercase, underscores to spaces, single spaces — the converter's `normalise`.
    static func normalise(_ headword: String) -> String {
        headword
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private func loadedBundle() async -> WordNetBundle? {
        if let bundle { return bundle }
        if let loadTask { return await loadTask.value }
        let task = Task.detached(priority: .userInitiated) { WordNetBundle.load() }
        loadTask = task
        let loaded = await task.value
        bundle = loaded
        loadTask = nil
        return loaded
    }
}

// MARK: - Function-word stoplist

/// `function-words.txt`: one lemma per line, lowercase, `#` starts a comment. Same parsing as
/// `load_function_words` in tools/convert_oewn.py, so `--check` and the app agree.
private struct FunctionWords: Sendable {
    let words: Set<String>

    func contains(_ headword: String) -> Bool {
        words.contains(WordNetLookup.normalise(headword))
    }

    static func load() -> FunctionWords? {
        guard let url = Bundle.main.url(forResource: "function-words", withExtension: "txt") else {
            print("WordNet: function-words.txt missing from the app bundle, no stoplist")
            return nil
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var words: Set<String> = []
            for line in text.split(whereSeparator: \.isNewline) {
                let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let key = WordNetLookup.normalise(String(content))
                if !key.isEmpty { words.insert(key) }
            }
            print("WordNet: loaded function-words.txt, \(words.count) function words")
            return FunctionWords(words: words)
        } catch {
            print("WordNet: failed to load function-words.txt: \(error)")
            return nil
        }
    }
}

// MARK: - Bundle decoding

private struct WordNetBundle: Sendable, Decodable {
    let edition: String
    let synsets: [WordNetSynset]
    /// Lemma key → its senses in rank order (the converter's `rank_senses`).
    let lemmas: [String: [WordNetSenseRef]]

    static func load() -> WordNetBundle? {
        guard let url = Bundle.main.url(forResource: "oewn-2024", withExtension: "json") else {
            print("WordNet: oewn-2024.json missing from the app bundle")
            return nil
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let data = try Data(contentsOf: url)
            let bundle = try JSONDecoder().decode(WordNetBundle.self, from: data)
            let elapsed = clock.now - start
            print("WordNet: loaded \(bundle.edition), \(bundle.lemmas.count) lemmas, \(bundle.synsets.count) synsets, \(data.count / 1024) KB in \(elapsed.spikeFormatted)")
            return bundle
        } catch {
            print("WordNet: failed to load oewn-2024.json: \(error)")
            return nil
        }
    }
}

/// `[gloss]`, `[gloss, [member, ...]]` or `[gloss, [member, ...], [example, ...]]`
/// (the member list may be empty in the third form).
private struct WordNetSynset: Sendable, Decodable {
    let gloss: String
    let members: [String]
    let examples: [String]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        gloss = try container.decode(String.self)
        members = container.isAtEnd ? [] : try container.decode([String].self)
        examples = container.isAtEnd ? [] : try container.decode([String].self)
    }
}

/// `[synset, pos]`, `[synset, pos, count]` or `[synset, pos, count, [antonym, ...]]`;
/// pos is 0 noun, 1 verb, 2 adjective, 3 adverb.
private struct WordNetSenseRef: Sendable, Decodable {
    let synset: Int
    let partOfSpeech: WordNetPartOfSpeech
    let count: Int
    let antonyms: [String]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        synset = try container.decode(Int.self)
        let code = try container.decode(Int.self)
        guard WordNetPartOfSpeech.allCases.indices.contains(code) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "part of speech code \(code)")
        }
        partOfSpeech = WordNetPartOfSpeech.allCases[code]
        count = container.isAtEnd ? 0 : try container.decode(Int.self)
        antonyms = container.isAtEnd ? [] : try container.decode([String].self)
    }
}
