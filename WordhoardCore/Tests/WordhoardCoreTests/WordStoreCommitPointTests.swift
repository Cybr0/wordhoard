import Foundation
import SwiftData
import Testing
import WordhoardCore

/// What a `WordStore` save commits. Autosave is off on the main context, SwiftData's `save()` is
/// context-wide, and the store applies the headword rules (trim, re-key, revert a blank on a stored word)
/// to every pending `Word` on every save (ruling on #30). 1.5/1.6 rely on exactly these facts.
@MainActor
@Suite("WordStore commit points")
struct WordStoreCommitPointTests {
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

    @Test("a blank rename followed by a valid rename before any store call persists the new value, re-keyed")
    func blankThenValidRenamePersistsTheNewValue() throws {
        let word = try store.add("book").word
        word.headword = "  "
        word.headword = " Novel "

        _ = try store.add("other")

        #expect(word.headword == "Novel")
        #expect(word.normalized == "novel")
        let reopened = try #require(try fresh().fetch(FetchDescriptor<Word>()).first { $0.id == word.id })
        #expect(reopened.headword == "Novel")
        #expect(reopened.normalized == "novel")
        #expect(try store.search("novel").map(\.id) == [word.id])
        #expect(try store.search("book").isEmpty)
        #expect(try store.add("NOVEL").word.id == word.id)
    }

    @Test(
        "pending renames and blanks on several words are all re-keyed or reverted by one delete or save of another word"
    )
    func deleteAndSaveOfAnotherWordAlsoApplyTheHeadwordRules() throws {
        let book = try store.add("book").word
        let pen = try store.add("pen").word
        let victim = try store.add("victim").word
        let other = try store.add("other").word

        book.headword = " Books "
        pen.headword = "\t"
        try store.delete(victim)

        #expect(book.headword == "Books")
        #expect(pen.headword == "pen")
        var rows = try fresh().fetch(FetchDescriptor<Word>())
        #expect(rows.first { $0.id == book.id }?.normalized == "books")
        #expect(rows.first { $0.id == pen.id }?.headword == "pen")

        book.headword = "Bookshelf"
        pen.headword = "   "
        try store.save(other)

        rows = try fresh().fetch(FetchDescriptor<Word>())
        #expect(rows.first { $0.id == book.id }?.normalized == "bookshelf")
        #expect(rows.first { $0.id == pen.id }?.headword == "pen")
        #expect(try store.search("bookshelf").map(\.id) == [book.id])
    }

    /// The `false` branch of the revert: a word whose row was hard-deleted through another context (only
    /// 1.7's wipe does this) has no saved value to fall back to. Nothing is resurrected and nothing throws
    /// beyond the ordinary `emptyHeadword`.
    @Test(
        "a pending blank on a word whose saved row is gone is left alone: save throws, an unrelated add still succeeds"
    )
    func pendingBlankOnAHardDeletedWordDoesNotBreakOtherSaves() throws {
        let word = try store.add("book").word
        let side = fresh()
        let id = word.id
        let row = try #require(try side.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })).first)
        side.delete(row)
        try side.save()
        #expect(try storedWordCount() == 0)

        word.headword = "  "
        #expect(throws: WordStoreError.emptyHeadword) {
            try store.save(word)
        }
        #expect(word.headword == "  ", "no saved row, so nothing to revert to")

        guard case .created = try store.add("other") else {
            Issue.record("expected .created")
            return
        }
        #expect(try storedWordCount() == 1)
        #expect(try store.words().map(\.headword) == ["other"])
        #expect(try store.word(id: id) == nil, "the hard-deleted row is not resurrected")
    }
}
