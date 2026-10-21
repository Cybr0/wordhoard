import Foundation
import Testing
import WordhoardCore

@MainActor
@Suite("WordListModel edge cases")
struct WordListModelEdgeCaseTests {
    let store: WordStore
    let model: WordListModel

    init() throws {
        store = try WordStore(container: WordhoardContainer.makeInMemory())
        model = WordListModel(store: store)
    }

    @Test("a whitespace-only query is not a search: every word is listed and no failure is raised")
    func whitespaceOnlyQueryListsEveryWord() {
        model.draft = "book"
        _ = model.addDraft()
        model.draft = "apple"
        _ = model.addDraft()

        for blank in ["   ", "\n\t", "\u{00A0}"] {
            model.query = blank
            #expect(Set(model.words.map(\.headword)) == ["book", "apple"], "query \(blank.debugDescription)")
            #expect(model.failure == nil)
        }
    }

    @Test("a blank draft keeps the active query and its results")
    func blankDraftKeepsTheActiveQuery() {
        model.draft = "book"
        _ = model.addDraft()

        model.query = "zzz"
        #expect(model.words.isEmpty)
        model.draft = "   "
        #expect(model.addDraft() == nil)
        #expect(model.query == "zzz")
        #expect(model.words.isEmpty)
        #expect(model.draft == "")
        #expect(model.failure == nil)

        model.query = "boo"
        model.draft = ""
        #expect(model.addDraft() == nil)
        #expect(model.query == "boo")
        #expect(model.words.map(\.headword) == ["book"])
    }

    @Test("a draft is trimmed but keeps its case and internal spacing, and its variants open the same word")
    func draftIsTrimmedAndVariantsAreTheSameWord() throws {
        model.draft = "  Look   Up "
        let created = try #require(model.addDraft()?.word)
        #expect(model.words.map(\.headword) == ["Look   Up"])

        for variant in ["look up", "LOOK  UP\t", "\nLook\tUp"] {
            model.draft = variant
            guard case let .existing(found) = model.addDraft() else {
                Issue.record("expected .existing for \(variant.debugDescription)")
                return
            }
            #expect(found.id == created.id)
            #expect(model.draft == "")
        }
        #expect(model.words.count == 1)
        #expect(try store.words().count == 1)
    }

    @Test("re-adding a soft-deleted word creates a fresh word and the tombstone stays hidden")
    func reAddingADeletedWordCreatesAFreshOne() throws {
        model.draft = "book"
        let first = try #require(model.addDraft()?.word)
        try store.delete(first)
        model.reload()
        #expect(model.words.isEmpty)

        model.draft = "book"
        guard case let .created(second) = model.addDraft() else {
            Issue.record("expected .created")
            return
        }
        #expect(second.id != first.id)
        #expect(model.words.map(\.id) == [second.id])

        model.query = "book"
        #expect(model.words.map(\.id) == [second.id])
    }

    @Test("very long, Cyrillic and emoji drafts are listed first and found by their query")
    func unusualDraftsAreListedAndSearchable() {
        let long = String(repeating: "abcdefghij", count: 50)
        for draft in [long, "книга", "🙂 face"] {
            model.draft = draft
            guard case .created = model.addDraft() else {
                Issue.record("expected .created for \(draft.prefix(20))")
                return
            }
            #expect(model.words.first?.headword == draft)
            #expect(model.draft == "")
            #expect(model.failure == nil)
        }
        #expect(model.words.count == 3)

        model.query = "КНИГА"
        #expect(model.words.map(\.headword) == ["книга"])
        model.query = "🙂"
        #expect(model.words.map(\.headword) == ["🙂 face"])
        model.query = String(long.prefix(100)).uppercased()
        #expect(model.words.map(\.headword) == [long])
    }

    @Test("a successful add leaves a pending failure for the view to dismiss")
    func successfulAddDoesNotClearAPendingFailure() {
        model.failure = .loading
        model.draft = "book"
        guard case .created = model.addDraft() else {
            Issue.record("expected .created")
            return
        }
        #expect(model.failure == .loading)
        #expect(model.words.map(\.headword) == ["book"])
    }
}
