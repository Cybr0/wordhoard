import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The two hard-delete helpers added for the card (1.6) and the duplicate lookup the rename check uses.
@MainActor
@Suite("WordStore sense and example deletion")
struct WordStoreDeletionTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func fresh() -> ModelContext {
        ModelContext(container)
    }

    @Test("deleting a sense removes it and its examples, bumps the word's updatedAt and saves")
    func deletingASenseRemovesItAndItsExamplesAndSaves() throws {
        let word = try store.add("book").word
        let noun = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
        let verb = Sense(partOfSpeech: .verb, definition: "to reserve", order: 1)
        word.senses = [noun, verb]
        noun.examples = [Example(text: "She read a book.", source: .auto, order: 0)]
        verb.examples = [Example(text: "I booked a table.", source: .auto, order: 0)]
        try store.save(word)
        let savedAt = word.updatedAt
        let nounID = noun.id

        try store.delete(noun)

        #expect(word.updatedAt > savedAt)
        #expect(word.sortedSenses.map(\.definition) == ["to reserve"])
        let context = fresh()
        #expect(try context.fetchCount(FetchDescriptor<Sense>(predicate: #Predicate { $0.id == nounID })) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Sense>()) == 1)
        #expect(try context.fetch(FetchDescriptor<Example>()).map(\.text) == ["I booked a table."])
        let reread = try #require(context.fetch(FetchDescriptor<Word>()).first)
        #expect(reread.updatedAt == word.updatedAt)
        #expect(reread.sortedSenses.map(\.definition) == ["to reserve"])
    }

    @Test("deleting an example removes only that row, bumps the word's updatedAt and saves")
    func deletingAnExampleRemovesOnlyThatRowAndSaves() throws {
        let word = try store.add("book").word
        let noun = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
        word.senses = [noun]
        let first = Example(text: "She read a book.", source: .auto, order: 0)
        let second = Example(text: "The book is on the table.", source: .auto, order: 1)
        noun.examples = [first, second]
        try store.save(word)
        let savedAt = word.updatedAt
        let firstID = first.id

        try store.delete(first)

        #expect(word.updatedAt > savedAt)
        #expect(noun.sortedExamples.map(\.text) == ["The book is on the table."])
        let context = fresh()
        #expect(try context.fetchCount(FetchDescriptor<Example>(predicate: #Predicate { $0.id == firstID })) == 0)
        #expect(try context.fetch(FetchDescriptor<Example>()).map(\.text) == ["The book is on the table."])
        #expect(try context.fetchCount(FetchDescriptor<Sense>()) == 1)
        #expect(try context.fetch(FetchDescriptor<Word>()).first?.updatedAt == word.updatedAt)
    }

    @Test("activeWord(normalized:) finds the oldest active word by key and ignores soft-deleted ones")
    func activeWordByKeyIgnoresDeletedWords() throws {
        let book = try store.add("Book").word
        #expect(try store.activeWord(normalized: "book")?.id == book.id)
        #expect(try store.activeWord(normalized: "Book") == nil)
        #expect(try store.activeWord(normalized: "apple") == nil)

        try store.delete(book)
        #expect(try store.activeWord(normalized: "book") == nil)
    }
}
