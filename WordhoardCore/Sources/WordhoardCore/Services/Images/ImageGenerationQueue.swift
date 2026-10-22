import Foundation
import Observation
import os

/// Makes pictures for words in the background while the app is open (I1, I3, I4, I5; plan 4.4, #49).
///
/// **Isolation: `@MainActor`**, like the `WordStore` it writes through. One worker drains a FIFO of word
/// ids, one job at a time (Image Playground is heavy). Per job: re-read the word (stop when deleted or no
/// longer `.pending`) → both availabilities → `ImagePromptWriter.imagePrompt` (`nil` → `.skipped`) →
/// `ImageGenerator.generate` → `ImageStore.write` off the main actor → re-read the word: deleted, or no
/// longer `.pending` because the user chose or removed a picture meanwhile → the new file is deleted and
/// nothing else changes; otherwise `WordStore.setImage` with a `.generated` asset carrying the prompt,
/// which clears the status. Every other outcome is a status (`.skipped`, `.refused`, `.failed`,
/// `.unavailable`) and never an alert (I4: the card simply has no picture). Cancellation writes nothing.
///
/// Foreground only: the worker does not start a job while `isSceneActive` is `false` or `isSuspended` is
/// `true` (the app suspends it until the launch orphan scan has finished), and a generator failure while
/// the scene is not active puts the word back to `.pending` (`backgroundCreationForbidden`), to be resumed
/// by `resumePending()` on the next `.active`.
@MainActor
@Observable
public final class ImageGenerationQueue {
    /// The word whose picture is being made; `nil` when idle.
    public private(set) var runningWordID: UUID?

    /// The card offers "Generate picture" only when both report `.available`.
    public let generator: any ImageGenerator
    public let promptWriter: any ImagePromptWriter

    /// Set by the app from the scene phase. Turning it on starts the worker if anything is queued.
    @ObservationIgnored
    public var isSceneActive = true {
        didSet { startWorkerIfNeeded() }
    }

    /// While `true` no job starts; jobs are still queued. Turning it off starts the worker.
    @ObservationIgnored
    public var isSuspended = false {
        didSet { startWorkerIfNeeded() }
    }

    /// A job for a word this returns `true` for is put off and stays `.pending`; the app passes "the
    /// first card is still being filled", so the prompt writer gets a definition, and calls
    /// `resumePending()` when it is. Defaults to never waiting.
    @ObservationIgnored
    public var waitsFor: @MainActor (Word) -> Bool = { _ in false }

    private let store: WordStore
    private let imageStore: ImageStore
    private let logger = Logger(subsystem: "Wordhoard", category: "images")

    @ObservationIgnored
    private var queue: [UUID] = []
    @ObservationIgnored
    private var worker: Task<Void, Never>?
    @ObservationIgnored
    private var job: Task<Void, Never>?

    public init(
        store: WordStore,
        imageStore: ImageStore,
        generator: any ImageGenerator,
        promptWriter: any ImagePromptWriter
    ) {
        self.store = store
        self.imageStore = imageStore
        self.generator = generator
        self.promptWriter = promptWriter
    }

    // MARK: - Queue

    /// Queues a picture for `word`: marks it `.pending` (saved, no `updatedAt` bump) and starts the
    /// worker. Without `force` this is the automatic path and does nothing when
    /// `UserSettings.autoGenerateImages` is off or the word already has a picture; `force` is the card's
    /// "Generate picture", which ignores the toggle and replaces any picture. A deleted word, or one
    /// already queued, is not queued again.
    public func enqueue(_ word: Word, force: Bool = false) throws {
        guard word.deletedAt == nil else {
            return
        }
        if !force {
            guard try store.settings().autoGenerateImages, word.image == nil else {
                return
            }
        }
        try store.setImageStatus(.pending, for: word)
        guard !queue.contains(word.id), runningWordID != word.id else {
            return
        }
        queue.append(word.id)
        startWorkerIfNeeded()
    }

    /// Queues every active `.pending` word, oldest first: at launch (after a kill) and on every
    /// foreground. Idempotent.
    public func resumePending() throws {
        for word in try store.wordsPendingImages() where !queue.contains(word.id) && runningWordID != word.id {
            queue.append(word.id)
        }
        startWorkerIfNeeded()
    }

    /// Drops `wordID` from the queue and cancels its job if it is running (Remove picture, a chosen
    /// photo, delete word). The status is the caller's to change.
    public func cancel(_ wordID: UUID) {
        queue.removeAll { $0 == wordID }
        if runningWordID == wordID {
            job?.cancel()
        }
    }

    /// Waits until the queue is empty and the worker idle. For tests and previews.
    public func drain() async {
        while let worker {
            await worker.value
        }
    }

    // MARK: - Worker

    private var canRun: Bool {
        isSceneActive && !isSuspended
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, canRun, !queue.isEmpty else {
            return
        }
        worker = Task { [weak self] in
            await self?.work()
        }
    }

    private func work() async {
        while canRun, !queue.isEmpty {
            let id = queue.removeFirst()
            runningWordID = id
            let job = Task<Void, Never> { [weak self] in
                guard let self else {
                    return
                }
                await run(id)
            }
            self.job = job
            await job.value
            self.job = nil
            runningWordID = nil
        }
        worker = nil
    }

    private func run(_ id: UUID) async {
        guard let word = pendingWord(id), !waitsFor(word) else {
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await makePicture(for: word, id: id)
        let seconds = (clock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
        logger.info("Picture for \(id): \(outcome, privacy: .public) after \(seconds, privacy: .public)")
    }

    /// One job; returns a word for the log line.
    private func makePicture(for word: Word, id: UUID) async -> String {
        let headword = word.headword
        let definition = word.sortedSenses.first.map(\.definition).flatMap { $0.isEmpty ? nil : $0 }
        guard await promptWriter.availability == .available, await generator.availability == .available else {
            return finish(id, with: .unavailable)
        }
        let prompt: String
        do {
            guard let written = try await promptWriter.imagePrompt(headword: headword, definition: definition),
                  !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return finish(id, with: .skipped)
            }
            prompt = written
        } catch is CancellationError {
            return "cancelled"
        } catch {
            return finish(id, with: Self.status(for: error as? ImagePromptError))
        }
        guard pendingWord(id) != nil else {
            return "discarded"
        }
        let fileName: String
        let asset = ImageAsset(fileName: "", source: .generated, prompt: prompt)
        do {
            let result = try await generator.generate(prompt: prompt)
            let imageStore = imageStore
            let assetID = asset.id
            fileName = try await Task.detached(priority: .utility) {
                try imageStore.write(result.data, id: assetID)
            }.value
        } catch is CancellationError {
            return "cancelled"
        } catch {
            let status = Self.status(for: error as? ImageGeneratorError)
            return finish(id, with: status == .failed && !isSceneActive ? .pending : status)
        }
        return attach(asset, fileName: fileName, to: id)
    }

    /// The user action wins: a word deleted, given a picture or cleared meanwhile keeps what it has.
    private func attach(_ asset: ImageAsset, fileName: String, to id: UUID) -> String {
        guard !Task.isCancelled, let word = pendingWord(id) else {
            deleteFile(fileName)
            return "discarded"
        }
        asset.fileName = fileName
        do {
            if let previous = try store.setImage(asset, for: word) {
                deleteFile(previous)
            }
            return "picture"
        } catch {
            logger.error("Could not save the picture for \(id): \(error.localizedDescription, privacy: .public)")
            deleteFile(fileName)
            return finish(id, with: .failed)
        }
    }

    // MARK: - Helpers

    /// The active word with `id` whose status is still `.pending`.
    private func pendingWord(_ id: UUID) -> Word? {
        do {
            guard let word = try store.word(id: id), word.deletedAt == nil, word.imageStatus == .pending else {
                return nil
            }
            return word
        } catch {
            logger.error("Could not fetch \(id): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes a terminal (or, in the background, `.pending`) status unless the word moved on meanwhile.
    private func finish(_ id: UUID, with status: ImageStatus) -> String {
        guard let word = pendingWord(id) else {
            return "discarded"
        }
        do {
            try store.setImageStatus(status, for: word)
        } catch {
            logger.error("Could not save the picture status of \(id): \(error.localizedDescription, privacy: .public)")
        }
        return status.rawValue
    }

    private static func status(for error: ImagePromptError?) -> ImageStatus {
        switch error {
        case .unavailable:
            .unavailable
        case .refused:
            .refused
        case .failed, nil:
            .failed
        }
    }

    private static func status(for error: ImageGeneratorError?) -> ImageStatus {
        switch error {
        case .unavailable:
            .unavailable
        case .refused:
            .refused
        case .failed, nil:
            .failed
        }
    }

    private func deleteFile(_ fileName: String) {
        do {
            try imageStore.delete(fileName)
        } catch {
            logger.notice("Could not delete \(fileName, privacy: .public); the orphan scan will")
        }
    }
}
