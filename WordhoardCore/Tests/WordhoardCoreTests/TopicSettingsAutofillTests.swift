import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Plan 3.1: autofill reads the topic set when a word is dequeued, so a change made through
/// `SettingsModel` reaches the next fill and every "Fill in again", and never removes examples.
@MainActor
@Suite("Topic settings and autofill")
struct TopicSettingsAutofillTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private static let presentPerfect: GrammarTopicID = "en.present_perfect"
    private static let passiveVoice: GrammarTopicID = "en.passive_voice"

    private func stored(_ id: UUID) throws -> Word {
        try #require(try storedWordOrNil(id, in: container))
    }

    private func topicKeys(of sense: Sense) -> [GrammarTopicID] {
        sense.sortedExamples.compactMap(\.grammarTopic)
    }

    @Test("changing topics affects the next fill and regeneration, never existing examples")
    func changingTopicsAffectsTheNextFillAndRegeneration() async throws {
        try store.updateSettings { $0.activeGrammarTopics = [Self.presentPerfect] }
        let stub = StubCardGenerator()
        let service = AutofillService(store: store, generator: stub)
        let list = WordListModel(store: store, autofill: service)
        let settings = SettingsModel(store: store)
        settings.load()

        list.draft = "book"
        let book = try #require(list.addDraft()).word
        await service.drain()
        #expect(try stored(book.id).sortedSenses.map(topicKeys) == [[Self.presentPerfect], [Self.presentPerfect]])
        let perfectBefore = try stored(book.id).sortedSenses.flatMap(\.sortedExamples)
            .filter { $0.grammarTopic == Self.presentPerfect }
            .map { [$0.id.uuidString, $0.text] }

        settings.setTopicActive(Self.passiveVoice, true)
        settings.setTopicActive(Self.presentPerfect, false)
        #expect(settings.activeTopics == [Self.passiveVoice])

        list.draft = "apple"
        let apple = try #require(list.addDraft()).word
        await service.drain()
        #expect(stub.topicRequests.count == 2)
        #expect(stub.topicRequests[1].topics.map(\.key) == [Self.passiveVoice])
        #expect(try stored(apple.id).sortedSenses.allSatisfy { topicKeys(of: $0) == [Self.passiveVoice] })
        #expect(try stored(book.id).sortedSenses.map(topicKeys) == [[Self.presentPerfect], [Self.presentPerfect]])

        service.retry(book)
        await service.drain()
        #expect(stub.topicRequests.count == 3)
        #expect(stub.topicRequests[2].topics.map(\.key) == [Self.passiveVoice])
        let refilled = try stored(book.id)
        for sense in refilled.sortedSenses {
            #expect(topicKeys(of: sense).sorted() == [Self.passiveVoice, Self.presentPerfect])
            #expect(sense.examples.count(where: { $0.grammarTopic == nil }) == 1)
        }
        let perfectAfter = refilled.sortedSenses.flatMap(\.sortedExamples)
            .filter { $0.grammarTopic == Self.presentPerfect }
            .map { [$0.id.uuidString, $0.text] }
        #expect(perfectAfter == perfectBefore, "the deselected topic's examples survive, same ids and text")
    }
}
