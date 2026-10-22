import Foundation
import SwiftData
import Testing
import WordhoardCore

/// qa edge cases for the autofill queue and regenerate (issues #39, #40, #41): user structure changes
/// between fills, deletions while queued, and topic examples that arrive for a sense that is gone.
@MainActor
@Suite("AutofillService edge cases")
struct AutofillEdgeCaseTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
        try store.settings().activeGrammarTopics = [presentPerfectKey]
    }

    private func stored(_ id: UUID) throws -> Word {
        try #require(try storedWordOrNil(id, in: container))
    }

    /// `book` filled through the service with its topic examples; returns the word.
    private func filledBook(_ service: AutofillService) async throws -> Word {
        let word = try store.add("book").word
        service.enqueue(word)
        await service.drain()
        #expect(try stored(word.id).senses.count == 2)
        return word
    }

    @Test("fill in again brings back a WordNet sense the user removed (open question on #40)")
    func fillInAgainRestoresARemovedAutoSense() async throws {
        let stub = StubCardGenerator()
        let service = AutofillService(store: store, generator: stub)
        let word = try await filledBook(service)
        let card = WordCardModel(word: word, store: store)
        let verb = try #require(word.sortedSenses.last)
        let removedID = verb.id
        card.removeSense(verb)
        #expect(try stored(word.id).senses.count == 1)

        service.retry(word)
        await service.drain()

        let refilled = try stored(word.id)
        #expect(refilled.autofillState == .ready)
        #expect(refilled.sortedSenses.map(\.partOfSpeech) == [.noun, .verb], "nothing remembers the removal")
        let restored = try #require(refilled.sortedSenses.last)
        #expect(restored.id != removedID)
        #expect(restored.gloss == GeneratorFixtures.reserveGloss)
        #expect(refilled.sortedSenses.map(\.order) == [0, 1])
        #expect(restored.examples.count == 2, "a fresh neutral and topic example, not doubled")
    }

    @Test("fill in again after the user changed a sense's part of speech keeps it and re-adds the verb")
    func fillInAgainAfterAPartOfSpeechChangeKeepsTheEditedSense() async throws {
        let service = AutofillService(store: store, generator: StubCardGenerator())
        let word = try await filledBook(service)
        let card = WordCardModel(word: word, store: store)
        let verb = try #require(word.sortedSenses.last)
        card.setPartOfSpeech(.adjective, for: verb)
        card.setDefinition("mine", for: verb)

        service.retry(word)
        await service.drain()

        let refilled = try stored(word.id)
        #expect(refilled.sortedSenses.map(\.partOfSpeech) == [.noun, .adjective, .verb])
        let edited = refilled.sortedSenses[1]
        #expect(edited.id == verb.id)
        #expect(edited.definition == "mine")
        #expect(edited.fieldSource(for: .definition) == .user)
        #expect(refilled.sortedSenses.map(\.order) == [0, 1, 2])
        #expect(refilled.sortedSenses[0].examples.count == 2, "the matched noun is not doubled")
    }

    @Test("a not-found fill leaves hand-entered senses untouched and the word ready")
    func notFoundKeepsHandSensesAndIsReady() async throws {
        let service = AutofillService(store: store, generator: StubCardGenerator())
        let word = try store.add("asdfgh").word
        let card = WordCardModel(word: word, store: store)
        let sense = card.addSense()
        card.setDefinition("my own meaning", for: sense)
        let before = MergeSnapshot(word)

        service.enqueue(word)
        await service.drain()

        let filled = try stored(word.id)
        #expect(filled.autofillState == .ready)
        #expect(MergeSnapshot(filled) == before)
        #expect(service.lastFailure[word.id] == nil)
    }

    @Test("words added while one is filling wait their turn and fill oldest first")
    func wordsAddedDuringAFillAreFilledInOrder() async throws {
        let generator = GatedCardGenerator()
        let service = AutofillService(store: store, generator: generator)
        let list = WordListModel(store: store, autofill: service)
        for headword in ["book", "apple", "cat"] {
            list.draft = headword
            _ = list.addDraft()
            if headword == "book" {
                try await waitUntil { generator.cardGate.waiting == 1 }
            }
        }
        #expect(try store.words().filter { $0.autofillState == .pending }.count == 2)
        generator.cardGate.open()
        await service.drain()

        #expect(generator.maxInFlight == 1)
        #expect(generator.completed == ["book", "apple", "cat"])
    }

    @Test("a word deleted while it waits in the queue is skipped")
    func aWordDeletedWhilePendingIsSkipped() async throws {
        let generator = GatedCardGenerator()
        let service = AutofillService(store: store, generator: generator)
        let first = try store.add("book").word
        let second = try store.add("apple").word
        service.enqueue(first)
        service.enqueue(second)
        try await waitUntil { generator.cardGate.waiting == 1 }
        try store.delete(second)
        generator.cardGate.open()
        await service.drain()

        #expect(generator.inner.requests.map(\.headword) == ["book"])
        let tombstone = try stored(second.id)
        #expect(tombstone.senses.isEmpty)
        #expect(tombstone.autofillState == .pending)
        #expect(try stored(first.id).autofillState == .ready)
    }

    @Test("tapping fill in again twice queues one fill")
    func retryingTwiceQueuesOneFill() async throws {
        let stub = StubCardGenerator()
        let service = AutofillService(store: store, generator: stub)
        let word = try await filledBook(service)

        service.retry(word)
        service.retry(word)
        await service.drain()

        #expect(stub.requests.count == 2, "the first fill and one refill")
        #expect(try stored(word.id).sortedSenses.map(\.examples.count) == [2, 2])
    }

    @Test("retrying the word whose topic examples are still arriving refills it after they finish")
    func retryDuringTheTopicStreamQueuesARefill() async throws {
        let generator = GatedCardGenerator(cardsOpen: true, topicsOpen: false)
        let service = AutofillService(store: store, generator: generator)
        let word = try store.add("book").word
        service.enqueue(word)
        try await waitUntil { try stored(word.id).autofillState == .ready }
        try await waitUntil { generator.topicGate.waiting == 1 }
        #expect(service.currentWordID == word.id)

        service.retry(word)
        generator.topicGate.open()
        await service.drain()

        #expect(generator.inner.requests.count == 2, "the first fill and the refill")
        #expect(try stored(word.id).autofillState == .ready, "not left pending")
        #expect(service.currentWordID == nil)
    }

    @Test("a topic example for a sense the user removed meanwhile is dropped")
    func aTopicExampleForARemovedSenseIsDropped() async throws {
        let generator = GatedCardGenerator(topicsOpen: false)
        generator.cardGate.open()
        let service = AutofillService(store: store, generator: generator)
        let word = try store.add("book").word
        service.enqueue(word)
        try await waitUntil { try stored(word.id).autofillState == .ready }
        try await waitUntil { generator.topicGate.waiting == 1 }

        let card = WordCardModel(word: word, store: store)
        let verb = try #require(word.sortedSenses.last)
        card.removeSense(verb)
        generator.topicGate.open()
        await service.drain()

        let filled = try stored(word.id)
        #expect(filled.senses.count == 1)
        let noun = try #require(filled.senses.first)
        #expect(noun.examples.map(\.grammarTopic).sorted { ($0 ?? "") < ($1 ?? "") } == [nil, presentPerfectKey])
        #expect(filled.autofillState == .ready)
    }

    @Test("fill in again keeps a user translation and its cleared fallback flag")
    func fillInAgainKeepsAUserTranslationUnflagged() async throws {
        let service = AutofillService(store: store, generator: StubCardGenerator())
        let word = try store.add("look up").word
        service.enqueue(word)
        await service.drain()
        let sense = try #require(word.sortedSenses.first)
        #expect(sense.translationIsFallback, "the look up fixture carries a fallback translation")

        WordCardModel(word: word, store: store).setTranslation("искать", for: sense)
        service.retry(word)
        await service.drain()

        let refilled = try #require(try stored(word.id).sortedSenses.first)
        #expect(refilled.translation == "искать")
        #expect(refilled.fieldSource(for: .translation) == .user)
        #expect(refilled.translationIsFallback == false)
    }
}
