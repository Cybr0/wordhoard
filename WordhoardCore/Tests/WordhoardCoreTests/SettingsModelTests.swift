import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `SettingsModel`, the grammar-topic subset (plan 3.1, #55; names from #45): catalog-order storage,
/// unknown keys preserved and never published, unchanged values save nothing, deselect-all allowed.
@MainActor
@Suite("SettingsModel topics")
struct SettingsModelTests {
    let container: ModelContainer
    let store: WordStore
    let model: SettingsModel

    static let unknown: GrammarTopicID = "en.no_such_topic"
    static let defaults = GrammarCatalog.english.defaultActiveKeys

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
        model = SettingsModel(store: store)
    }

    /// The stored list as a fresh context reads it.
    private func storedTopics() throws -> [GrammarTopicID] {
        try #require(try ModelContext(container).fetch(FetchDescriptor<UserSettings>()).first).activeGrammarTopics
    }

    private func setRecord(_ topics: [GrammarTopicID]) throws {
        try store.updateSettings { $0.activeGrammarTopics = topics }
        model.load()
    }

    @Test("toggling a topic keeps catalog order and unknown keys")
    func togglingATopicKeepsCatalogOrderAndUnknownKeys() throws {
        try setRecord(["en.present_perfect", Self.unknown])
        #expect(model.activeTopics == ["en.present_perfect"])

        model.setTopicActive("en.past_simple", true)
        #expect(try storedTopics() == ["en.present_perfect", "en.past_simple", Self.unknown])
        #expect(model.activeTopics == ["en.present_perfect", "en.past_simple"])
        #expect(!model.activeTopics.contains(Self.unknown))

        model.setTopicActive("en.present_perfect", false)
        #expect(try storedTopics() == ["en.past_simple", Self.unknown])
        #expect(model.activeTopics == ["en.past_simple"])
        #expect(model.failure == nil)
    }

    @Test("resetting topics restores the defaults and keeps unknown keys")
    func resettingTopicsRestoresTheDefaultsAndKeepsUnknownKeys() throws {
        try setRecord(["en.past_simple", Self.unknown])

        model.resetTopicsToDefault()

        #expect(try storedTopics() == Self.defaults + [Self.unknown])
        #expect(model.activeTopics == Set(Self.defaults))
    }

    @Test("deselecting every topic is allowed and never re-seeded")
    func deselectingEveryTopicIsAllowed() throws {
        try setRecord(Self.defaults + [Self.unknown])

        for key in Self.defaults {
            model.setTopicActive(key, false)
        }

        #expect(try storedTopics() == [Self.unknown])
        #expect(model.activeTopics.isEmpty)
        #expect(try UserSettings.current(in: ModelContext(container)).activeGrammarTopics == [Self.unknown])
        model.load()
        #expect(model.activeTopics.isEmpty)
    }

    /// No save is observed through a pending in-place edit: any store save is context-wide, so the edit
    /// reaching a fresh context would prove `updateSettings` ran.
    @Test("unknown keys and unchanged values save nothing")
    func unknownKeysAndUnchangedValuesSaveNothing() throws {
        try setRecord(Self.defaults)
        let word = try store.add("book").word
        word.note = "pending, never saved"

        model.setTopicActive("en.bogus", true)
        #expect(try storedTopics() == Self.defaults)
        #expect(model.activeTopics == Set(Self.defaults))
        #expect(model.failure == nil)

        model.setTopicActive("en.present_perfect", true)
        model.setTopicActive("en.articles", false)
        model.resetTopicsToDefault()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Word>()).first)
        #expect(stored.note == nil, "no call saved the context")
        #expect(model.failure == nil)
    }

    @Test("loading reflects an imported topic list")
    func loadingReflectsAnImportedTopicList() throws {
        model.load()
        #expect(model.activeTopics == Set(Self.defaults))

        _ = try Importer.import(GoldenExport.data, into: store)
        model.load()

        #expect(model.activeTopics == ["en.present_perfect", "en.second_conditional"])
    }

    @Test("the ordering rule keeps unknown keys around the known block")
    func theOrderingRuleKeepsUnknownKeysAroundTheKnownBlock() throws {
        try setRecord(["en.x", "en.passive_voice", "en.y", "en.present_perfect", "en.z"])

        model.setTopicActive("en.articles", true)

        #expect(try storedTopics() == [
            "en.x", "en.present_perfect", "en.passive_voice", "en.articles", "en.y", "en.z",
        ])

        try setRecord(["en.x"])
        model.setTopicActive("en.articles", true)
        #expect(try storedTopics() == ["en.articles", "en.x"])
    }
}
