import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Edge cases issue #36 implies but does not spell out: id collisions across words, unvalidated settings
/// keys, settings-only files, hand senses with provenance keys this build does not use, dates with a
/// non-UTC offset, re-importing an older export over a local rename, a revived tombstone as the store
/// sees it afterwards, and a thousand-word file within seconds.
@MainActor
@Suite("Importer edge cases")
struct ImporterEdgeCaseTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func importing(_ document: ExportDocument) throws -> ImportSummary {
        try Importer.import(document.encode(), into: store)
    }

    private func export(_ store: WordStore) throws -> Data {
        try Exporter.export(from: store, exportedAt: TransferFixture.exportedAt, appVersion: TransferFixture.appVersion)
    }

    @Test("an example id already used under another local word is inserted under a fresh id")
    func anExampleIdTakenByAnotherWordGetsAFreshId() throws {
        let apple = try store.add("apple").word
        let appleSense = Sense(partOfSpeech: .noun, definition: "a fruit", order: 0)
        let taken = Example(text: "An apple a day.", source: .user, order: 0)
        appleSense.examples = [taken]
        apple.senses = [appleSense]
        try store.save(apple)

        let fileExample = makeExample(id: taken.id, text: "I booked a table.")
        let document = makeDocument(words: [makeWord(headword: "book", senses: [makeSense(examples: [fileExample])])])
        let summary = try importing(document)

        #expect(summary.examplesCreated == 1)
        #expect(summary.examplesUpdated == 0)
        let book = try #require(try store.activeWord(normalized: "book"))
        let imported = try #require(book.sortedSenses.first?.sortedExamples.first)
        #expect(imported.id != taken.id)
        #expect(imported.text == "I booked a table.")
        #expect(taken.text == "An apple a day.", "the other word's example is untouched")
        #expect(appleSense.sortedExamples.map(\.id) == [taken.id])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Example>()) == 2)
    }

    @Test("duplicate and unknown active grammar topics are stored verbatim, not validated")
    func duplicateAndUnknownActiveGrammarTopicsImportVerbatim() throws {
        let topics: [GrammarTopicID] = ["en.present_perfect", "en.present_perfect", "en.not_yet", ""]
        let document = makeDocument(words: [], settings: makeSettings(activeGrammarTopics: topics))

        let summary = try importing(document)

        #expect(summary.settingsChanged)
        #expect(try store.settings().activeGrammarTopics == topics)
        #expect(try importing(document) == .nothing)
        #expect(try ExportDocument.decode(export(store)).settings.activeGrammarTopics == topics)
    }

    @Test("a file with no words applies the settings and nothing else")
    func aFileWithNoWordsAppliesOnlySettings() throws {
        _ = try store.add("book")
        _ = try store.settings()
        let before = try RowCounts(in: container)
        let document = makeDocument(words: [], settings: makeSettings(nativeLanguage: "es", autoGenerateImages: false))

        let summary = try importing(document)

        var expected = ImportSummary.nothing
        expected.settingsChanged = true
        #expect(summary == expected)
        #expect(try RowCounts(in: container) == before)
        #expect(try store.settings().nativeLanguage == "es")
        #expect(try store.settings().autoGenerateImages == false)
        #expect(try store.words().map(\.headword) == ["book"], "existing words are neither removed nor touched")
    }

    @Test("a hand-added sense with no senseSource and an unknown fieldSources key round-trips")
    func aHandSenseWithUnknownFieldSourceKeysRoundTrips() throws {
        let book = try store.add("book").word
        let hand = Sense(
            partOfSpeech: .verb,
            definition: "to reserve",
            order: 0,
            fieldSources: ["definition": .user, "colour": .user, "": .auto]
        )
        book.senses = [hand]
        try store.save(book)
        try store.transaction { _ in
            book.createdAt = TransferFixture.bookCreatedAt
            book.updatedAt = TransferFixture.bookUpdatedAt
        }

        let data = try export(store)
        let text = try utf8(data)
        #expect(!text.contains("senseSource"), "a nil optional is omitted, never null")
        #expect(text.contains("\"colour\" : \"user\""))

        let fresh = try WordStore(container: WordhoardContainer.makeInMemory())
        let summary = try Importer.import(data, into: fresh)
        #expect(summary.sensesCreated == 1)
        let restored = try #require(try fresh.activeWord(normalized: "book")?.sortedSenses.first)
        #expect(restored.senseSource == nil)
        #expect(restored.fieldSources == ["definition": .user, "colour": .user, "": .auto])
        #expect(try export(fresh) == data)
    }

    @Test("dates with a non-UTC offset decode to the same instant and import to the millisecond")
    func datesWithANonUTCOffsetDecodeToTheSameInstant() throws {
        var text = replacing(
            "\"exportedAt\" : \"2025-06-15T15:06:40.000Z\"",
            in: GoldenExport.text,
            with: "\"exportedAt\" : \"2025-06-15T17:06:40.000+02:00\""
        )
        text = replacing(
            "\"createdAt\" : \"2023-11-14T22:13:20.125Z\"",
            in: text,
            with: "\"createdAt\" : \"2023-11-14T17:13:20.125-0500\""
        )
        let data = Data(text.utf8)

        let document = try ExportDocument.decode(data)
        #expect(document.exportedAt == TransferFixture.exportedAt)
        #expect(document.words.first?.createdAt == TransferFixture.bookCreatedAt)

        _ = try Importer.import(data, into: store)
        let book = try #require(try store.word(id: TransferFixture.bookID))
        #expect(sameMillisecond(book.createdAt, TransferFixture.bookCreatedAt))
        #expect(try export(store) == GoldenExport.data, "the re-export is back in UTC and byte-identical")
    }

    @Test("re-importing an older export undoes a local rename made since; incoming wins by id")
    func aLocalRenameIsUndoneByReimportingTheOlderExport() throws {
        let book = try store.add("book").word
        let backup = try export(store)
        book.headword = "notebook"
        try store.save(book)
        #expect(try store.activeWord(normalized: "notebook")?.id == book.id)

        let summary = try Importer.import(backup, into: store)

        #expect(summary.wordsUpdated == 1)
        #expect(summary.wordsCreated == 0)
        #expect(book.headword == "book")
        #expect(book.normalized == "book")
        #expect(try store.activeWord(normalized: "notebook") == nil)
        #expect(try store.search("notebook").isEmpty)
        #expect(try store.search("book").map(\.id) == [book.id])
        #expect(try store.words().count == 1)
        #expect(try Importer.import(backup, into: store) == .nothing)
    }

    @Test("a revived tombstone is persisted as active: a fresh context sees no deletedAt and add() finds it")
    func aRevivedTombstoneIsPersistedAsActive() throws {
        let book = try store.add("book").word
        try store.delete(book)
        let document = makeDocument(words: [makeWord(id: book.id, headword: "Book", senses: [makeSense()])])

        #expect(try importing(document).wordsCreated == 1)

        let id = book.id
        let stored = try ModelContext(container).fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id }))
        #expect(stored.count == 1)
        #expect(stored.first?.deletedAt == nil)
        #expect(stored.first?.headword == "Book")
        #expect(stored.first?.normalized == "book")
        #expect(try store.add("book") == .existing(book), "the revived word owns its key again")
        #expect(try store.words().map(\.id) == [book.id])
        #expect(try store.search("book").map(\.id) == [book.id])
    }

    @Test("a thousand words with senses and examples import, export and re-import within seconds")
    func aThousandWordsImportAndExportInSeconds() throws {
        let words = (0 ..< 1000).map { index -> ExportWord in
            let senses = (0 ..< 2).map { senseIndex in
                makeSense(
                    order: senseIndex,
                    definition: "definition \(index).\(senseIndex)",
                    examples: (0 ..< 2).map { makeExample(order: $0, text: "example \(index).\(senseIndex).\($0)") }
                )
            }
            return makeWord(headword: "word\(index)", senses: senses)
        }
        let data = try makeDocument(words: words).encode()
        let clock = ContinuousClock()

        var summary = ImportSummary.nothing
        let importTime = try clock.measure {
            summary = try Importer.import(data, into: store)
        }
        #expect(summary.wordsCreated == 1000)
        #expect(summary.sensesCreated == 2000)
        #expect(summary.examplesCreated == 4000)
        #expect(importTime < .seconds(20), "first import took \(importTime)")

        var exported = Data()
        let exportTime = try clock.measure {
            exported = try export(store)
        }
        #expect(try ExportDocument.decode(exported).words.count == 1000)
        #expect(exportTime < .seconds(20), "export took \(exportTime)")

        var again = ImportSummary.nothing
        let reimportTime = try clock.measure {
            again = try Importer.import(exported, into: store)
        }
        #expect(again == .nothing)
        #expect(reimportTime < .seconds(20), "no-op re-import took \(reimportTime)")
        let counts = RowCounts(words: 1000, senses: 2000, examples: 4000, tags: 0, settings: 1)
        #expect(try RowCounts(in: container) == counts)
    }
}
