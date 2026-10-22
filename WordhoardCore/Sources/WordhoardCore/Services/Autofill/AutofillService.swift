import Foundation
import Observation
import os

/// Fills words in after they are saved (requirements C5, A2, A6, A7; issue #39).
///
/// **Isolation: `@MainActor`**, like the `WordStore` it writes through and the view models beside it.
/// One worker task drains a FIFO of word ids, one word at a time. Every store access happens on the
/// main actor between awaits; the generator is `Sendable` and its `nonisolated` calls run off the main
/// actor, and only value DTOs cross that boundary (`@Model` objects never leave the main actor).
///
/// Per word: re-fetch by id (skip when gone or soft-deleted) → `filling` saved **before** the call →
/// `generateCard` → re-fetch (deleted meanwhile → discard) → **one** `WordStore.transaction` that merges
/// the first card through `CardMerger` and sets `ready` + `updatedAt`, so the card and its state are one
/// commit and a kill at any moment leaves the word either untouched-and-`filling` or complete → the topic
/// stream, merged and saved per example as they arrive. `.unavailable` → state `unavailable`; any other
/// error → `failed`; a stream error leaves the card `ready` (topic examples are optional, A2); a
/// `CancellationError` writes nothing and the launch sweep (`resumeAfterLaunch`) re-queues the word.
@MainActor
@Observable
public final class AutofillService {
    /// The word being filled or receiving topic examples; `nil` when idle.
    public private(set) var currentWordID: UUID?

    /// Why a word is `failed` or `unavailable`, for this session only; nothing is stored.
    public private(set) var lastFailure: [UUID: CardGeneratorError] = [:]

    /// The card (2.5) reads availability through it before offering "Fill in".
    public let generator: any CardGenerator

    private let store: WordStore
    private let catalog: GrammarCatalog
    private let logger = Logger(subsystem: "Wordhoard", category: "autofill")

    @ObservationIgnored
    private var queue: [UUID] = []
    @ObservationIgnored
    private var worker: Task<Void, Never>?

    public init(store: WordStore, generator: any CardGenerator, catalog: GrammarCatalog = .english) {
        self.store = store
        self.generator = generator
        self.catalog = catalog
    }

    // MARK: - Queue

    /// Marks `word` `pending` (unless it already is, or is `filling`), saves, appends it to the queue and
    /// starts the worker if it is idle. A word already queued, or whose card is being generated right
    /// now, is not added twice; the word whose topic examples are still arriving is queued again, so it
    /// is refilled once they finish.
    public func enqueue(_ word: Word) {
        if word.id == currentWordID, word.autofillState == .filling {
            return
        }
        if word.autofillState != .pending, word.autofillState != .filling {
            word.autofillState = .pending
            do {
                try store.save(word)
            } catch {
                logger.error("Could not mark \(word.id) pending: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !queue.contains(word.id) else {
            return
        }
        queue.append(word.id)
        startWorkerIfNeeded()
    }

    /// Re-queues `word` in any state except `filling` ("Try again", and 2.5's "Fill in again").
    public func retry(_ word: Word) {
        guard word.autofillState != .filling else {
            return
        }
        enqueue(word)
    }

    /// The launch and foreground sweep: every active `filling` word becomes `pending` in one save (the
    /// app was killed mid-fill), then every `pending` word is queued oldest first. Idempotent.
    public func resumeAfterLaunch() throws {
        let words = try store.words().sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let interrupted = words.filter { $0.autofillState == .filling && $0.id != currentWordID }
        if !interrupted.isEmpty {
            try store.transaction { _ in
                for word in interrupted {
                    word.autofillState = .pending
                }
            }
            logger.notice("Re-queued \(interrupted.count) interrupted fill(s)")
        }
        for word in words where word.autofillState == .pending {
            enqueue(word)
        }
    }

    /// Stops the worker. The running generator call is cancelled and its result discarded; the word it
    /// was filling stays `filling` until the next `resumeAfterLaunch()`, exactly as after a kill.
    public func cancel() {
        queue.removeAll()
        worker?.cancel()
    }

    /// Waits until the queue is empty and the worker idle. For tests and previews.
    public func drain() async {
        while let worker {
            await worker.value
        }
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else {
            return
        }
        worker = Task { [weak self] in
            await self?.work()
        }
    }

    private func work() async {
        while !Task.isCancelled, !queue.isEmpty {
            let id = queue.removeFirst()
            currentWordID = id
            await fill(id)
            currentWordID = nil
        }
        worker = nil
    }

    private func fill(_ id: UUID) async {
        guard let word = activeWord(id) else {
            return
        }
        word.autofillState = .filling
        do {
            try store.save(word)
        } catch {
            word.autofillState = .pending
            logger.error("Could not mark \(id) filling: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let request = makeRequest(for: word) else {
            return
        }
        let card: GeneratedCard
        do {
            card = try await generator.generateCard(request)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled {
                return
            }
            record(error, for: id)
            return
        }

        guard let senseIDs = commit(card, to: id) else {
            return
        }
        guard !senseIDs.isEmpty, !request.topics.isEmpty else {
            return
        }
        await addTopicExamples(for: card, request: request, wordID: id, senseIDs: senseIDs)
    }

    /// The first card and `ready` in one transaction. Returns the merged sense ids, or `nil` when the word
    /// was deleted meanwhile (the card is discarded) or the save failed (the word is marked `failed`).
    private func commit(_ card: GeneratedCard, to id: UUID) -> [UUID]? {
        guard let word = activeWord(id) else {
            logger.notice("Discarding a card for \(id): the word was deleted while filling")
            return nil
        }
        do {
            let senseIDs = try store.transaction { _ in
                let ids = CardMerger.apply(card, to: word)
                word.autofillState = .ready
                word.updatedAt = .now
                return ids
            }
            lastFailure[id] = nil
            logger.info(
                "Filled \(id): \(senseIDs.count, privacy: .public) senses via \(card.path.rawValue, privacy: .public)"
            )
            return senseIDs
        } catch {
            logger.error("Could not save the card for \(id): \(error.localizedDescription, privacy: .public)")
            record(CardGeneratorError.failed(error.localizedDescription), for: id)
            return nil
        }
    }

    /// Stage 2, saved per example. A stream error is logged and leaves the card `ready`.
    private func addTopicExamples(for card: GeneratedCard, request: CardRequest, wordID: UUID, senseIDs: [UUID]) async {
        do {
            for try await topicExample in generator.generateTopicExamples(for: card, request: request) {
                guard let word = activeWord(wordID) else {
                    return
                }
                guard senseIDs.indices.contains(topicExample.senseIndex) else {
                    continue
                }
                let senseID = senseIDs[topicExample.senseIndex]
                guard let sense = word.senses.first(where: { $0.id == senseID }) else {
                    continue
                }
                CardMerger.apply(topicExample.example, to: sense)
                try store.save(word)
            }
        } catch is CancellationError {
            return
        } catch {
            logger.notice("Topic examples for \(wordID) stopped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// The word with `id` when it exists and is not soft-deleted.
    private func activeWord(_ id: UUID) -> Word? {
        do {
            guard let word = try store.word(id: id), word.deletedAt == nil else {
                return nil
            }
            return word
        } catch {
            logger.error("Could not fetch \(id): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Topics are the settings' active keys resolved through the catalog; unknown keys are dropped and
    /// logged once per fill.
    private func makeRequest(for word: Word) -> CardRequest? {
        do {
            let settings = try store.settings()
            let keys = settings.activeGrammarTopics
            let dropped = keys.filter { catalog.topic(for: $0) == nil }
            if !dropped.isEmpty {
                logger.notice("Dropped unknown grammar topics: \(dropped.joined(separator: ", "), privacy: .public)")
            }
            return CardRequest(
                headword: word.headword,
                nativeLanguage: settings.nativeLanguage,
                topics: keys.compactMap(catalog.topic(for:))
            )
        } catch {
            logger.error("Could not read settings: \(error.localizedDescription, privacy: .public)")
            record(CardGeneratorError.failed(error.localizedDescription), for: word.id)
            return nil
        }
    }

    /// Maps a generator error to a stored state and remembers the reason for this session.
    private func record(_ error: any Error, for id: UUID) {
        let failure = (error as? CardGeneratorError) ?? .failed(error.localizedDescription)
        lastFailure[id] = failure
        guard let word = activeWord(id) else {
            return
        }
        if case .unavailable = failure {
            word.autofillState = .unavailable
        } else {
            word.autofillState = .failed
        }
        let state = word.autofillState.rawValue
        let reason = String(describing: failure)
        logger.notice("Fill of \(id) ended \(state, privacy: .public): \(reason, privacy: .public)")
        do {
            try store.save(word)
        } catch {
            logger.error("Could not save the state of \(id): \(error.localizedDescription, privacy: .public)")
        }
    }
}
