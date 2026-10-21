import Foundation
import SwiftData
import Testing
import WordhoardCore

@MainActor
@Suite("WordListModel")
struct WordListModelTests {
    let store: WordStore
    let model: WordListModel

    init() throws {
        store = try WordStore(container: WordhoardContainer.makeInMemory())
        model = WordListModel(store: store)
    }

    /// Adds `headwords` through the store, oldest first, with `createdAt` one second apart.
    private func addSpaced(_ headwords: [String]) throws {
        for (offset, headword) in headwords.enumerated() {
            let word = try store.add(headword).word
            word.createdAt = Date(timeIntervalSince1970: 1000 + TimeInterval(offset))
            try store.save(word)
        }
    }

    @Test("the model lists active words newest first")
    func modelListsActiveWordsNewestFirst() throws {
        try addSpaced(["book", "apple", "cat"])
        #expect(model.words.isEmpty)

        model.reload()
        #expect(model.words.map(\.headword) == ["cat", "apple", "book"])
        #expect(model.failure == nil)
    }

    @Test("adding a draft shows it first and clears the draft and the query")
    func addingADraftShowsItFirstAndClearsDraftAndQuery() {
        model.draft = "book"
        guard case .created = model.addDraft() else {
            Issue.record("expected .created")
            return
        }
        #expect(model.words.first?.headword == "book")
        #expect(model.words.count == 1)
        #expect(model.draft == "")
        #expect(model.query == "")
        #expect(model.failure == nil)

        model.query = "zzz"
        #expect(model.words.isEmpty)
        model.draft = "apple"
        guard case .created = model.addDraft() else {
            Issue.record("expected .created")
            return
        }
        #expect(model.query == "")
        #expect(model.draft == "")
        #expect(model.words.map(\.headword) == ["apple", "book"])
        #expect(model.failure == nil)
    }

    @Test("adding an existing word returns it without adding a row")
    func addingAnExistingWordReturnsItWithoutAddingARow() throws {
        model.draft = "book"
        let original = try #require(model.addDraft()?.word)

        model.draft = "Book "
        guard case let .existing(found) = model.addDraft() else {
            Issue.record("expected .existing")
            return
        }
        #expect(found.id == original.id)
        #expect(model.words.count == 1)
        #expect(model.words.first?.headword == "book")
        #expect(model.draft == "")
        #expect(model.query == "")
        #expect(model.failure == nil)
        #expect(try store.words().count == 1)
    }

    @Test("adding an existing word while a search is active clears the query")
    func addingAnExistingWordClearsAnActiveQuery() {
        model.draft = "book"
        _ = model.addDraft()
        model.query = "zzz"
        #expect(model.words.isEmpty)

        model.draft = "BOOK"
        guard case .existing = model.addDraft() else {
            Issue.record("expected .existing")
            return
        }
        #expect(model.query == "")
        #expect(model.words.map(\.headword) == ["book"])
    }

    @Test("adding an existing word re-reads the list whether or not a search was active")
    func addingAnExistingWordReloadsTheList() throws {
        model.draft = "book"
        _ = model.addDraft()
        model.query = "boo"
        _ = try store.add("apple")
        #expect(model.words.map(\.headword) == ["book"])

        model.draft = "Book"
        guard case .existing = model.addDraft() else {
            Issue.record("expected .existing")
            return
        }
        #expect(try model.words.map(\.id) == (store.words().map(\.id)))
        #expect(model.words.map(\.headword) == ["apple", "book"])

        // No search active: the query does not change, so only an explicit reload can refresh the list.
        _ = try store.add("cat")
        model.draft = "BOOK"
        guard case .existing = model.addDraft() else {
            Issue.record("expected .existing")
            return
        }
        #expect(try model.words.map(\.id) == (store.words().map(\.id)))
        #expect(model.words.map(\.headword) == ["cat", "apple", "book"])
    }

    @Test("a blank draft is ignored without an error")
    func blankDraftIsIgnoredWithoutAnError() throws {
        model.draft = "book"
        _ = model.addDraft()
        let before = model.words.map(\.id)

        for blank in ["   ", "", "\n\t "] {
            model.draft = blank
            #expect(model.addDraft() == nil)
            #expect(model.words.map(\.id) == before)
            #expect(model.draft == "")
            #expect(model.failure == nil)
        }
        #expect(try store.words().count == 1)
    }

    @Test("the query filters the list on the normalized headword and clearing it restores everything")
    func queryFiltersTheListOnTheNormalizedHeadword() throws {
        try addSpaced(["book", "Notebook", "look up"])
        model.reload()

        model.query = "BOOK"
        #expect(model.words.map(\.headword) == ["Notebook", "book"])

        model.query = " bo ok "
        #expect(model.words.isEmpty)

        model.query = ""
        #expect(model.words.map(\.headword) == ["look up", "Notebook", "book"])
        #expect(model.failure == nil)
    }

    @Test("reload reflects changes made through the store elsewhere")
    func reloadReflectsStoreChanges() throws {
        model.draft = "book"
        _ = model.addDraft()

        let added = try store.add("apple").word
        #expect(model.words.map(\.headword) == ["book"])
        model.reload()
        #expect(model.words.first?.id == added.id)
        #expect(model.words.count == 2)

        try store.delete(added)
        model.reload()
        #expect(model.words.map(\.headword) == ["book"])
    }

    @Test("a successful reload does not clear a pending failure")
    func reloadDoesNotClearAPendingFailure() {
        model.failure = .saving
        model.reload()
        #expect(model.failure == .saving)

        model.failure = nil
        model.reload()
        #expect(model.failure == nil)
    }
}
