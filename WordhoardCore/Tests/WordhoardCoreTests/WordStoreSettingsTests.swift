import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `WordStore.updateSettings(_:)` (plan 3.1, #44's signature): one save under the 1.4 headword rules,
/// nothing persisted when the change throws.
@MainActor
@Suite("WordStore settings writes")
struct WordStoreSettingsTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private struct SomeError: Error {}

    private func freshSettings() throws -> UserSettings {
        try #require(try ModelContext(container).fetch(FetchDescriptor<UserSettings>()).first)
    }

    @Test("updating settings persists and commits pending edits too")
    func updatingSettingsCommitsPendingEditsToo() throws {
        try store.updateSettings { $0.autoGenerateImages = false }
        #expect(try freshSettings().autoGenerateImages == false)

        let word = try store.add("book").word
        word.headword = "  Books "
        try store.updateSettings { $0.activeGrammarTopics = [] }

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Word>()).first)
        #expect(stored.headword == "Books")
        #expect(stored.normalized == "books")
        #expect(try freshSettings().activeGrammarTopics.isEmpty)
    }

    @Test("a throwing settings change saves nothing")
    func aThrowingSettingsChangeSavesNothing() throws {
        _ = try store.settings()
        #expect(throws: SomeError.self) {
            try store.updateSettings { settings in
                settings.activeGrammarTopics = []
                throw SomeError()
            }
        }
        #expect(try freshSettings().activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)
        #expect(try store.settings().activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)
    }
}
