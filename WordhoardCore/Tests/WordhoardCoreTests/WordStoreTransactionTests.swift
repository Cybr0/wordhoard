import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `WordStore.transaction`: one save at the end with the headword rules, rollback on error, no
/// `updatedAt` bump.
@MainActor
@Suite("WordStore transaction")
struct WordStoreTransactionTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private struct SomeError: Error {}

    @Test("a transaction commits once, with the headword rules applied to inserted words")
    func transactionCommitsOnceWithHeadwordRules() throws {
        let id: UUID = try store.transaction { context in
            let word = Word(headword: "  x ")
            context.insert(word)
            return word.id
        }

        let rows = try ModelContext(container).fetch(FetchDescriptor<Word>())
        #expect(rows.map(\.id) == [id])
        #expect(rows.first?.headword == "x")
        #expect(rows.first?.normalized == "x")
        #expect(try store.search("x").map(\.id) == [id])
    }

    @Test("a thrown error rolls the transaction back and the store keeps working")
    func transactionRollsBackOnError() throws {
        let kept = try store.add("kept").word
        #expect(throws: SomeError.self) {
            try store.transaction { context in
                context.insert(Word(headword: "lost"))
                kept.note = "also lost"
                throw SomeError()
            }
        }

        let rows = try ModelContext(container).fetch(FetchDescriptor<Word>())
        #expect(rows.map(\.headword) == ["kept"])
        #expect(rows.first?.note == nil)
        #expect(kept.note == nil, "the rollback also discards the in-memory edit")
        guard case .created = try store.add("next") else {
            Issue.record("expected .created")
            return
        }
        #expect(try store.words().map(\.headword) == ["next", "kept"])
    }

    @Test("a word edited inside a transaction keeps its updatedAt")
    func transactionDoesNotBumpUpdatedAt() throws {
        let word = try store.add("book").word
        let savedAt = word.updatedAt
        try store.transaction { _ in
            word.note = "edited in a batch"
        }

        let reopened = try #require(try ModelContext(container).fetch(FetchDescriptor<Word>()).first)
        #expect(reopened.note == "edited in a batch")
        #expect(reopened.updatedAt == savedAt)
    }
}
