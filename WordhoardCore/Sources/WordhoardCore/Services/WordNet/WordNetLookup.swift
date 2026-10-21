import Foundation
import os

/// Offline sense inventory from the bundled Open English WordNet 2024 (`Resources/WordNet/oewn-2024.json`,
/// CC BY 4.0, produced by `spike/tools/convert_oewn.py`) and the closed-class stoplist
/// (`function-words.txt`). ADR 0001 point 1: when WordNet knows the lemma its senses are the only senses.
///
/// **Isolation: actor.** The 15 MB bundle is decoded once, lazily, on a detached task, so neither the
/// main actor nor the actor's own executor waits for it twice. A missing or undecodable bundle is logged
/// at `.fault` and every lookup then answers `nil` / `false` — the generator takes the model-only path;
/// the app never crashes over the bundle. The load time is logged at `.info`.
public actor WordNetLookup {
    /// The lookup over the package's own resources.
    public static let shared = WordNetLookup(bundle: .module)

    /// How many senses the default selection keeps per part of speech (ADR 0001: missing a real sense
    /// costs more than showing a spare one). The converter keeps this many per part in the bundle.
    public static let maxSensesPerPartOfSpeech = 2
    /// How many senses the default selection keeps in all (1 ≤ senses ≤ 4, five model calls per sense).
    public static let maxSensesTotal = 4

    /// The resource subdirectory, the same on the macOS host and inside the app bundle (`.copy`).
    static let subdirectory = "WordNet"
    static let bundleResource = "oewn-2024"
    static let stoplistResource = "function-words"

    private static let logger = Logger(subsystem: "Wordhoard", category: "wordnet")

    /// Part-of-speech codes in the bundle, in the order senses are listed and regrouped.
    private static let bundledPartsOfSpeech: [(code: String, partOfSpeech: PartOfSpeech)] = [
        ("n", .noun), ("v", .verb), ("a", .adjective), ("r", .adverb),
    ]

    private enum LoadState {
        case notLoaded
        case loading(Task<WordNetBundle?, Never>)
        case loaded(WordNetBundle?)
    }

    private let bundle: Bundle
    private var loadState: LoadState = .notLoaded
    private var functionWords: Set<String>?

    /// `bundle` holds `WordNet/oewn-2024.json` and `WordNet/function-words.txt`; tests may point at a
    /// directory with a tiny or broken copy.
    public init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// Starts loading the bundle so the first lookup does not pay for it. Called once at launch (2.3).
    public func warmUp() async {
        _ = await loadedBundle()
    }

    /// Whether the headword is on the closed-class stoplist: determiners, pronouns, prepositions,
    /// conjunctions, auxiliaries, discourse adverbs. WordNet is useless or misleading for these, so the
    /// generator takes the model-only path without consulting the bundle.
    public func isFunctionWord(_ headword: String) -> Bool {
        if functionWords == nil {
            functionWords = loadFunctionWords()
        }
        return functionWords?.contains(Self.normalize(headword)) ?? false
    }

    /// Every bundled sense of the lemma and the default selection, or `nil` when the bundle has no
    /// entry for it (or failed to load).
    public func entry(for headword: String) async -> WordNetEntry? {
        guard let bundle = await loadedBundle() else { return nil }
        let key = Self.normalize(headword)
        guard let groups = bundle.lemmas[key] else { return nil }

        var senses: [WordNetSense] = []
        for (code, partOfSpeech) in Self.bundledPartsOfSpeech {
            for ref in groups[code] ?? [] where bundle.synsets.indices.contains(ref.synset) {
                let synset = bundle.synsets[ref.synset]
                senses.append(WordNetSense(
                    partOfSpeech: partOfSpeech,
                    gloss: synset.gloss,
                    synonyms: synset.members.filter { Self.normalize($0) != key },
                    antonyms: ref.antonyms,
                    example: synset.examples.first
                ))
            }
        }
        guard !senses.isEmpty else { return nil }
        return WordNetEntry(senses: senses, selected: Self.select(senses))
    }

    /// The default selection, pure: rank 1 of every part of speech (nouns → verbs → adjectives →
    /// adverbs) before any rank 2, at most `maxSensesPerPartOfSpeech` per part and `maxSensesTotal` in
    /// all, returned regrouped by part of speech with each part's senses in rank order. For *book* that
    /// is noun 1, noun 2, verb *engage for a performance*, verb *reserve*; for *light* one of each.
    /// Same policy as `top_senses` in `spike/tools/convert_oewn.py`.
    public static func select(_ senses: [WordNetSense]) -> [WordNetSense] {
        var groups: [PartOfSpeech: [WordNetSense]] = [:]
        for sense in senses {
            groups[sense.partOfSpeech, default: []].append(sense)
        }
        var kept: [Ranked] = []
        for rank in 0 ..< maxSensesPerPartOfSpeech {
            for (position, partOfSpeech) in PartOfSpeech.allCases.enumerated() {
                guard kept.count < maxSensesTotal else { break }
                guard let group = groups[partOfSpeech], rank < group.count else { continue }
                kept.append(Ranked(position: position, rank: rank, sense: group[rank]))
            }
        }
        return kept
            .sorted { ($0.position, $0.rank) < ($1.position, $1.rank) }
            .map(\.sense)
    }

    /// A kept sense with its part-of-speech position and rank, for `select`'s regrouping.
    private struct Ranked {
        var position: Int
        var rank: Int
        var sense: WordNetSense
    }

    /// Lowercase, underscores to spaces, single spaces, trimmed — the converter's `normalise`. Agrees
    /// with `Word.normalize` for ASCII input.
    public static func normalize(_ headword: String) -> String {
        headword
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - Loading

    private func loadedBundle() async -> WordNetBundle? {
        switch loadState {
        case let .loaded(bundle):
            return bundle
        case let .loading(task):
            return await task.value
        case .notLoaded:
            let url = bundle.url(
                forResource: Self.bundleResource,
                withExtension: "json",
                subdirectory: Self.subdirectory
            )
            let task = Task.detached(priority: .userInitiated) { WordNetBundle.load(from: url) }
            loadState = .loading(task)
            let loaded = await task.value
            loadState = .loaded(loaded)
            return loaded
        }
    }

    /// `function-words.txt`: one lemma per line, lowercase, `#` starts a comment, blank lines skipped.
    /// Same parsing as `load_function_words` in `spike/tools/convert_oewn.py`, so `--check` and the app agree.
    private func loadFunctionWords() -> Set<String> {
        guard let url = bundle.url(
            forResource: Self.stoplistResource, withExtension: "txt", subdirectory: Self.subdirectory
        ) else {
            Self.logger.fault("function-words.txt is missing from the resource bundle; no stoplist")
            return []
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var words: Set<String> = []
            for line in text.split(whereSeparator: \.isNewline) {
                let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let key = Self.normalize(String(content))
                if !key.isEmpty {
                    words.insert(key)
                }
            }
            Self.logger.info("Loaded function-words.txt: \(words.count, privacy: .public) function words")
            return words
        } catch {
            Self.logger.fault("function-words.txt failed to load: \(error, privacy: .public)")
            return []
        }
    }
}

// MARK: - Bundle decoding

/// The on-disk shape written by `convert_oewn.py`: `synsets` indexed by position and `lemmas` keyed
/// by normalized lemma, each mapping a part-of-speech code to its sense references in rank order.
private struct WordNetBundle: Sendable, Decodable {
    let edition: String
    let synsets: [WordNetSynset]
    let lemmas: [String: [String: [WordNetSenseRef]]]

    private static let logger = Logger(subsystem: "Wordhoard", category: "wordnet")

    static func load(from url: URL?) -> WordNetBundle? {
        guard let url else {
            logger.fault("oewn-2024.json is missing from the resource bundle; WordNet lookups answer nil")
            return nil
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let data = try Data(contentsOf: url)
            let bundle = try JSONDecoder().decode(WordNetBundle.self, from: data)
            let milliseconds = (clock.now - start).components.attoseconds / 1_000_000_000_000_000
                + (clock.now - start).components.seconds * 1000
            logger.info(
                """
                Loaded \(bundle.edition, privacy: .public): \(bundle.lemmas.count, privacy: .public) lemmas, \
                \(bundle.synsets.count, privacy: .public) synsets, \(data.count / 1024, privacy: .public) KB \
                in \(milliseconds, privacy: .public) ms
                """
            )
            return bundle
        } catch {
            logger.fault("oewn-2024.json failed to load: \(error, privacy: .public); WordNet lookups answer nil")
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
