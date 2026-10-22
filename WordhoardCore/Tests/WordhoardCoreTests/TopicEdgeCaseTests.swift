import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Phase 3 edge cases from qa (#55, #57): settings writes under the 1.4 headword rules, a topic change
/// during a fill in flight, imported unknown keys, and browse counts across "Fill in again".
@MainActor
@Suite("Topic edge cases")
struct TopicEdgeCaseTests {
    let container: ModelContainer
    let store: WordStore

    private static let presentPerfect: GrammarTopicID = "en.present_perfect"
    private static let passiveVoice: GrammarTopicID = "en.passive_voice"
    private static let pastSimple: GrammarTopicID = "en.past_simple"
    private static let articles: GrammarTopicID = "en.articles"

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func storedTopics() throws -> [GrammarTopicID] {
        try #require(try ModelContext(container).fetch(FetchDescriptor<UserSettings>()).first).activeGrammarTopics
    }

    private func topicKeys(of word: Word) -> [[GrammarTopicID]] {
        word.sortedSenses.map { $0.sortedExamples.compactMap(\.grammarTopic) }
    }

    @Test("a topic toggle while a stored word has a pending blank headword keeps the saved headword")
    func aTopicToggleRevertsAPendingBlankHeadword() throws {
        let settings = SettingsModel(store: store)
        settings.load()
        let word = try store.add("book").word
        word.headword = "   "

        settings.setTopicActive(Self.articles, true)

        #expect(settings.failure == nil)
        #expect(try storedTopics().contains(Self.articles))
        let stored = try #require(try storedWordOrNil(word.id, in: container))
        #expect(stored.headword == "book")
        #expect(stored.normalized == "book")
        #expect(word.headword == "book", "the in-memory edit is reverted too, so the card shows the saved value")
    }

    @Test("a topic change during a fill in flight leaves that fill's topics and reaches the next word")
    func aTopicChangeDuringAFillReachesOnlyTheNextWord() async throws {
        try store.updateSettings { $0.activeGrammarTopics = [Self.presentPerfect] }
        let generator = GatedCardGenerator(cardsOpen: true, topicsOpen: false)
        let service = AutofillService(store: store, generator: generator)
        let list = WordListModel(store: store, autofill: service)
        let settings = SettingsModel(store: store)
        settings.load()

        list.draft = "book"
        let book = try #require(list.addDraft()).word
        list.draft = "apple"
        let apple = try #require(list.addDraft()).word
        await generator.topicGate.untilWaiting(1)

        settings.setTopicActive(Self.passiveVoice, true)
        settings.setTopicActive(Self.presentPerfect, false)
        generator.topicGate.open()
        await service.drain()

        #expect(generator.inner.topicRequests.map { $0.topics.map(\.key) } == [
            [Self.presentPerfect], [Self.passiveVoice],
        ])
        let storedBook = try #require(try storedWordOrNil(book.id, in: container))
        let storedApple = try #require(try storedWordOrNil(apple.id, in: container))
        #expect(topicKeys(of: storedBook) == [[Self.presentPerfect], [Self.presentPerfect]])
        #expect(topicKeys(of: storedApple).allSatisfy { $0 == [Self.passiveVoice] })
    }

    @Test("an imported topic list with unknown keys keeps them stored and shows them nowhere")
    func importedUnknownTopicKeysAreKeptAndNeverPublished() throws {
        let future: GrammarTopicID = "en.future_tense_of_tomorrow"
        let retired: GrammarTopicID = "en.retired_topic"
        let example = ExportExample(
            id: UUID(), order: 0, text: "A tagged sentence.", grammarTopic: future, source: .auto
        )
        let document = makeDocument(
            words: [makeWord(headword: "book", senses: [makeSense(examples: [example])])],
            settings: makeSettings(activeGrammarTopics: [future, Self.pastSimple, retired])
        )
        _ = try Importer.import(document.encode(), into: store)
        let settings = SettingsModel(store: store)

        settings.load()
        #expect(settings.activeTopics == [Self.pastSimple])

        settings.setTopicActive(Self.articles, true)
        let stored = try storedTopics()
        #expect(stored.filter { $0 == future || $0 == retired } == [future, retired])
        #expect(stored.filter { $0 != future && $0 != retired } == [Self.pastSimple, Self.articles])
        #expect(settings.activeTopics == [Self.pastSimple, Self.articles])

        let browse = TopicBrowseModel(store: store)
        browse.load()
        #expect(browse.active.map(\.id) == [Self.pastSimple, Self.articles])
        #expect(browse.other.isEmpty)
        #expect((browse.active + browse.other).allSatisfy { $0.exampleCount == 0 })
        #expect(browse.groups(for: future).isEmpty)
        #expect(browse.failure == nil)
    }

    @Test("fill in again with the same topics rewrites auto topic examples and leaves the counts alone")
    func fillInAgainKeepsTopicCounts() async throws {
        try store.updateSettings { $0.activeGrammarTopics = [Self.presentPerfect, Self.passiveVoice] }
        let stub = StubCardGenerator()
        let service = AutofillService(store: store, generator: stub)
        let list = WordListModel(store: store, autofill: service)
        list.draft = "book"
        let book = try #require(list.addDraft()).word
        await service.drain()
        let browse = TopicBrowseModel(store: store)
        browse.load()
        let before = browse.active.map(\.exampleCount)
        #expect(before == [2, 2])
        let slot = book.sortedSenses[0].sortedExamples.first { $0.grammarTopic == Self.presentPerfect }
        let slotID = try #require(slot).id

        stub.topicExampleOverrides = [.init(0, Self.presentPerfect): .text("I have booked the room again.")]
        service.retry(book)
        await service.drain()
        browse.load()

        #expect(browse.active.map(\.exampleCount) == before)
        let group = try #require(browse.groups(for: Self.presentPerfect).first)
        #expect(browse.groups(for: Self.presentPerfect).count == 1)
        #expect(group.examples.count == 2)
        #expect(group.examples.first?.id == slotID)
        #expect(group.examples.first?.text == "I have booked the room again.")
    }
}
