import Foundation
import os

/// One sense from the bundled Simple English Wiktionary (Phase 7): a learner-written definition in
/// page order, so the most common meaning comes first.
public struct WiktionarySense: Equatable, Sendable {
    public var partOfSpeech: PartOfSpeech
    /// The learner definition as Simple Wiktionary writes it ("If you run a place, you manage it.").
    public var gloss: String
    /// A sentence written by Wiktionary's editors, when the sense has one.
    public var example: String?
    public var synonyms: [String]
    public var antonyms: [String]

    public init(
        partOfSpeech: PartOfSpeech,
        gloss: String,
        example: String? = nil,
        synonyms: [String] = [],
        antonyms: [String] = []
    ) {
        self.partOfSpeech = partOfSpeech
        self.gloss = gloss
        self.example = example
        self.synonyms = synonyms
        self.antonyms = antonyms
    }
}

/// The bundled Simple English Wiktionary (CC BY-SA 4.0; `tools/convert_simplewikt.py`; NOTICE) as the
/// card's first sense source (Phase 7, owner feedback 2026-10-23): its senses are in everyday-frequency
/// order and written for learners, which WordNet's order and the on-device model's ranking were not.
///
/// **Isolation: actor.** The bundle (about 7 MB) is decoded once, on first use, off the main actor. A
/// missing or broken bundle answers `nil`, so the generator falls back to WordNet; it never crashes.
public actor WiktionaryLookup {
    public static let shared = WiktionaryLookup(bundle: .module)

    static let subdirectory = "Wiktionary"
    static let bundleResource = "simplewikt"

    private static let logger = Logger(subsystem: "Wordhoard", category: "wiktionary")

    private let bundle: Bundle?
    private var lemmas: [String: [WiktionarySense]]?
    /// Inflected forms with no meaning of their own, pointing at the base word ("ran" → "run").
    private var aliases: [String: String] = [:]

    /// `bundle` holds `Wiktionary/simplewikt.json`.
    public init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// An in-memory lookup for tests and previews; `[:]` is a lookup that knows no word.
    public init(entries: [String: [WiktionarySense]]) {
        bundle = nil
        lemmas = Dictionary(uniqueKeysWithValues: entries.map { (WordNetLookup.normalize($0.key), $0.value) })
    }

    /// Decodes the bundle now, so the first card does not pay for it. Called once at launch.
    public func warmUp() {
        _ = loaded()
    }

    /// Every sense of the headword in page order — the meanings in use, most common first; old, rare and
    /// specialised senses were left out when the bundle was built (`tools/convert_simplewikt.py`). No cap
    /// on the count (owner, 2026-10-23). An inflected form reads its base word's senses ("ran" → "run").
    /// `nil` when the bundle does not know the word.
    public func senses(for headword: String) -> [WiktionarySense]? {
        let all = loaded()
        let key = WordNetLookup.normalize(headword)
        guard let senses = all[key] ?? aliases[key].flatMap({ all[$0] }), !senses.isEmpty else {
            return nil
        }
        return senses
    }

    // MARK: - Loading

    private func loaded() -> [String: [WiktionarySense]] {
        if let lemmas {
            return lemmas
        }
        let decoded = Self.load(from: bundle)
        lemmas = decoded?.lemmas ?? [:]
        aliases = decoded?.aliases ?? [:]
        return lemmas ?? [:]
    }

    private typealias Loaded = (lemmas: [String: [WiktionarySense]], aliases: [String: String])

    private static func load(from bundle: Bundle?) -> Loaded? {
        guard let bundle else {
            return nil
        }
        guard let url = bundle.url(forResource: bundleResource, withExtension: "json", subdirectory: subdirectory)
        else {
            logger.fault("simplewikt.json is missing from the resource bundle; WordNet only")
            return nil
        }
        do {
            let start = ContinuousClock.now
            let file = try JSONDecoder().decode(WiktionaryBundle.self, from: Data(contentsOf: url))
            let lemmas = file.lemmas.mapValues { rows in rows.compactMap(\.sense) }
            logger.info(
                """
                Loaded \(file.edition, privacy: .public): \(lemmas.count, privacy: .public) lemmas in \
                \(String(describing: ContinuousClock.now - start), privacy: .public)
                """
            )
            return (lemmas, file.aliases ?? [:])
        } catch {
            logger.fault("simplewikt.json failed to decode: \(error, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Bundle decoding

/// The on-disk shape written by `tools/convert_simplewikt.py`.
private struct WiktionaryBundle: Decodable {
    let edition: String
    let lemmas: [String: [WiktionaryRow]]
    let aliases: [String: String]?
}

/// `[part-of-speech code, gloss, example | null, [synonym], [antonym]]`.
private struct WiktionaryRow: Decodable {
    let code: String
    let gloss: String
    let example: String?
    let synonyms: [String]
    let antonyms: [String]

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        code = try row.decode(String.self)
        gloss = try row.decode(String.self)
        example = try row.decodeIfPresent(String.self)
        synonyms = try row.decode([String].self)
        antonyms = try row.decode([String].self)
    }

    /// Part-of-speech codes from the converter: n v a r p(reposition) c(onjunction) h (phrase) o(ther).
    var sense: WiktionarySense? {
        let partOfSpeech: PartOfSpeech? = switch code {
        case "n": .noun
        case "v": .verb
        case "a": .adjective
        case "r": .adverb
        case "p": .preposition
        case "c": .conjunction
        case "h": .phrase
        case "o": .other
        default: nil
        }
        guard let partOfSpeech else {
            return nil
        }
        return WiktionarySense(
            partOfSpeech: partOfSpeech,
            gloss: gloss,
            example: example,
            synonyms: synonyms,
            antonyms: antonyms
        )
    }
}
