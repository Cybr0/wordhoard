import Foundation
import Observation
import os

/// One topic on the Topics screen with how many examples carry its key.
public struct TopicRow: Equatable, Sendable, Identifiable {
    public let topic: GrammarTopic
    public let exampleCount: Int

    public var id: GrammarTopicID {
        topic.key
    }

    public init(topic: GrammarTopic, exampleCount: Int) {
        self.topic = topic
        self.exampleCount = exampleCount
    }
}

/// One word on a topic screen with its examples for that topic, in sense then example order. Holds
/// `@Model` objects, so it is not `Sendable`; main-actor only, like `WordListModel.words`.
public struct TopicWordGroup: Identifiable {
    public let word: Word
    public let examples: [Example]

    public var id: UUID {
        word.id
    }
}

/// State for browsing by grammar topic (G3, B2, G4; plans 3.3, 3.4): the Topics screen's two sections and
/// one topic's examples grouped by word.
///
/// **Isolation: `@MainActor`**, like the `WordStore` it reads. `load()` asks the store for one count per
/// catalog topic (`WordStore.exampleCounts(for:)`) and `groups(for:)` fetches only that topic's examples
/// (`WordStore.examples(forTopic:)`), so neither walks the hoard (#61). Counting rule: every example whose
/// `grammarTopic` equals a catalog key, whatever its `source`, on an active word; keys the catalog does
/// not know are counted and listed nowhere.
@MainActor
@Observable
public final class TopicBrowseModel {
    /// Something the store could not do. The view shows an alert and sets this back to `nil` on dismiss.
    public enum Failure: Equatable, Sendable {
        /// `load()` or `groups(for:)` could not read; the previous rows or groups are kept.
        case loading
    }

    public let catalog: GrammarCatalog

    /// Every active topic in catalog order, including those with no example yet.
    public private(set) var active: [TopicRow] = []

    /// Inactive topics that still have examples, in catalog order, so deselecting a topic never hides
    /// its examples from browse.
    public private(set) var other: [TopicRow] = []

    public var failure: Failure?

    /// The last groups read per key, returned again when a later read fails.
    @ObservationIgnored
    private var lastGroups: [GrammarTopicID: [TopicWordGroup]] = [:]

    private let readActiveTopics: @MainActor () throws -> [GrammarTopicID]
    private let readCounts: @MainActor ([GrammarTopicID]) throws -> [GrammarTopicID: Int]
    private let readExamples: @MainActor (GrammarTopicID) throws -> [Example]
    private let logger = Logger(subsystem: "Wordhoard", category: "topics")

    public convenience init(store: WordStore, catalog: GrammarCatalog = .english) {
        self.init(
            catalog: catalog,
            activeTopics: { try store.settings().activeGrammarTopics },
            exampleCounts: { try store.exampleCounts(for: $0) },
            examples: { try store.examples(forTopic: $0) }
        )
    }

    /// The readers as closures, so a test can make a read fail (`WordStore` is final).
    package init(
        catalog: GrammarCatalog,
        activeTopics: @escaping @MainActor () throws -> [GrammarTopicID],
        exampleCounts: @escaping @MainActor ([GrammarTopicID]) throws -> [GrammarTopicID: Int],
        examples: @escaping @MainActor (GrammarTopicID) throws -> [Example]
    ) {
        self.catalog = catalog
        readActiveTopics = activeTopics
        readCounts = exampleCounts
        readExamples = examples
    }

    /// The 3.3 test seam: every read derived from a list of words walked in memory, so a test can make
    /// the word read fail. Production uses the store's queries through `init(store:catalog:)`.
    package convenience init(
        catalog: GrammarCatalog,
        activeTopics: @escaping @MainActor () throws -> [GrammarTopicID],
        words: @escaping @MainActor () throws -> [Word]
    ) {
        let matching = { @MainActor (key: GrammarTopicID) throws -> [Example] in
            try words().flatMap { word in
                word.senses.flatMap { sense in sense.examples.filter { $0.grammarTopic == key } }
            }
        }
        self.init(
            catalog: catalog,
            activeTopics: activeTopics,
            exampleCounts: { keys in
                try Dictionary(uniqueKeysWithValues: keys.map { try ($0, matching($0).count) })
            },
            examples: matching
        )
    }

    /// Re-reads the settings and the counts. On error `failure = .loading` and the previous rows are kept.
    public func load() {
        let activeKeys: Set<GrammarTopicID>
        let counts: [GrammarTopicID: Int]
        do {
            activeKeys = try Set(readActiveTopics())
            counts = try readCounts(catalog.topics.map(\.key))
        } catch {
            logger.error("Could not load topics: \(error.localizedDescription, privacy: .public)")
            failure = .loading
            return
        }
        let rows = catalog.topics.map { TopicRow(topic: $0, exampleCount: counts[$0.key] ?? 0) }
        active = rows.filter { activeKeys.contains($0.id) }
        other = rows.filter { !activeKeys.contains($0.id) && $0.exampleCount > 0 }
    }

    /// The words that have at least one example with `key`, newest first (`createdAt` descending, `id` as
    /// tie-break, as `WordStore.words()`), each with only those examples in sense then example order. A key
    /// the catalog does not know → `[]`. On error `failure = .loading` and the last groups for `key` are
    /// returned.
    public func groups(for key: GrammarTopicID) -> [TopicWordGroup] {
        guard catalog.topic(for: key) != nil else {
            return []
        }
        let examples: [Example]
        do {
            examples = try readExamples(key)
        } catch {
            logger.error("Could not load the topic's examples: \(error.localizedDescription, privacy: .public)")
            failure = .loading
            return lastGroups[key] ?? []
        }
        // Only the fetched examples are read, so a word's other senses and examples stay faults.
        var byWord: [UUID: (word: Word, examples: [Positioned])] = [:]
        for example in examples {
            guard let sense = example.sense, let word = sense.word, word.deletedAt == nil else {
                continue
            }
            let positioned = Positioned(sense: sense.order, order: example.order, example: example)
            byWord[word.id, default: (word, [])].examples.append(positioned)
        }
        let ordered = byWord.values.sorted { lhs, rhs in
            lhs.word.createdAt != rhs.word.createdAt
                ? lhs.word.createdAt > rhs.word.createdAt
                : lhs.word.id.uuidString < rhs.word.id.uuidString
        }
        let groups = ordered.map { entry in
            TopicWordGroup(
                word: entry.word,
                examples: entry.examples.sorted { ($0.sense, $0.order) < ($1.sense, $1.order) }.map(\.example)
            )
        }
        lastGroups[key] = groups
        return groups
    }

    /// An example with the two positions `groups(for:)` sorts by.
    private struct Positioned {
        let sense: Int
        let order: Int
        let example: Example
    }
}
