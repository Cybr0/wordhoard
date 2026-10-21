import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The merge rules of issue #36, one per test: match by id, then tombstone revive, then key, else insert;
/// incoming wins; local extras kept; a colliding rename skips the word; tags by id then name; settings
/// replaced.
@MainActor
@Suite("Importer merge rules")
struct ImporterMergeTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func importing(_ document: ExportDocument) throws -> ImportSummary {
        try Importer.import(document.encode(), into: store)
    }

    @Test("a word matched by id takes the file's fields and keeps local senses the file lacks")
    func matchingByIdUpdatesIncomingFieldsAndKeepsLocalExtras() throws {
        let book = try store.add("book").word
        let senseOne = Sense(partOfSpeech: .noun, definition: "local one", order: 0)
        let senseTwo = Sense(partOfSpeech: .verb, definition: "local two", order: 1)
        book.senses = [senseOne, senseTwo]
        try store.save(book)
        let earlier = Date(timeIntervalSince1970: 1_600_000_000.25)
        let exampleNine = TransferFixture.uuid(9)
        let senseThree = TransferFixture.uuid(3)

        let document = makeDocument(words: [
            makeWord(
                id: book.id,
                headword: "Book",
                note: "n",
                createdAt: book.createdAt,
                updatedAt: earlier,
                senses: [
                    makeSense(
                        id: senseOne.id,
                        order: 0,
                        definition: "from the file",
                        examples: [makeExample(id: exampleNine, text: "Nine.")]
                    ),
                    makeSense(id: senseThree, order: 2, partOfSpeech: .adjective, definition: "third"),
                ]
            ),
        ])
        let summary = try importing(document)

        #expect(summary.wordsUpdated == 1)
        #expect(summary.wordsCreated == 0)
        #expect(summary.sensesUpdated == 1)
        #expect(summary.sensesCreated == 1)
        #expect(summary.examplesCreated == 1)
        let reopened = try #require(try store.word(id: book.id))
        #expect(reopened.headword == "Book")
        #expect(reopened.normalized == "book")
        #expect(reopened.note == "n")
        #expect(sameMillisecond(reopened.updatedAt, earlier))
        #expect(reopened.sortedSenses.map(\.id) == [senseOne.id, senseTwo.id, senseThree])
        #expect(reopened.sortedSenses.first?.definition == "from the file")
        #expect(reopened.sortedSenses.first?.sortedExamples.map(\.id) == [exampleNine])
        #expect(reopened.sortedSenses[1].definition == "local two", "senseTwo is kept")
        #expect(try importing(document) == .nothing)
    }

    @Test("an unknown id with a known headword merges into the existing word and keeps its id")
    func anUnknownIdWithAKnownHeadwordMergesIntoTheExistingWord() throws {
        let local = try store.add("book").word
        let fileID = TransferFixture.uuid(5)
        let document = makeDocument(words: [
            makeWord(
                id: fileID,
                headword: "book",
                createdAt: local.createdAt,
                updatedAt: local.updatedAt,
                senses: [makeSense()]
            ),
        ])

        let summary = try importing(document)
        #expect(summary.wordsUpdated == 1)
        #expect(summary.wordsCreated == 0)
        #expect(summary.sensesCreated == 1)
        let active = try store.words()
        #expect(active.map(\.id) == [local.id])
        #expect(active.first?.senses.count == 1)
        #expect(try store.word(id: fileID) == nil)
        #expect(try importing(document) == .nothing)
    }

    @Test("a deleted word whose id is in the file is revived with the file's senses")
    func aDeletedWordInTheFileIsRestored() throws {
        let book = try store.add("book").word
        try store.delete(book)
        let word = makeWord(id: book.id, headword: "book", senses: [makeSense(definition: "back")])
        let document = makeDocument(words: [word])

        let summary = try importing(document)
        #expect(summary.wordsCreated == 1)
        #expect(summary.wordsUpdated == 0)
        let revived = try #require(try store.word(id: book.id))
        #expect(revived.deletedAt == nil)
        #expect(try store.words().map(\.id) == [book.id])
        #expect(revived.senses.map(\.definition) == ["back"])
        #expect(try importing(document) == .nothing)
    }

    @Test("a deleted word is not revived when another active word owns the key; the file merges into that one")
    func aDeletedWordIsNotRevivedWhenAnotherActiveWordOwnsTheKey() throws {
        let deleted = try store.add("book").word
        try store.delete(deleted)
        let active = try store.add("book").word
        let word = makeWord(id: deleted.id, headword: "Book", senses: [makeSense(definition: "merged")])
        let document = makeDocument(words: [word])

        let summary = try importing(document)
        #expect(summary.wordsUpdated == 1)
        #expect(summary.wordsCreated == 0)
        #expect(try store.word(id: deleted.id)?.deletedAt != nil, "the tombstone stays deleted")
        #expect(try store.word(id: deleted.id)?.senses.isEmpty == true)
        #expect(try store.words().map(\.id) == [active.id])
        #expect(active.headword == "Book")
        #expect(active.senses.map(\.definition) == ["merged"])
    }

    @Test("a rename that would collide with another active word skips the word entirely")
    func anImportedRenameThatCollidesIsSkipped() throws {
        let book = try store.add("book").word
        let apple = try store.add("apple").word
        let document = makeDocument(words: [
            makeWord(id: apple.id, headword: "Book", note: "should not land", senses: [makeSense()]),
        ])

        let summary = try importing(document)
        #expect(summary.wordsSkipped == 1)
        #expect(summary.wordsUpdated == 0)
        #expect(summary.sensesCreated == 0)
        #expect(apple.headword == "apple")
        #expect(apple.note == nil)
        #expect(apple.senses.isEmpty)
        #expect(try store.words().count == 2)
        #expect(try store.activeWord(normalized: "book")?.id == book.id)
    }

    @Test("two file words with one key and different ids end as one word")
    func twoFileWordsWithOneKeyMergeIntoOne() throws {
        let document = makeDocument(words: [
            makeWord(id: TransferFixture.uuid(1), headword: "book", senses: [makeSense(id: TransferFixture.uuid(10))]),
            makeWord(
                id: TransferFixture.uuid(2),
                headword: "Book",
                senses: [makeSense(id: TransferFixture.uuid(11), order: 1)]
            ),
        ])
        let summary = try importing(document)
        #expect(summary.wordsCreated == 1)
        #expect(summary.wordsUpdated == 1)
        let words = try store.words()
        #expect(words.map(\.id) == [TransferFixture.uuid(1)])
        #expect(words.first?.headword == "Book")
        #expect(words.first?.senses.count == 2)
    }

    @Test("a sense whose id already exists elsewhere in the store is inserted under a fresh id")
    func aSenseIdTakenElsewhereGetsAFreshId() throws {
        let pen = try store.add("pen").word
        let taken = Sense(partOfSpeech: .noun, definition: "pen sense", order: 0)
        pen.senses = [taken]
        try store.save(pen)

        let word = makeWord(headword: "book", senses: [makeSense(id: taken.id, definition: "book sense")])
        let document = makeDocument(words: [word])
        let summary = try importing(document)
        #expect(summary.sensesCreated == 1)
        #expect(taken.definition == "pen sense")
        #expect(taken.word?.id == pen.id)
        let book = try #require(try store.activeWord(normalized: "book"))
        #expect(book.senses.map(\.definition) == ["book sense"])
        #expect(book.senses.first?.id != taken.id)
    }

    @Test("tags match by id, then by name; unknown tag ids on a word are ignored")
    func tagsMatchByIdThenByName() throws {
        let book = try store.add("book").word
        let reading = WordhoardCore.Tag(name: "reading")
        book.tags = [reading]
        try store.save(book)
        let fileTagID = TransferFixture.uuid(200)
        let verbs = TransferFixture.uuid(201)
        let unknown = TransferFixture.uuid(202)

        let document = makeDocument(
            words: [
                makeWord(
                    id: book.id,
                    headword: "book",
                    createdAt: book.createdAt,
                    updatedAt: book.updatedAt,
                    tagIDs: [fileTagID]
                ),
                makeWord(headword: "apple", tagIDs: [fileTagID, verbs, unknown, fileTagID]),
            ],
            tags: [
                ExportTag(id: fileTagID, name: "reading"),
                ExportTag(id: verbs, name: "verbs"),
                ExportTag(id: unknown, name: "  "),
            ]
        )
        let summary = try importing(document)

        #expect(summary.tagsCreated == 1)
        #expect(summary.tagsUpdated == 0)
        #expect(summary.wordsUpdated == 0, "book already had the reading tag")
        let tags = try ModelContext(container).fetch(FetchDescriptor<WordhoardCore.Tag>())
        #expect(tags.map(\.name).sorted() == ["reading", "verbs"])
        #expect(tags.first { $0.name == "reading" }?.id == reading.id)
        #expect(tags.first { $0.name == "verbs" }?.id == verbs)
        let apple = try #require(try store.activeWord(normalized: "apple"))
        #expect(apple.tags.map(\.name).sorted() == ["reading", "verbs"])
        #expect(book.tags.map(\.id) == [reading.id])
        #expect(try importing(document) == .nothing)
    }

    @Test("a tag matched by id is renamed to the file's name")
    func aTagMatchedByIdIsRenamed() throws {
        let book = try store.add("book").word
        let tag = WordhoardCore.Tag(name: "reading")
        book.tags = [tag]
        try store.save(book)
        let document = makeDocument(words: [], tags: [ExportTag(id: tag.id, name: "novels")])

        #expect(try importing(document).tagsUpdated == 1)
        #expect(tag.name == "novels")
        #expect(try importing(document) == .nothing)
    }

    @Test("a tag renamed by id does not also capture a new file tag that takes its old name")
    func aRenamedTagDoesNotCaptureANewTagWithItsOldName() throws {
        let book = try store.add("book").word
        let local = WordhoardCore.Tag(name: "a")
        book.tags = [local]
        try store.save(book)
        let newTagID = TransferFixture.uuid(210)
        let document = makeDocument(
            words: [makeWord(headword: "apple", tagIDs: [newTagID])],
            tags: [ExportTag(id: newTagID, name: "a"), ExportTag(id: local.id, name: "b")]
        )
        let summary = try importing(document)

        #expect(summary.tagsUpdated == 1)
        #expect(summary.tagsCreated == 1)
        let tags = try ModelContext(container).fetch(FetchDescriptor<WordhoardCore.Tag>())
        #expect(tags.map(\.name).sorted() == ["a", "b"])
        #expect(tags.first { $0.name == "b" }?.id == local.id)
        #expect(tags.first { $0.name == "a" }?.id == newTagID)
        let apple = try #require(try store.activeWord(normalized: "apple"))
        #expect(apple.tags.map(\.name) == ["a"])
        #expect(book.tags.map(\.name) == ["b"])
        #expect(try importing(document) == .nothing)
    }

    @Test("settings are replaced by the file's values")
    func settingsAreReplacedByTheFile() throws {
        let settings = try store.settings()
        #expect(settings.nativeLanguage == nil)
        #expect(!settings.activeGrammarTopics.isEmpty)
        #expect(settings.autoGenerateImages)
        let document = makeDocument(
            words: [],
            settings: makeSettings(nativeLanguage: "es", activeGrammarTopics: [], autoGenerateImages: false)
        )

        #expect(try importing(document).settingsChanged)
        #expect(settings.nativeLanguage == "es")
        #expect(settings.activeGrammarTopics == [])
        #expect(settings.autoGenerateImages == false)
        #expect(try importing(document).settingsChanged == false)
        #expect(try importing(document) == .nothing)
    }
}
