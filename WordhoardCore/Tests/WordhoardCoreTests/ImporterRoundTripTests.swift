import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Export → import → export round trips, idempotence and counts (issue #36). Refused files are in
/// `ImporterRefusalTests`, the merge rules in `ImporterMergeTests`.
@MainActor
@Suite("Importer round trip")
struct ImporterRoundTripTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func export(_ store: WordStore) throws -> Data {
        try Exporter.export(from: store, exportedAt: TransferFixture.exportedAt, appVersion: TransferFixture.appVersion)
    }

    @Test("export, import into a fresh store, export again: identical bytes and equal fields")
    func exportThenImportIntoAFreshStoreReproducesEveryField() throws {
        try TransferFixture.insert(into: container)
        let fileA = try export(store)

        let containerB = try WordhoardContainer.makeInMemory()
        let storeB = WordStore(container: containerB)
        _ = try Importer.import(fileA, into: storeB)

        #expect(try export(storeB) == fileA)
        #expect(try HoardSnapshot(of: storeB) == HoardSnapshot(of: store))
        #expect(try RowCounts(in: containerB) == RowCounts(in: container))

        let book = try #require(try storeB.word(id: TransferFixture.bookID))
        #expect(book.tags.map(\.name) == ["reading"])
        #expect(book.sortedSenses.first?.senseSource == .wordnet)
        #expect(book.sortedSenses.first?.gloss == "a written work or composition that has been published")
        #expect(book.sortedSenses.first?.fieldSources == ["definition": .user, "synonyms": .auto])
        #expect(
            book.sortedSenses.first?.sortedExamples.map(\.grammarTopic) == ["en.present_perfect", "en.no_such_topic"]
        )
        #expect(book.sortedSenses.last?.sortedExamples.map(\.source) == [.auto, .user])
        #expect(sameMillisecond(book.createdAt, TransferFixture.bookCreatedAt))
        #expect(sameMillisecond(book.updatedAt, TransferFixture.bookUpdatedAt))
        #expect(book.image == nil, "images are not in the file")
        let settings = try storeB.settings()
        #expect(settings.nativeLanguage == "ru")
        #expect(settings.learningLanguage == "en")
        #expect(settings.activeGrammarTopics == ["en.present_perfect", "en.second_conditional"])
        #expect(settings.autoGenerateImages == false)
    }

    @Test("normalized is derived from the headword, never read from the file")
    func normalizedIsDerivedNotRead() throws {
        var text = replacing("\"headword\" : \"book\"", in: GoldenExport.text, with: "\"headword\" : \"Book\"")
        text = replacing(
            "\"headword\" : \"Book\",",
            in: text,
            with: "\"headword\" : \"Book\",\n      \"normalized\" : \"bogus\","
        )
        _ = try Importer.import(Data(text.utf8), into: store)
        let book = try #require(try store.word(id: TransferFixture.bookID))
        #expect(book.headword == "Book")
        #expect(book.normalized == "book")
        #expect(try store.search("book").map(\.id) == [book.id])
    }

    @Test("importing the same file twice, or a store's own export into it, changes nothing")
    func importingTheSameFileTwiceIsANoOp() throws {
        try TransferFixture.insert(into: container)
        let fileA = try export(store)
        let containerB = try WordhoardContainer.makeInMemory()
        let storeB = WordStore(container: containerB)
        _ = try Importer.import(fileA, into: storeB)
        let counts = try RowCounts(in: containerB)
        let fileB = try export(storeB)

        #expect(try Importer.import(fileA, into: storeB) == .nothing)
        #expect(try RowCounts(in: containerB) == counts)
        #expect(try export(storeB) == fileB)

        #expect(try Importer.import(fileA, into: store) == .nothing)
        #expect(try export(store) == fileA)
    }

    @Test("a store's export imports back into it as a no-op even when dates have sub-millisecond parts")
    func importingAnExportBackIntoItsStoreIsANoOpWithStoreMadeDates() throws {
        let word = try store.add("book").word
        word.note = "n"
        try store.save(word)
        let file = try export(store)
        #expect(try Importer.import(file, into: store) == .nothing)
    }

    @Test("the first import of the rich fixture reports what it created")
    func firstImportReportsWhatItCreated() throws {
        let summary = try Importer.import(GoldenExport.data, into: store)
        #expect(summary == ImportSummary(
            wordsCreated: 2,
            wordsUpdated: 0,
            wordsSkipped: 0,
            sensesCreated: 3,
            sensesUpdated: 0,
            examplesCreated: 4,
            examplesUpdated: 0,
            tagsCreated: 1,
            tagsUpdated: 0,
            settingsChanged: true
        ))
    }

    @Test("the golden text imports into a fresh store as the fixture hoard")
    func goldenFixtureImports() throws {
        _ = try Importer.import(GoldenExport.data, into: store)

        let reference = try WordhoardContainer.makeInMemory()
        try TransferFixture.insert(into: reference)
        #expect(try HoardSnapshot(of: store) == HoardSnapshot(of: WordStore(container: reference)))
        #expect(try export(store) == GoldenExport.data)
        #expect(try store.words().map(\.headword) == ["apple", "book"])
        #expect(try RowCounts(in: container) == RowCounts(words: 2, senses: 3, examples: 4, tags: 1, settings: 1))
    }

    @Test("unknown topic keys import verbatim and unknown JSON keys are ignored")
    func unknownTopicKeysAndExtraJSONKeysAreTolerated() throws {
        var text = replacing(
            "\"grammarTopic\" : \"en.no_such_topic\"",
            in: GoldenExport.text,
            with: "\"grammarTopic\" : \"en.not_yet\""
        )
        text = replacing("\"en.second_conditional\"", in: text, with: "\"en.not_yet\"")
        text = replacing(
            "\"schemaVersion\" : 1,",
            in: text,
            with: "\"schemaVersion\" : 1,\n  \"image\" : { \"count\" : 1 },"
        )
        text = replacing(
            "\"headword\" : \"apple\",",
            in: text,
            with: "\"headword\" : \"apple\",\n      \"colour\" : \"red\","
        )

        let summary = try Importer.import(Data(text.utf8), into: store)
        #expect(summary.wordsCreated == 2)
        let book = try #require(try store.word(id: TransferFixture.bookID))
        #expect(book.sortedSenses.first?.sortedExamples.last?.grammarTopic == "en.not_yet")
        #expect(try store.settings().activeGrammarTopics == ["en.present_perfect", "en.not_yet"])
    }

    @Test("blank headwords are skipped and counted, never inserted")
    func blankHeadwordsAreSkippedNotInserted() throws {
        let document = makeDocument(words: [
            makeWord(headword: "  "),
            makeWord(headword: "\n"),
            makeWord(headword: "book"),
        ])
        let summary = try Importer.import(document.encode(), into: store)
        #expect(summary.wordsCreated == 1)
        #expect(summary.wordsSkipped == 2)
        #expect(try store.words().count == 1)
        #expect(try store.search("book").map(\.headword) == ["book"])
        let all = try ModelContext(container).fetch(FetchDescriptor<Word>())
        #expect(all.count == 1)
        #expect(all.allSatisfy { !Word.normalize($0.headword).isEmpty })
    }
}

extension RowCounts {
    init(words: Int, senses: Int, examples: Int, tags: Int, settings: Int) {
        self.words = words
        self.senses = senses
        self.examples = examples
        self.tags = tags
        self.settings = settings
    }
}
