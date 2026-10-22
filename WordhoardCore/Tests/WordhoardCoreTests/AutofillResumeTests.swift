import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `AutofillService` across launches (issue #39): the sweep that re-queues interrupted and pending words,
/// a kill mid-generation that leaves the word either untouched or complete, and the import rule.
@MainActor
@Suite("AutofillService resume and crash safety")
struct AutofillResumeTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func stored(_ id: UUID, in container: ModelContainer? = nil) throws -> Word {
        try #require(try storedWordOrNil(id, in: container ?? self.container))
    }

    @Test("resume re-queues filling and pending words oldest first")
    func resumeRequeuesFillingAndPendingWordsOldestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1000)
        let interrupted = try insertWord("book", state: .filling, createdAt: base, into: store)
        let pending = try insertWord("apple", state: .pending, createdAt: base + 1, into: store)
        let ready = try insertWord("cat", state: .ready, createdAt: base + 2, into: store)
        let failed = try insertWord("dog", state: .failed, createdAt: base + 3, into: store)
        let stub = StubCardGenerator()
        try store.settings().activeGrammarTopics = []
        let service = AutofillService(store: store, generator: stub)

        try service.resumeAfterLaunch()
        #expect(try stored(interrupted.id).autofillState == .pending, "reset before any fill starts")
        await service.drain()

        #expect(stub.requests.map(\.headword) == ["book", "apple"])
        #expect(try stored(interrupted.id).autofillState == .ready)
        #expect(try stored(pending.id).autofillState == .ready)
        #expect(try stored(ready.id).autofillState == .ready)
        #expect(try stored(ready.id).senses.isEmpty)
        #expect(try stored(failed.id).autofillState == .failed)
        #expect(try stored(failed.id).senses.isEmpty)

        try service.resumeAfterLaunch()
        await service.drain()
        #expect(stub.requests.count == 2, "a second sweep fills nothing twice")
    }

    @Test("a sweep while a fill is in flight does not queue that word again")
    func sweepDuringAFillDoesNotQueueTheCurrentWordTwice() async throws {
        let generator = GatedCardGenerator()
        try store.settings().activeGrammarTopics = []
        let service = AutofillService(store: store, generator: generator)
        let word = try store.add("book").word
        service.enqueue(word)
        try await waitUntil { generator.cardGate.waiting == 1 }

        try service.resumeAfterLaunch()
        #expect(try stored(word.id).autofillState == .filling, "the current word is not reset")
        generator.cardGate.open()
        await service.drain()

        #expect(generator.inner.requests.count == 1)
        #expect(try stored(word.id).autofillState == .ready)
    }

    @Test("a kill mid-generation leaves the word filling with no senses and the next launch fills it")
    func aKillMidGenerationLeavesTheWordUntouchedAndTheNextLaunchFillsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordhoard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Wordhoard.store")

        let wordID: UUID
        do {
            let first = try WordhoardContainer.makeOnDisk(url: url)
            let firstStore = WordStore(container: first)
            try firstStore.settings().activeGrammarTopics = []
            let generator = GatedCardGenerator()
            let service = AutofillService(store: firstStore, generator: generator)
            let word = try firstStore.add("book").word
            wordID = word.id
            service.enqueue(word)
            try await waitUntil { generator.cardGate.waiting == 1 }

            // The "kill": the worker is cancelled while the generator call is in flight.
            service.cancel()
            await service.drain()
            #expect(generator.cardGate.waiting == 0, "the cancelled call was released")
            #expect(service.currentWordID == nil)

            let interrupted = try stored(wordID, in: first)
            #expect(interrupted.autofillState == .filling)
            #expect(interrupted.senses.isEmpty, "nothing half-written")
        }

        let second = try WordhoardContainer.makeOnDisk(url: url)
        let secondStore = WordStore(container: second)
        let relaunched = AutofillService(store: secondStore, generator: StubCardGenerator())
        #expect(try stored(wordID, in: second).autofillState == .filling)

        try relaunched.resumeAfterLaunch()
        #expect(try stored(wordID, in: second).autofillState == .pending)
        await relaunched.drain()

        let filled = try stored(wordID, in: second)
        #expect(filled.autofillState == .ready)
        #expect(filled.sortedSenses.map(\.partOfSpeech) == [.noun, .verb])
    }

    @Test("a cancelled fill that already failed is not written either")
    func cancelBeforeTheCallWritesNothing() async throws {
        let generator = GatedCardGenerator()
        try store.settings().activeGrammarTopics = []
        let service = AutofillService(store: store, generator: generator)
        let words = try ["book", "apple"].map { try store.add($0).word }
        for word in words {
            service.enqueue(word)
        }
        try await waitUntil { generator.cardGate.waiting == 1 }

        service.cancel()
        await service.drain()

        #expect(try stored(words[0].id).autofillState == .filling)
        #expect(try stored(words[1].id).autofillState == .pending, "never started, never touched")
        #expect(service.lastFailure.isEmpty)
    }

    @Test("imported words are ready when they have senses")
    func importedWordsAreReadyWhenTheyHaveSenses() throws {
        let filled = makeWord(
            headword: "book",
            senses: [
                makeSense(order: 0, partOfSpeech: .noun, definition: "a written work"),
                makeSense(order: 1, partOfSpeech: .verb, definition: "to reserve"),
            ]
        )
        let empty = makeWord(headword: "apple", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let data = try makeDocument(words: [filled, empty]).encode()

        let summary = try Importer.import(data, into: store)

        #expect(summary.wordsCreated == 2)
        #expect(try stored(filled.id).autofillState == .ready)
        #expect(try stored(empty.id).autofillState == .pending)
    }
}
