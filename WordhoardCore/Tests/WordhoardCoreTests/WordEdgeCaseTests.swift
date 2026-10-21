import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("normalize treats tabs, newlines and non-breaking spaces as whitespace")
func normalizeTreatsTabsNewlinesAndNonBreakingSpacesAsWhitespace() {
    #expect(Word.normalize("look\tup") == "look up")
    #expect(Word.normalize("look\r\nup\r\n") == "look up")
    #expect(Word.normalize("look\u{00A0}up") == "look up")
    #expect(Word.normalize("look\u{2003}up") == "look up")
    #expect(Word.normalize("\t \n") == "")
    #expect(Word.normalize("") == "")
}

@Test("normalize lowercases Cyrillic and keeps emoji and long headwords intact")
func normalizeLowercasesCyrillicAndKeepsEmojiAndLongHeadwordsIntact() {
    #expect(Word.normalize("  КНИГА ") == "книга")
    #expect(Word.normalize("📚 Book") == "📚 book")
    let long = String(repeating: "a", count: 500)
    #expect(Word.normalize(long) == long)
}

@Test("a 500-character headword round-trips verbatim")
func longHeadwordRoundTripsVerbatim() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let long = String(repeating: "б", count: 500)
    context.insert(Word(headword: long))
    try context.save()

    let word = try #require(try ModelContext(container).fetch(FetchDescriptor<Word>()).first)
    #expect(word.headword == long)
    #expect(word.normalized == long)
}

@Test("a soft-deleted word is still reachable by id with its senses")
func softDeletedWordIsStillReachableByIDWithItsSenses() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = try insertBookFixture(into: context)
    word.deletedAt = .now
    try context.save()

    let id = word.id
    let fresh = ModelContext(container)
    let byID = try fresh.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id }))
    #expect(byID.count == 1)
    #expect(byID.first?.deletedAt != nil)
    #expect(byID.first?.senses.count == 2)
    #expect(try fresh.fetch(Word.activeDescriptor()).isEmpty)
}

@Test("two words with the same normalized form can both be stored")
func twoWordsWithTheSameNormalizedFormCanBothBeStored() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    context.insert(Word(headword: "Cat"))
    context.insert(Word(headword: " cat "))
    try context.save()

    let fresh = ModelContext(container)
    #expect(try fresh.fetchCount(FetchDescriptor<Word>(predicate: #Predicate { $0.normalized == "cat" })) == 2)
}

@Test("changing sense order is reflected by sortedSenses after a refetch")
func changingSenseOrderIsReflectedBySortedSensesAfterARefetch() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = try insertBookFixture(into: context)
    for sense in word.senses {
        sense.order = sense.partOfSpeech == .noun ? 1 : 0
    }
    try context.save()

    let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<Word>()).first)
    #expect(fetched.sortedSenses.map(\.partOfSpeech) == [.verb, .noun])
}
