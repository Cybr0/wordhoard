import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `ImageGenerationQueue` (plan 4.4, #49): manual Generate, bookkeeping, the toggle, waiting and the
/// foreground rule.
@MainActor
@Suite("ImageGenerationQueue manual and foreground")
struct ImageGenerationQueueEdgeTests {
    @Test("Remove clears the status and a manual Generate replaces any picture")
    func manualGenerateReplacesAnyPicture() async throws {
        let skipped = try ImageQueueFixture(writer: StubImagePromptWriter(result: .success(nil)))
        let apple = try skipped.add("apple")
        await skipped.queue.drain()
        #expect(apple.imageStatus == .skipped)
        skipped.cardModel(apple).removeImage()
        #expect(apple.imageStatus == nil)

        let fixture = try ImageQueueFixture()
        try fixture.store.updateSettings { $0.autoGenerateImages = false }
        let book = try fixture.add("book")
        let card = fixture.cardModel(book)
        try card.setImage(data: makePNG(width: 20, height: 20), source: .library)
        let photo = try #require(book.image?.fileName)

        card.generateImage()
        #expect(book.imageStatus == .pending)
        await fixture.queue.drain()
        #expect(book.image?.source == .generated)
        #expect(!fixture.directory.store.exists(photo))
        #expect(try fixture.assetCount() == 1)
    }

    @Test("image status is bookkeeping, not content")
    func imageStatusIsBookkeepingNotContent() throws {
        let fixture = try ImageQueueFixture()
        let word = try fixture.store.add("apple").word
        let past = Date(timeIntervalSince1970: 1000)
        try fixture.store.transaction { _ in
            word.updatedAt = past
        }
        try fixture.store.setImageStatus(.pending, for: word)
        #expect(word.updatedAt == past)
        #expect(try fixture.storedWord(word).imageStatus == .pending)

        try fixture.store.setImage(ImageAsset(fileName: "a.jpg", source: .library), for: word)
        #expect(word.updatedAt > past)
        #expect(word.imageStatus == nil)
    }

    @Test("a job for a word still being filled waits until it is resumed")
    func aJobWaitsForTheFirstCard() async throws {
        let fixture = try ImageQueueFixture()
        fixture.queue.waitsFor = { $0.autofillState == .pending }
        let word = try fixture.add("apple")
        await fixture.queue.drain()
        #expect(fixture.writer.calls.isEmpty)
        #expect(word.imageStatus == .pending)

        try fixture.store.transaction { _ in
            word.autofillState = .ready
        }
        try fixture.queue.resumePending()
        await fixture.queue.drain()
        #expect(word.image != nil)
    }

    @Test("a failure while the scene is inactive leaves the word pending, and no job starts while inactive")
    func backgroundFailuresStayPending() async throws {
        let fixture = try ImageQueueFixture(generator: StubImageGenerator(outcome: .failed), holdsGenerator: true)
        let word = try fixture.add("apple")
        await fixture.generatorGate.untilWaiting(1)
        fixture.queue.isSceneActive = false
        fixture.generatorGate.open()
        await fixture.queue.drain()
        #expect(word.imageStatus == .pending)

        let pear = try fixture.add("pear")
        await fixture.queue.drain()
        #expect(fixture.generator.prompts.count == 1, "nothing starts in the background")
        #expect(pear.imageStatus == .pending)
    }

    /// A Siri cold launch never makes a scene active, so the queue must not assume one (review must-fix 2).
    @Test("a queue created inactive starts no job until the scene becomes active")
    func aNewQueueStartsInactive() async throws {
        let fixture = try ImageQueueFixture()
        let word = try fixture.store.add("apple").word
        try fixture.store.setImageStatus(.pending, for: word)
        let launched = ImageGenerationQueue(
            store: fixture.store,
            imageStore: fixture.directory.store,
            generator: fixture.generator,
            promptWriter: fixture.writer
        )
        launched.isSuspended = true
        try launched.resumePending()
        launched.isSuspended = false
        await launched.drain()
        #expect(fixture.writer.calls.isEmpty, "a background launch starts nothing")
        #expect(word.imageStatus == .pending)

        launched.isSceneActive = true
        await launched.drain()
        #expect(word.image?.source == .generated)
    }

    @Test("Image Playground refusing a background creation leaves the word pending, even while active")
    func aBackgroundRefusalStaysPending() async throws {
        let fixture = try ImageQueueFixture(generator: StubImageGenerator(outcome: .backgroundForbidden))
        let word = try fixture.add("apple")
        await fixture.queue.drain()
        #expect(fixture.generator.prompts.count == 1)
        #expect(word.imageStatus == .pending)
        #expect(try fixture.storedWord(word).imageStatus == .pending)
        #expect(fixture.directory.allFiles.isEmpty)
    }
}

/// Regression found in the simulator pass: the autofill hook can call `resumePending()` while the job
/// that just put the word off is still the running one; the word must be queued again, not skipped.
@MainActor
@Suite("ImageGenerationQueue resume during a put-off job")
struct ImageGenerationQueueResumeRaceTests {
    @Test("a word resumed while its put-off job is still running gets its picture")
    func aWordResumedWhileItsJobRunsIsQueuedAgain() async throws {
        let fixture = try ImageQueueFixture()
        var isFilling = true
        let queue = fixture.queue
        queue.waitsFor = { _ in
            guard isFilling else {
                return false
            }
            // The first card settles while this job is deciding: the hook resumes the queue now.
            isFilling = false
            try? queue.resumePending()
            return true
        }
        let word = try fixture.add("apple")
        await queue.drain()
        #expect(word.image?.source == .generated)
        #expect(word.imageStatus == nil)
    }
}
