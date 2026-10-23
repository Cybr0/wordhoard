import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `AutofillService` (issue #39): capture stays instant, the queue fills one word at a time, the first
/// card and `ready` are one commit, and every generator outcome maps to a card state (C5, A2, A6, A7).
/// Launch sweep, crash safety and the import rule are in `AutofillResumeTests`.
@MainActor
@Suite("AutofillService queue and states")
struct AutofillServiceTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private static let presentPerfect: GrammarTopicID = "en.present_perfect"

    private func makeService(_ generator: any CardGenerator, topics: [GrammarTopicID] = []) throws -> AutofillService {
        try store.settings().activeGrammarTopics = topics
        return AutofillService(store: store, generator: generator)
    }

    private func stored(_ id: UUID) throws -> Word {
        try #require(try storedWordOrNil(id, in: container))
    }

    @Test("adding a word saves it then fills it in")
    func addingAWordSavesItThenFillsItIn() async throws {
        let stub = StubCardGenerator()
        let service = try makeService(stub)
        let list = WordListModel(store: store, autofill: service)

        list.draft = "book"
        guard case let .created(word) = list.addDraft() else {
            Issue.record("expected .created")
            return
        }
        #expect(try store.words().map(\.id) == [word.id])
        #expect(try stored(word.id).autofillState == .pending)
        #expect(try stored(word.id).senses.isEmpty, "capture is instant: the save does not wait for the card")

        await service.drain()

        let filled = try stored(word.id)
        #expect(filled.autofillState == .ready)
        let senses = filled.sortedSenses
        #expect(senses.map(\.partOfSpeech) == [.noun, .verb])
        #expect(senses.allSatisfy { $0.senseSource == .wordnet && $0.gloss != nil && $0.translation == nil })
        #expect(senses.flatMap(\.examples).filter { $0.grammarTopic == nil }.count == 2)
        #expect(service.currentWordID == nil)
        #expect(service.lastFailure[word.id] == nil)

        list.draft = "Book "
        guard case .existing = list.addDraft() else {
            Issue.record("expected .existing")
            return
        }
        await service.drain()
        #expect(stub.requests.count == 1, ".existing enqueues nothing")
    }

    @Test("the first card is saved before any topic example")
    func theFirstCardIsSavedBeforeAnyTopicExample() async throws {
        let generator = GatedCardGenerator(cardsOpen: true, topicsOpen: false)
        let service = try makeService(generator, topics: [Self.presentPerfect])
        let word = try store.add("book").word

        service.enqueue(word)
        try await waitUntil { generator.topicGate.arrivals == 1 }

        let firstCard = try stored(word.id)
        #expect(firstCard.autofillState == .ready)
        #expect(firstCard.senses.count == 2)
        #expect(firstCard.senses.flatMap(\.examples).allSatisfy { $0.grammarTopic == nil })
        #expect(firstCard.senses.flatMap(\.examples).count == 2)
        #expect(service.currentWordID == word.id, "still receiving topic examples")

        generator.topicGate.open()
        await service.drain()

        let topicExamples = try stored(word.id).senses.flatMap(\.examples).filter { $0.grammarTopic != nil }
        #expect(topicExamples.count == 2)
        #expect(topicExamples.allSatisfy { $0.grammarTopic == Self.presentPerfect && $0.source == .auto })
        #expect(try stored(word.id).sortedSenses.map { $0.sortedExamples.map(\.order) } == [[0, 1], [0, 1]])
    }

    @Test("filling is persisted before the call and ready after")
    func fillingIsPersistedBeforeTheCallAndReadyAfter() async throws {
        let generator = GatedCardGenerator()
        let service = try makeService(generator)
        let word = try store.add("book").word
        var seenUpdatedAt: Set<Date> = try [stored(word.id).updatedAt]

        service.enqueue(word)
        try await waitUntil { generator.cardGate.waiting == 1 }

        let filling = try stored(word.id)
        #expect(filling.autofillState == .filling)
        #expect(filling.senses.isEmpty)
        #expect(service.currentWordID == word.id)
        seenUpdatedAt.insert(filling.updatedAt)
        #expect(seenUpdatedAt.count == 2, "the filling save is one commit")

        generator.cardGate.open()
        await service.drain()

        let ready = try stored(word.id)
        #expect(ready.autofillState == .ready)
        #expect(ready.senses.count == 2)
        seenUpdatedAt.insert(ready.updatedAt)
        #expect(seenUpdatedAt.count == 3, "the merge and the ready flag are one more commit, and the last")
    }

    @Test("generator errors become failed or unavailable")
    func generatorErrorsBecomeFailedOrUnavailable() async throws {
        let unavailable = try makeService(StubCardGenerator(availability: .unavailable(.deviceNotEligible)))
        let word = try store.add("book").word
        unavailable.enqueue(word)
        await unavailable.drain()
        #expect(try stored(word.id).autofillState == .unavailable)
        #expect(try stored(word.id).senses.isEmpty)
        #expect(unavailable.lastFailure[word.id] == .unavailable(.deviceNotEligible))

        let failing = try makeService(ThrowingCardGenerator(error: .failed("x")))
        let second = try store.add("apple").word
        failing.enqueue(second)
        await failing.drain()
        #expect(try stored(second.id).autofillState == .failed)
        #expect(failing.lastFailure[second.id] == .failed("x"))

        let refusing = try makeService(ThrowingCardGenerator(error: .refused))
        let third = try store.add("cat").word
        refusing.enqueue(third)
        await refusing.drain()
        #expect(try stored(third.id).autofillState == .failed)
        #expect(refusing.lastFailure[third.id] == .refused)
    }

    @Test("a failing topic stream leaves the card ready")
    func aFailingTopicStreamLeavesTheCardReady() async throws {
        let stub = StubCardGenerator()
        stub.topicExampleOverrides = [.init(1, Self.presentPerfect): .failure(.failed("boom"))]
        let service = try makeService(stub, topics: [Self.presentPerfect])
        let word = try store.add("book").word

        service.enqueue(word)
        await service.drain()

        let ready = try stored(word.id)
        #expect(ready.autofillState == .ready)
        #expect(ready.sortedSenses.map { $0.examples.filter { $0.grammarTopic != nil }.count } == [1, 0])
        #expect(service.lastFailure[word.id] == nil)
    }

    @Test("retry re-queues a failed word")
    func retryRequeuesAFailedWord() async throws {
        let stub = StubCardGenerator(fixtures: [:], fallback: nil)
        let service = try makeService(stub)
        let word = try store.add("book").word
        service.enqueue(word)
        await service.drain()
        #expect(try stored(word.id).autofillState == .failed)

        stub.fixtures = StubFixtures.cards
        service.retry(word)
        #expect(try stored(word.id).autofillState == .pending, "retry marks the word pending at once")
        await service.drain()
        #expect(try stored(word.id).autofillState == .ready)
        #expect(try stored(word.id).senses.count == 2)
        #expect(service.lastFailure[word.id] == nil)

        let generator = GatedCardGenerator()
        let gated = try makeService(generator)
        let second = try store.add("apple").word
        gated.enqueue(second)
        try await waitUntil { generator.cardGate.waiting == 1 }
        gated.retry(second)
        gated.enqueue(second)
        generator.cardGate.open()
        await gated.drain()
        #expect(generator.inner.requests.count == 1, "retry and enqueue on a filling word are no-ops")
    }

    @Test("the queue fills one word at a time")
    func theQueueFillsOneWordAtATime() async throws {
        let generator = GatedCardGenerator()
        let service = try makeService(generator)
        let words = try ["book", "apple", "cat"].map { try store.add($0).word }

        for word in words {
            service.enqueue(word)
        }
        try await waitUntil { generator.cardGate.waiting == 1 }
        #expect(generator.cardGate.arrivals == 1, "the second call waits for the first")
        generator.cardGate.open()
        await service.drain()

        #expect(generator.maxInFlight == 1)
        #expect(generator.completed == ["book", "apple", "cat"])
        #expect(try words.allSatisfy { try stored($0.id).autofillState == .ready })
    }

    @Test("a word deleted while filling gets no senses")
    func aWordDeletedWhileFillingGetsNoSenses() async throws {
        let generator = GatedCardGenerator()
        let service = try makeService(generator)
        let word = try store.add("book").word

        service.enqueue(word)
        try await waitUntil { generator.cardGate.waiting == 1 }
        try store.delete(word)
        generator.cardGate.open()
        await service.drain()

        let tombstone = try stored(word.id)
        #expect(tombstone.deletedAt != nil)
        #expect(tombstone.senses.isEmpty)
        #expect(tombstone.autofillState == .filling)
        #expect(service.lastFailure[word.id] == nil)
    }

    @Test("not found is ready with no senses")
    func notFoundIsReadyWithNoSenses() async throws {
        let stub = StubCardGenerator()
        let service = try makeService(stub, topics: [Self.presentPerfect])
        let word = try store.add("asdfgh").word

        service.enqueue(word)
        await service.drain()

        #expect(try stored(word.id).autofillState == .ready)
        #expect(try stored(word.id).senses.isEmpty)
        #expect(service.lastFailure[word.id] == nil)
        #expect(stub.topicRequests.isEmpty, "no senses, no topic stream")
    }

    @Test("the request carries the headword and the resolved topics")
    func theRequestCarriesResolvedTopics() async throws {
        let stub = StubCardGenerator()
        let service = try makeService(stub, topics: [Self.presentPerfect, "en.bogus"])
        let word = try store.add("book").word
        service.enqueue(word)
        await service.drain()

        let request = try #require(stub.requests.first)
        #expect(request.headword == "book")
        #expect(request.topics == [GrammarCatalog.english.topic(for: Self.presentPerfect)].compactMap(\.self))
        #expect(request.topics.first?.description.isEmpty == false)
    }
}
