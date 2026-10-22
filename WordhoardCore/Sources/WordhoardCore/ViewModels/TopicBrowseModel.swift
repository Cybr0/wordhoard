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

/// State for browsing by grammar topic (G3, B2, G4; plan 3.3): the Topics screen's two sections and one
/// topic's examples grouped by word.
///
/// **Isolation: `@MainActor`**, like the `WordStore` it reads. No new store API and no query on
/// `Example`: `load()` walks `store.words()` (active words, newest first) and their relationships in
/// memory. Counting rule: every example whose `grammarTopic` equals a catalog key, whatever its `source`;
/// keys the catalog does not know are counted and listed nowhere.
@MainActor
@Observable
public final class TopicBrowseModel {
    /// Something the store could not do. The view shows an alert and sets this back to `nil` on dismiss.
    public enum Failure: Equatable, Sendable {
        /// `load()` could not read; the previous rows are kept.
        case loading
    }

    public let catalog: GrammarCatalog

    /// Every active topic in catalog order, including those with no example yet.
    public private(set) var active: [TopicRow] = []

    /// Inactive topics that still have examples, in catalog order, so deselecting a topic never hides
    /// its examples from browse.
    public private(set) var other: [TopicRow] = []

    public var failure: Failure?

    /// The words the last `load()` read; `groups(for:)` is computed from them.
    private var words: [Word] = []

    private let readActiveTopics: @MainActor () throws -> [GrammarTopicID]
    private let readWords: @MainActor () throws -> [Word]
    private let logger = Logger(subsystem: "Wordhoard", category: "topics")

    public convenience init(store: WordStore, catalog: GrammarCatalog = .english) {
        self.init(
            catalog: catalog,
            activeTopics: { try store.settings().activeGrammarTopics },
            words: { try store.words() }
        )
    }

    /// The readers as closures, so a test can make a read fail (`WordStore` is final).
    package init(
        catalog: GrammarCatalog,
        activeTopics: @escaping @MainActor () throws -> [GrammarTopicID],
        words: @escaping @MainActor () throws -> [Word]
    ) {
        self.catalog = catalog
        readActiveTopics = activeTopics
        readWords = words
    }

    /// Re-reads the settings and the words and recounts. On error `failure = .loading` and the previous
    /// rows and groups are kept.
    public func load() {
        let activeKeys: Set<GrammarTopicID>
        let words: [Word]
        do {
            activeKeys = try Set(readActiveTopics())
            words = try readWords()
        } catch {
            logger.error("Could not load topics: \(error.localizedDescription, privacy: .public)")
            failure = .loading
            return
        }
        var counts: [GrammarTopicID: Int] = [:]
        for word in words {
            for sense in word.senses {
                for example in sense.examples {
                    if let key = example.grammarTopic {
                        counts[key, default: 0] += 1
                    }
                }
            }
        }
        let rows = catalog.topics.map { TopicRow(topic: $0, exampleCount: counts[$0.key] ?? 0) }
        active = rows.filter { activeKeys.contains($0.id) }
        other = rows.filter { !activeKeys.contains($0.id) && $0.exampleCount > 0 }
        self.words = words
    }

    /// The words from the last `load()` that have at least one example with `key`, newest first, each
    /// with only those examples in sense then example order. A key the catalog does not know → `[]`.
    public func groups(for key: GrammarTopicID) -> [TopicWordGroup] {
        guard catalog.topic(for: key) != nil else {
            return []
        }
        return words.compactMap { word in
            let examples = word.sortedSenses.flatMap { sense in
                sense.sortedExamples.filter { $0.grammarTopic == key }
            }
            return examples.isEmpty ? nil : TopicWordGroup(word: word, examples: examples)
        }
    }
}
