import Foundation
import SwiftData
import Testing
import WordhoardCore

/// "Fill in again" (issue #41) goes through `AutofillService.retry` and `CardMerger`, so every edit the
/// user made survives and nothing is duplicated (A5, A4, A6).
@MainActor
@Suite("AutofillService regenerate")
struct AutofillRegenerateTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
        try store.settings().activeGrammarTopics = ["en.present_perfect"]
    }

    private func stored(_ id: UUID) throws -> Word {
        try #require(try storedWordOrNil(id, in: container))
    }

    @Test("fill in again keeps user edits and refreshes the rest")
    func fillInAgainKeepsUserEditsAndRefreshesTheRest() async throws {
        let stub = StubCardGenerator()
        let generator = GatedCardGenerator(inner: stub, cardsOpen: true)
        let service = AutofillService(store: store, generator: generator)
        let word = try store.add("book").word
        service.enqueue(word)
        await service.drain()
        let noun = try #require(word.sortedSenses.first)
        let examplesBefore = word.sortedSenses.map { $0.sortedExamples.map(\.id) }
        #expect(examplesBefore.map(\.count) == [2, 2], "one neutral and one topic example per sense")

        WordCardModel(word: word, store: store).setDefinition("mine", for: noun)
        stub.fixtures["book"] = bookWithNoun(definition: "theirs", synonyms: ["tome"])
        generator.cardGate.close()

        service.retry(word)
        #expect(try stored(word.id).autofillState == .pending)
        try await waitUntil { generator.cardGate.waiting == 1 }
        #expect(try stored(word.id).autofillState == .filling)
        generator.cardGate.open()
        await service.drain()

        let refilled = try stored(word.id)
        #expect(refilled.autofillState == .ready)
        #expect(refilled.senses.count == 2)
        let storedNoun = try #require(refilled.sortedSenses.first)
        #expect(storedNoun.definition == "mine")
        #expect(storedNoun.fieldSource(for: .definition) == .user)
        #expect(storedNoun.synonyms == ["tome"])
        #expect(storedNoun.fieldSource(for: .synonyms) == .auto)
        #expect(refilled.sortedSenses.map { $0.sortedExamples.map(\.id) } == examplesBefore, "slots, not copies")
        #expect(refilled.sortedSenses.map { $0.examples.filter { $0.grammarTopic == nil }.count } == [1, 1])
        #expect(generator.inner.requests.count == 2)
    }

    @Test("fill in recovers unavailable and failed cards")
    func fillInRecoversUnavailableAndFailedCards() async throws {
        let generator =
            SwitchingCardGenerator(StubCardGenerator(availability: .unavailable(.appleIntelligenceNotEnabled)))
        let service = AutofillService(store: store, generator: generator)
        let word = try store.add("book").word
        service.enqueue(word)
        await service.drain()
        #expect(try stored(word.id).autofillState == .unavailable)
        #expect(await service.generator.availability() == .unavailable(.appleIntelligenceNotEnabled))

        generator.current = StubCardGenerator()
        #expect(await service.generator.availability() == .available)
        service.retry(word)
        await service.drain()
        #expect(try stored(word.id).autofillState == .ready)
        #expect(try stored(word.id).senses.count == 2)
        #expect(service.lastFailure[word.id] == nil)

        generator.current = ThrowingCardGenerator(error: .failed("x"))
        let second = try store.add("apple").word
        service.enqueue(second)
        await service.drain()
        #expect(try stored(second.id).autofillState == .failed)

        generator.current = StubCardGenerator()
        service.retry(second)
        await service.drain()
        #expect(try stored(second.id).autofillState == .ready)
        #expect(try stored(second.id).senses.count == 1)
    }
}
