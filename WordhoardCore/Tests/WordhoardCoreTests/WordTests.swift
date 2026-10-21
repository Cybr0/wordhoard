import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("a soft-deleted word is hidden from the default fetch but still stored")
func softDeletedWordIsHiddenFromTheDefaultFetchButStillStored() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let kept = Word(headword: "keep")
    let deleted = Word(headword: "drop")
    context.insert(kept)
    context.insert(deleted)
    deleted.deletedAt = .now
    try context.save()

    let fresh = ModelContext(container)
    let active = try fresh.fetch(Word.activeDescriptor())
    #expect(active.map(\.headword) == ["keep"])
    #expect(try fresh.fetchCount(FetchDescriptor<Word>()) == 2)
}

@Test("the default fetch is newest first")
func defaultFetchIsNewestFirst() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let older = Word(headword: "older")
    let newer = Word(headword: "newer")
    older.createdAt = Date(timeIntervalSince1970: 1000)
    newer.createdAt = Date(timeIntervalSince1970: 1001)
    context.insert(older)
    context.insert(newer)
    try context.save()

    let words = try ModelContext(container).fetch(Word.activeDescriptor())
    #expect(words.map(\.headword) == ["newer", "older"])
}

@Test("normalized headword is lowercased, trimmed and whitespace-collapsed")
func normalizedHeadwordIsLowercasedTrimmedAndWhitespaceCollapsed() {
    #expect(Word.normalize("Book ") == "book")
    #expect(Word.normalize("  look   up\n") == "look up")
    #expect(Word.normalize("BY THE BOOK") == "by the book")
    #expect(Word.normalize("café") == "café")

    let word = Word(headword: "Book ")
    #expect(word.headword == "Book ")
    #expect(word.normalized == "book")
}

@Test("a new word has English as learning language and no deletion")
func newWordHasEnglishAsLearningLanguageAndNoDeletion() {
    let word = Word(headword: "book")
    let other = Word(headword: "book")
    #expect(word.learningLanguage == "en")
    #expect(word.deletedAt == nil)
    #expect(word.pronunciation == nil)
    #expect(word.note == nil)
    #expect(word.createdAt == word.updatedAt)
    #expect(word.id != other.id)
}
