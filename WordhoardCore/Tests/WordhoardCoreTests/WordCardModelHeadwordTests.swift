import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The card's headword rename rules (C4; ruling on #30) and word deletion (W3), on `WordCardModel`.
@MainActor
@Suite("WordCardModel headword and delete")
struct WordCardModelHeadwordTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func fresh() -> ModelContext {
        ModelContext(container)
    }

    /// `book` with one unmarked noun sense, saved.
    private func makeBook() throws -> (Word, Sense) {
        let word = try store.add("book").word
        let sense = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
        word.senses = [sense]
        try store.save(word)
        return (word, sense)
    }

    private func storedWord(_ id: UUID) throws -> Word? {
        try fresh().fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })).first
    }

    private func model(for word: Word) -> WordCardModel {
        WordCardModel(word: word, store: store)
    }

    // MARK: - Headword (C4)

    @Test("renaming a headword is found by search after reopening the on-disk store")
    func renamingAHeadwordIsFoundBySearchAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordhoard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Wordhoard.store")
        let id: UUID

        do {
            let diskStore = try WordStore(container: WordhoardContainer.makeOnDisk(url: url))
            let word = try diskStore.add("book").word
            id = word.id
            let model = WordCardModel(word: word, store: diskStore)
            #expect(model.setHeadword("Notebook") == nil)
            #expect(model.headwordRejection == nil)
        }

        let reopened = try WordStore(container: WordhoardContainer.makeOnDisk(url: url))
        let found = try reopened.search("notebook")
        #expect(found.map(\.id) == [id])
        #expect(found.first?.headword == "Notebook")
        #expect(found.first?.normalized == "notebook")
        #expect(try reopened.search("book").map(\.id) == [id])
    }

    @Test("a blank headword is rejected and the previous one kept")
    func blankHeadwordIsRejectedAndThePreviousOneKept() throws {
        let (word, _) = try makeBook()
        let savedAt = word.updatedAt
        let model = model(for: word)

        for blank in ["   ", "", "\n\t", "\u{00A0}"] {
            #expect(model.setHeadword(blank) == .empty, "input \(blank.debugDescription)")
            #expect(model.headwordRejection == .empty)
            #expect(word.headword == "book")
            #expect(word.normalized == "book")
            #expect(word.updatedAt == savedAt)
            #expect(model.failure == nil)
        }
        #expect(try storedWord(word.id)?.headword == "book")

        #expect(model.setHeadword("books") == nil)
        #expect(model.headwordRejection == nil)
        #expect(word.headword == "books")
        #expect(word.normalized == "books")
        #expect(word.updatedAt > savedAt)
        #expect(try storedWord(word.id)?.headword == "books")
    }

    @Test("renaming to an existing word is blocked before anything is pending")
    func renamingToAnExistingWordIsBlockedBeforeAnythingIsPending() throws {
        let book = try store.add("book").word
        let apple = try store.add("apple").word
        let appleID = apple.id
        let savedAt = apple.updatedAt
        let model = model(for: apple)

        #expect(model.setHeadword(" BOOK ") == .collision(existingHeadword: "book"))
        #expect(model.headwordRejection == .collision(existingHeadword: "book"))
        #expect(apple.headword == "apple")
        #expect(apple.normalized == "apple")
        #expect(apple.updatedAt == savedAt)
        #expect(model.failure == nil)

        _ = try store.add("other")
        let context = fresh()
        let byKey = try context.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.normalized == "book" }))
        #expect(byKey.map(\.id) == [book.id])
        #expect(try context.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == appleID })).first?
            .headword == "apple")

        guard case let .existing(found) = try store.add("book") else {
            Issue.record("expected .existing")
            return
        }
        #expect(found.id == book.id)
        #expect(try store.words().count == 3)
    }

    @Test("renaming a word to a different casing of itself is not a collision")
    func renamingAWordToItsOwnKeyIsNotACollision() throws {
        let (word, _) = try makeBook()
        let model = model(for: word)

        #expect(model.setHeadword("Book") == nil)
        #expect(model.headwordRejection == nil)
        #expect(word.headword == "Book")
        #expect(word.normalized == "book")
        #expect(try storedWord(word.id)?.headword == "Book")
        #expect(try store.activeWord(normalized: "book")?.id == word.id)
    }

    @Test("committing the same headword saves nothing and clears a previous rejection")
    func committingTheSameHeadwordSavesNothing() throws {
        let (word, _) = try makeBook()
        let savedAt = word.updatedAt
        let model = model(for: word)

        #expect(model.setHeadword("book") == nil)
        #expect(model.setHeadword("  book\n") == nil)
        #expect(word.updatedAt == savedAt)
        #expect(word.headword == "book")

        _ = model.setHeadword("")
        #expect(model.headwordRejection == .empty)
        #expect(model.setHeadword("book") == nil)
        #expect(model.headwordRejection == nil)
        #expect(word.updatedAt == savedAt)
    }

    @Test("a soft-deleted word with the same key does not block a rename")
    func aDeletedWordWithTheSameKeyDoesNotBlockARename() throws {
        let old = try store.add("notebook").word
        try store.delete(old)
        let (word, _) = try makeBook()
        let model = model(for: word)

        #expect(model.setHeadword("Notebook") == nil)
        #expect(word.headword == "Notebook")
        #expect(try store.search("notebook").map(\.id) == [word.id])
    }

    // MARK: - Delete (W3)

    @Test("deleting the word soft-deletes it and reports success")
    func deletingTheWordSoftDeletesIt() throws {
        let (word, sense) = try makeBook()
        _ = try store.add("apple")
        let model = model(for: word)

        #expect(model.deleteWord() == true)

        #expect(word.deletedAt != nil)
        #expect(model.failure == nil)
        #expect(try store.words().map(\.headword) == ["apple"])
        let found = try #require(try store.word(id: word.id))
        #expect(found.deletedAt != nil)
        #expect(found.sortedSenses.map(\.id) == [sense.id])
        #expect(try storedWord(word.id)?.deletedAt != nil)
    }
}
