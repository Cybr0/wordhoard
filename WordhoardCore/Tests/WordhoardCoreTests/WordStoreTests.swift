import Foundation
import SwiftData
import Testing
import WordhoardCore

@MainActor
@Suite("WordStore")
struct WordStoreTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func fresh() -> ModelContext {
        ModelContext(container)
    }

    private func storedWordCount() throws -> Int {
        try fresh().fetchCount(FetchDescriptor<Word>())
    }

    /// Spreads `createdAt` one second apart, in the order given, and saves through the store.
    private func space(_ words: [Word], startingAt start: TimeInterval = 1000) throws {
        for (offset, word) in words.enumerated() {
            word.createdAt = Date(timeIntervalSince1970: start + TimeInterval(offset))
            try store.save(word)
        }
    }

    @Test("adding a word saves it immediately with a trimmed headword")
    func addingAWordSavesItImmediatelyWithATrimmedHeadword() throws {
        guard case let .created(word) = try store.add("Book ") else {
            Issue.record("expected .created")
            return
        }
        #expect(word.headword == "Book")
        #expect(word.normalized == "book")
        #expect(word.deletedAt == nil)
        #expect(word.createdAt == word.updatedAt)
        #expect(try storedWordCount() == 1)
        #expect(try fresh().fetch(FetchDescriptor<Word>()).first?.headword == "Book")

        guard case let .created(phrase) = try store.add("  look   up\n") else {
            Issue.record("expected .created")
            return
        }
        #expect(phrase.headword == "look   up")
        #expect(phrase.normalized == "look up")
        #expect(try storedWordCount() == 2)
    }

    @Test("adding a word that differs only by case or whitespace returns the existing one")
    func addingAWordThatDiffersOnlyByCaseOrWhitespaceReturnsTheExistingOne() throws {
        let first = try store.add("book").word
        for variant in ["Book ", "  BOOK\n"] {
            guard case let .existing(found) = try store.add(variant) else {
                Issue.record("expected .existing for \(variant.debugDescription)")
                return
            }
            #expect(found.id == first.id)
            #expect(found.headword == "book")
            #expect(found.updatedAt == first.updatedAt)
        }
        #expect(try storedWordCount() == 1)

        let phrase = try store.add("look   up").word
        guard case let .existing(foundPhrase) = try store.add("Look up") else {
            Issue.record("expected .existing")
            return
        }
        #expect(foundPhrase.id == phrase.id)
        #expect(foundPhrase.headword == "look   up")
        #expect(try storedWordCount() == 2)
    }

    @Test("canonically equivalent spellings are the same word, cafe without the accent is another")
    func canonicallyEquivalentSpellingsAreTheSameWord() throws {
        let precomposed = try store.add("caf\u{E9}").word
        guard case let .existing(decomposed) = try store.add("cafe\u{301}") else {
            Issue.record("expected .existing")
            return
        }
        #expect(decomposed.id == precomposed.id)

        guard case let .created(plain) = try store.add("cafe") else {
            Issue.record("expected .created")
            return
        }
        #expect(plain.id != precomposed.id)
        #expect(try storedWordCount() == 2)
    }

    @Test("a blank headword is rejected and nothing is saved")
    func blankHeadwordIsRejectedAndNothingIsSaved() throws {
        for blank in ["", "   ", "\n\t "] {
            #expect(throws: WordStoreError.emptyHeadword) {
                try store.add(blank)
            }
        }
        #expect(try storedWordCount() == 0)
        #expect(try store.words().isEmpty)
    }

    @Test("words are newest first and exclude deleted")
    func wordsAreNewestFirstAndExcludeDeleted() throws {
        let oldest = try store.add("oldest").word
        let middle = try store.add("middle").word
        let newest = try store.add("newest").word
        try space([oldest, middle, newest])
        try store.delete(middle)

        #expect(try store.words().map(\.headword) == ["newest", "oldest"])
        #expect(try storedWordCount() == 3)
    }

    @Test("search matches the normalized headword as a substring, ignoring case and whitespace")
    func searchMatchesTheNormalizedHeadwordAsASubstring() throws {
        let words = try ["book", "Notebook", "look up", "bookcase"].map { try store.add($0).word }
        try space(words)

        #expect(try store.search("BOOK").map(\.headword) == ["bookcase", "Notebook", "book"])
        #expect(try store.search("oo").map(\.headword) == ["bookcase", "look up", "Notebook", "book"])
        #expect(try store.search("look  UP").map(\.headword) == ["look up"])
        #expect(try store.search(" look up ").map(\.headword) == ["look up"])
        #expect(try store.search(" bo ok ").isEmpty)
        #expect(try store.search("xyz").isEmpty)
    }

    @Test("an empty query returns all active words in list order")
    func emptyQueryReturnsAllActiveWords() throws {
        let words = try ["book", "Notebook", "look up"].map { try store.add($0).word }
        try space(words)
        try store.delete(words[1])
        let all = try store.words().map(\.id)
        #expect(all.count == 2)

        #expect(try store.search("").map(\.id) == all)
        #expect(try store.search("  \n").map(\.id) == all)
    }

    @Test("deleted words are excluded from search and the list but found by id")
    func deletedWordsAreExcludedFromSearchButFoundById() throws {
        let word = try store.add("book").word
        try store.delete(word)

        #expect(try store.search("book").isEmpty)
        #expect(try store.words().isEmpty)
        let found = try #require(try store.word(id: word.id))
        #expect(found.id == word.id)
        #expect(found.deletedAt != nil)
        #expect(try store.word(id: UUID()) == nil)
    }

    @Test("deleting a word is soft and keeps its senses, examples, tags and image")
    func deletingAWordIsSoftAndKeepsItsSensesExamplesTagsAndImage() throws {
        let word = try insertBookFixture(into: fresh())
        let stored = try #require(try store.word(id: word.id))
        let past = Date(timeIntervalSince1970: 1000)
        stored.createdAt = past
        stored.updatedAt = past

        try store.delete(stored)
        let deletedAt = try #require(stored.deletedAt)
        #expect(stored.updatedAt > stored.createdAt)
        #expect(stored.updatedAt == deletedAt)

        let context = fresh()
        #expect(try context.fetchCount(FetchDescriptor<Word>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Sense>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Example>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<WordhoardCore.Tag>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 1)
        #expect(try context.fetch(FetchDescriptor<Word>()).first?.deletedAt == deletedAt)

        try store.delete(stored)
        #expect(stored.deletedAt == deletedAt)
    }

    @Test("adding a deleted word again creates a fresh word and leaves the tombstone deleted")
    func addingADeletedWordAgainCreatesAFreshWord() throws {
        guard case let .created(first) = try store.add("book") else {
            Issue.record("expected .created")
            return
        }
        try store.delete(first)

        guard case let .created(second) = try store.add("book") else {
            Issue.record("expected .created")
            return
        }
        #expect(second.id != first.id)
        #expect(second.deletedAt == nil)
        #expect(try storedWordCount() == 2)
        #expect(try store.words().map(\.id) == [second.id])
        #expect(try store.word(id: first.id)?.deletedAt != nil)
    }

    @Test("duplicate lookup picks the oldest active match when several exist")
    func duplicateLookupPicksTheOldestActiveMatch() throws {
        let context = fresh()
        let older = Word(headword: "book")
        let newer = Word(headword: "book")
        older.createdAt = Date(timeIntervalSince1970: 1000)
        newer.createdAt = Date(timeIntervalSince1970: 1001)
        context.insert(older)
        context.insert(newer)
        try context.save()

        guard case let .existing(found) = try store.add("Book") else {
            Issue.record("expected .existing")
            return
        }
        #expect(found.id == older.id)
        #expect(try storedWordCount() == 2)
    }

    @Test("saving a word bumps updatedAt and re-derives normalized from the headword")
    func savingAWordBumpsUpdatedAtAndRederivesNormalized() throws {
        let word = try store.add("book").word
        let sense = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
        word.senses = [sense]
        try store.save(word)

        let past = Date(timeIntervalSince1970: 1000)
        word.updatedAt = past
        sense.definition = "a set of printed pages"
        try store.save(word)
        #expect(word.updatedAt > past)
        let reopened = try #require(try fresh().fetch(FetchDescriptor<Word>()).first)
        #expect(reopened.sortedSenses.map(\.definition) == ["a set of printed pages"])

        word.headword = " Books "
        try store.save(word)
        #expect(word.headword == "Books")
        #expect(word.normalized == "books")
        #expect(try store.search("books").map(\.id) == [word.id])
        #expect(try store.search("book ").map(\.id) == [word.id])
        guard case let .existing(found) = try store.add("books ") else {
            Issue.record("expected .existing")
            return
        }
        #expect(found.id == word.id)
        #expect(try fresh().fetch(FetchDescriptor<Word>()).first?.headword == "Books")
        #expect(try storedWordCount() == 1)
    }

    @Test("saving a blank headword is rejected and the stored headword is unchanged")
    func savingABlankHeadwordIsRejected() throws {
        let word = try store.add("Books").word
        let savedAt = word.updatedAt

        word.headword = "  "
        #expect(throws: WordStoreError.emptyHeadword) {
            try store.save(word)
        }
        #expect(word.updatedAt == savedAt)
        #expect(try fresh().fetch(FetchDescriptor<Word>()).first?.headword == "Books")
    }

    @Test("settings are created once and persisted immediately")
    func settingsAreCreatedOnceAndPersistedImmediately() throws {
        let first = try store.settings()
        let second = try store.settings()
        #expect(first.id == second.id)
        #expect(first === second)

        let context = fresh()
        #expect(try context.fetchCount(FetchDescriptor<UserSettings>()) == 1)
        let reopened = try UserSettings.current(in: context)
        #expect(reopened.id == first.id)
        #expect(reopened.activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)
        #expect(reopened.activeGrammarTopics.count == 5)
        #expect(try context.fetchCount(FetchDescriptor<UserSettings>()) == 1)
    }

    @Test("the existing path of add writes nothing, not even pending changes")
    func existingPathWritesNothing() throws {
        #expect(container.mainContext.autosaveEnabled == false)
        let word = try store.add("book").word
        word.note = "unsaved edit"

        _ = try store.add("Book")
        #expect(try fresh().fetch(FetchDescriptor<Word>()).first?.note == nil)
    }
}
