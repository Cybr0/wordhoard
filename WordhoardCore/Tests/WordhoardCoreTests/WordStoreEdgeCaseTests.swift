import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Edge cases for `WordStore` beyond the acceptance criteria in issue #30: unusual input, SQL-ish search
/// queries, two stores on one container, and the consequences of autosave being off on the main context.
@MainActor
@Suite("WordStore edge cases")
struct WordStoreEdgeCaseTests {
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

    // MARK: - Input

    @Test("a 500-character headword is stored verbatim and found again by its lowercase key")
    func veryLongHeadwordIsStoredVerbatim() throws {
        let long = String(repeating: "Ab", count: 250)
        guard case let .created(word) = try store.add(long) else {
            Issue.record("expected .created")
            return
        }
        #expect(word.headword == long)
        #expect(word.headword.count == 500)
        #expect(word.normalized == long.lowercased())
        #expect(try store.search(long.uppercased()).map(\.id) == [word.id])
        guard case .existing = try store.add(" " + long.lowercased() + "\n") else {
            Issue.record("expected .existing")
            return
        }
        #expect(try storedWordCount() == 1)
    }

    @Test("emoji, Cyrillic and mixed-script headwords are stored, de-duplicated and searchable")
    func nonLatinHeadwordsAreStoredAndSearchable() throws {
        let emoji = try store.add("🙂 face").word
        let cyrillic = try store.add("книга").word
        let mixed = try store.add("book книга").word
        #expect(emoji.headword == "🙂 face")
        #expect(cyrillic.normalized == "книга")
        #expect(mixed.normalized == "book книга")

        guard case let .existing(found) = try store.add("  КНИГА ") else {
            Issue.record("expected .existing: Cyrillic case folding")
            return
        }
        #expect(found.id == cyrillic.id)
        #expect(try store.search("🙂").map(\.id) == [emoji.id])
        #expect(try Set(store.search("КНИГА").map(\.id)) == [cyrillic.id, mixed.id])
        #expect(try storedWordCount() == 3)
    }

    @Test("tab-only, newline-only and non-breaking-space-only input is blank")
    func exoticWhitespaceOnlyInputIsBlank() throws {
        for blank in ["\t\t", "\n\n", "\r\n", "\u{00A0}", " \u{00A0}\t\n", "\u{2003}\u{3000}"] {
            #expect(throws: WordStoreError.emptyHeadword, "\(blank.debugDescription)") {
                try store.add(blank)
            }
        }
        #expect(try storedWordCount() == 0)
    }

    @Test("a headword padded with non-breaking spaces is trimmed to the visible text")
    func nonBreakingSpacePaddingIsTrimmed() throws {
        guard case let .created(word) = try store.add("\u{00A0}book\u{00A0}") else {
            Issue.record("expected .created")
            return
        }
        #expect(word.headword == "book")
        #expect(word.normalized == "book")
    }

    @Test("internal tabs and newlines count as the same word as spaces but are stored as typed")
    func internalWhitespaceVariantsAreOneWord() throws {
        let phrase = try store.add("look   up").word
        for variant in ["Look Up", "look\tup", "look\nup", " LOOK\u{00A0}UP "] {
            guard case let .existing(found) = try store.add(variant) else {
                Issue.record("expected .existing for \(variant.debugDescription)")
                return
            }
            #expect(found.id == phrase.id)
            #expect(found.headword == "look   up")
        }
        #expect(try storedWordCount() == 1)

        guard case let .created(tabbed) = try store.add("pick\tup") else {
            Issue.record("expected .created")
            return
        }
        #expect(tabbed.headword == "pick\tup")
        #expect(tabbed.normalized == "pick up")
    }

    // MARK: - Search

    @Test("search treats %, _, quotes and backslash literally, not as SQL wildcards")
    func searchTreatsSQLSpecialCharactersLiterally() throws {
        let percent = try store.add("100%").word
        let underscore = try store.add("snake_case").word
        let apostrophe = try store.add("don't").word
        let quote = try store.add("say \"hi\"").word
        let backslash = try store.add("back\\slash").word
        _ = try store.add("abc").word
        _ = try store.add("1000").word

        #expect(try store.search("%").map(\.id) == [percent.id])
        #expect(try store.search("_").map(\.id) == [underscore.id])
        #expect(try store.search("'").map(\.id) == [apostrophe.id])
        #expect(try store.search("\"").map(\.id) == [quote.id])
        #expect(try store.search("\\").map(\.id) == [backslash.id])
        #expect(try store.search("100%").map(\.id) == [percent.id])
        #expect(try store.search("1_0").isEmpty)
        #expect(try store.search("a%c").isEmpty)
    }

    @Test("a single space and a very long query are handled: space lists all, long matches nothing")
    func spaceOnlyAndVeryLongQueries() throws {
        let words = try ["book", "look up"].map { try store.add($0).word }
        #expect(try Set(store.search(" ").map(\.id)) == Set(words.map(\.id)))
        #expect(try store.search(" ").count == 2)
        #expect(try store.search(String(repeating: "x", count: 2000)).isEmpty)
        #expect(try store.search(String(repeating: "book", count: 200)).isEmpty)
    }

    // MARK: - Two stores, foreign objects

    @Test("two stores on one container share the main context and see each other's saves at once")
    func twoStoresOnOneContainerSeeEachOther() throws {
        let other = WordStore(container: container)
        let word = try store.add("book").word

        #expect(try other.words().map(\.id) == [word.id])
        guard case let .existing(found) = try other.add("Book") else {
            Issue.record("expected .existing")
            return
        }
        #expect(found === word)

        try other.delete(word)
        #expect(try store.words().isEmpty)
        #expect(try store.word(id: word.id)?.deletedAt != nil)

        #expect(try store.settings() === (other.settings()))
        #expect(try fresh().fetchCount(FetchDescriptor<UserSettings>()) == 1)
    }

    @Test("settings created by another context before the store is asked are reused, not duplicated")
    func settingsCreatedElsewhereAreReused() throws {
        let context = fresh()
        let existing = try UserSettings.current(in: context)
        existing.activeGrammarTopics = ["en.present_perfect"]
        try context.save()

        let settings = try store.settings()
        #expect(settings.id == existing.id)
        #expect(settings.activeGrammarTopics == ["en.present_perfect"])
        #expect(try fresh().fetchCount(FetchDescriptor<UserSettings>()) == 1)
    }

    @Test("renaming a word to collide with another active word is allowed by save; both stay listed")
    func saveAllowsRenamingIntoACollision() throws {
        let book = try store.add("book").word
        let novel = try store.add("novel").word
        novel.headword = "Book"
        try store.save(novel)

        #expect(novel.normalized == "book")
        #expect(try Set(store.search("book").map(\.id)) == [book.id, novel.id])
        #expect(try store.words().count == 2)
        #expect(try store.add("BOOK").word.id == book.id)
        #expect(try storedWordCount() == 2)
    }

    // MARK: - Autosave is off

    @Test("an edit made directly on a Word without save(_:) is not persisted by words(), search or word(id:)")
    func directEditWithoutSaveIsNotPersistedByReads() throws {
        let word = try store.add("book").word
        word.note = "typed but never saved"
        word.headword = "Books"

        _ = try store.words()
        _ = try store.search("book")
        _ = try store.word(id: word.id)

        let reopened = try #require(try fresh().fetch(FetchDescriptor<Word>()).first)
        #expect(reopened.note == nil)
        #expect(reopened.headword == "book")
    }

    /// SwiftData's `save()` writes every pending change in the context, so the store cannot save one
    /// word in isolation: an unsaved in-place edit rides along with the next save the store makes for
    /// anything else, with the headword trimmed and `normalized` re-derived on the way (ruling on #30).
    /// 1.5/1.6 must treat every store mutation as a commit point for all pending edits.
    @Test("an unsaved direct edit is flushed, trimmed and re-keyed by the next save for another word")
    func directEditIsFlushedByTheNextUnrelatedSave() throws {
        let word = try store.add("book").word
        word.note = "typed but never saved"
        word.headword = " Books "

        _ = try store.add("another")

        let reopened = try #require(try fresh().fetch(FetchDescriptor<Word>()).first { $0.id == word.id })
        #expect(reopened.note == "typed but never saved")
        #expect(reopened.headword == "Books")
        #expect(reopened.normalized == "books")
    }

    @Test("the first settings() call is a save and flushes unsaved direct edits, re-keyed, with it")
    func firstSettingsCallFlushesUnsavedDirectEdits() throws {
        let word = try store.add("book").word
        word.note = "typed but never saved"
        word.headword = "Books"

        _ = try store.settings()

        let reopened = try #require(try fresh().fetch(FetchDescriptor<Word>()).first { $0.id == word.id })
        #expect(reopened.note == "typed but never saved")
        #expect(reopened.headword == "Books")
        #expect(reopened.normalized == "books")

        word.note = "second unsaved edit"
        _ = try store.settings()
        let again = try #require(try fresh().fetch(FetchDescriptor<Word>()).first { $0.id == word.id })
        #expect(again.note == "typed but never saved", "a later settings() call is read-only")
    }

    @Test("a rejected save restores the headword in memory")
    func rejectedSaveRestoresTheHeadwordInMemory() throws {
        let word = try store.add("book").word
        word.headword = "  "
        #expect(throws: WordStoreError.emptyHeadword) {
            try store.save(word)
        }
        #expect(word.headword == "book")
        #expect(word.normalized == "book")
    }

    @Test("a headword edited in place is re-keyed by any save, not only by save(_:)")
    func inPlaceRenameIsRekeyedByAnUnrelatedSave() throws {
        let word = try store.add("book").word
        let savedAt = word.updatedAt
        word.headword = " Books "

        _ = try store.add("other")

        let reopened = try #require(try fresh().fetch(FetchDescriptor<Word>()).first { $0.id == word.id })
        #expect(reopened.headword == "Books")
        #expect(reopened.normalized == "books")
        #expect(reopened.updatedAt == savedAt, "re-keying by an unrelated save does not bump updatedAt")
        guard case let .existing(found) = try store.add("books") else {
            Issue.record("expected .existing")
            return
        }
        #expect(found.id == word.id)
        #expect(try store.search("book").map(\.id) == [word.id])
    }

    @Test("a pending blank headword is reverted, not persisted, by an unrelated save")
    func pendingBlankHeadwordIsNotPersistedByAnUnrelatedSave() throws {
        let word = try store.add("book").word
        word.headword = "  "

        _ = try store.add("other")

        #expect(word.headword == "book")
        let reopened = try #require(try fresh().fetch(FetchDescriptor<Word>()).first { $0.id == word.id })
        #expect(reopened.headword == "book")
        #expect(reopened.normalized == "book")
        #expect(try store.search("book").map(\.id) == [word.id])
    }
}
