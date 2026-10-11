// Phase 0 spike: offline sense inventory from the bundled Open English WordNet 2024
// (Resources/oewn-2024.json, CC BY 4.0, produced by tools/convert_oewn.py).
//
// The bundle gives, per lemma, the senses in WordNet order grouped by part of speech,
// each with a gloss, the synset's other members (synonyms) and antonyms. The model never
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
    /// The synset's `Definition` text, terse lexicographer English.
    let gloss: String
    /// Other members of the synset, in WordNet order; never contains the headword.
    let synonyms: [String]
    let antonyms: [String]
}

/// What the bundle knows about one headword.
struct WordNetEntry: Sendable {
    /// Senses in the bundle per part of speech (the bundle keeps at most
    /// `WordNetLookup.maxSensesPerPartOfSpeech` per part, so this is a floor, not WordNet's full count).
    let senseCounts: [(partOfSpeech: WordNetPartOfSpeech, count: Int)]
    /// The senses the card will show: up to `WordNetLookup.maxSensesPerPartOfSpeech` per part of
    /// speech, nouns first, then verbs, adjectives, adverbs.
    let top: [WordNetSense]

    var bundledSenseCount: Int { senseCounts.reduce(0) { $0 + $1.count } }
}

/// Loads the bundle once, on first use, on its own executor so the main actor never
/// waits for the JSON decode. The load time is printed.
actor WordNetLookup {
    static let shared = WordNetLookup()

    /// How many senses a card shows per part of speech (issue #11, decision 1: missing a real
    /// sense costs more than showing a spare one). The converter keeps this many per part.
    static let maxSensesPerPartOfSpeech = 2

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
        guard let groups = bundle.lemmas[key] else { return nil }

        // Up to `maxSensesPerPartOfSpeech` senses per part of speech, in WordNet rank order,
        // parts of speech in noun, verb, adjective, adverb order. For "book" that is noun 1,
        // noun 2, verb "engage for a performance", verb "reserve". Same policy as `top_senses`
        // in tools/convert_oewn.py.
        var counts: [(partOfSpeech: WordNetPartOfSpeech, count: Int)] = []
        var top: [WordNetSense] = []
        for partOfSpeech in WordNetPartOfSpeech.allCases {
            guard let refs = groups[partOfSpeech.rawValue], !refs.isEmpty else { continue }
            counts.append((partOfSpeech, refs.count))
            for ref in refs.prefix(Self.maxSensesPerPartOfSpeech) {
                let synset = bundle.synsets[ref.synset]
                top.append(WordNetSense(
                    partOfSpeech: partOfSpeech,
                    gloss: synset.gloss,
                    synonyms: synset.members.filter { Self.normalise($0) != key },
                    antonyms: ref.antonyms
                ))
            }
        }
        return WordNetEntry(senseCounts: counts, top: top)
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
    let lemmas: [String: [String: [WordNetSenseRef]]]

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

/// `[gloss]` or `[gloss, [member, ...]]`.
private struct WordNetSynset: Sendable, Decodable {
    let gloss: String
    let members: [String]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        gloss = try container.decode(String.self)
        members = container.isAtEnd ? [] : try container.decode([String].self)
    }
}

/// A synset index, or `[index, [antonym, ...]]` when the sense has antonyms.
private struct WordNetSenseRef: Sendable, Decodable {
    let synset: Int
    let antonyms: [String]

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let index = try? single.decode(Int.self) {
            synset = index
            antonyms = []
        } else {
            var container = try decoder.unkeyedContainer()
            synset = try container.decode(Int.self)
            antonyms = try container.decode([String].self)
        }
    }
}
