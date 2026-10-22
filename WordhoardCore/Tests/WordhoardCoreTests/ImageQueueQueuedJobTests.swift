import Foundation
import SwiftData
import Testing
import WordhoardCore

/// User actions on a word whose picture job is still waiting in the queue (qa, PR #63). The queue is
/// suspended while the jobs are queued, so no job has started when the action happens.
@MainActor
@Suite("ImageGenerationQueue user actions on a queued job")
struct ImageQueueQueuedJobTests {
    @Test("a word deleted while its picture job is queued is skipped and leaves no file")
    func aWordDeletedWhileQueuedIsSkipped() async throws {
        let fixture = try ImageQueueFixture()
        fixture.queue.isSuspended = true
        let apple = try fixture.add("apple")
        let pear = try fixture.add("pear")
        #expect(pear.imageStatus == .pending)

        #expect(fixture.cardModel(pear).deleteWord())
        fixture.queue.isSuspended = false
        await fixture.queue.drain()

        #expect(fixture.writer.calls.map(\.headword) == ["apple"])
        #expect(fixture.generator.prompts.count == 1)
        #expect(pear.image == nil)
        let picture = try #require(apple.image?.fileName)
        #expect(fixture.directory.allFiles == [picture, ImageStore.thumbnailFileName(for: picture)])
        #expect(try fixture.assetCount() == 1)
        #expect(try fixture.store.wordsPendingImages().isEmpty)
    }

    @Test("a deleted word left pending is not resumed by the next launch")
    func aDeletedPendingWordIsNotResumed() async throws {
        let fixture = try ImageQueueFixture()
        fixture.queue.isSuspended = true
        let pear = try fixture.add("pear")
        // A delete that bypasses the card model, so the queue is never told: the status stays `.pending`.
        try fixture.store.delete(pear)

        let relaunched = ImageGenerationQueue(
            store: fixture.store,
            imageStore: fixture.directory.store,
            generator: fixture.generator,
            promptWriter: fixture.writer
        )
        relaunched.isSceneActive = true
        try relaunched.resumePending()
        await relaunched.drain()
        #expect(fixture.writer.calls.isEmpty)
        #expect(fixture.directory.allFiles.isEmpty)
        #expect(try fixture.assetCount() == 0)
    }

    @Test("a photo chosen while the picture job is queued wins and nothing is generated for it")
    func aPhotoChosenWhileQueuedWins() async throws {
        let fixture = try ImageQueueFixture()
        fixture.queue.isSuspended = true
        let apple = try fixture.add("apple")
        let pear = try fixture.add("pear")

        #expect(try fixture.cardModel(pear).setImage(data: makePNG(width: 20, height: 20), source: .library))
        let photo = try #require(pear.image?.fileName)
        fixture.queue.isSuspended = false
        await fixture.queue.drain()

        #expect(fixture.writer.calls.map(\.headword) == ["apple"])
        #expect(pear.image?.source == .library)
        #expect(pear.image?.fileName == photo)
        #expect(pear.imageStatus == nil)
        let picture = try #require(apple.image?.fileName)
        #expect(fixture.directory.allFiles == [
            picture, ImageStore.thumbnailFileName(for: picture),
            photo, ImageStore.thumbnailFileName(for: photo),
        ])
        #expect(try fixture.assetCount() == 2)
    }

    @Test("removing the picture of a word whose job is queued clears the status and generates nothing")
    func removingWhileQueuedStopsTheJob() async throws {
        let fixture = try ImageQueueFixture()
        fixture.queue.isSuspended = true
        let pear = try fixture.add("pear")

        fixture.cardModel(pear).removeImage()
        #expect(pear.imageStatus == nil)
        fixture.queue.isSuspended = false
        await fixture.queue.drain()

        #expect(fixture.writer.calls.isEmpty)
        #expect(pear.image == nil)
        #expect(fixture.directory.allFiles.isEmpty)
    }

    @Test("the launch orphan scan's default age keeps a file written within the last minute")
    func orphanScanDefaultAgeKeepsRecentFiles() throws {
        let directory = TemporaryImageDirectory()
        let images = directory.store
        let fresh = try images.write(makePNG(width: 10, height: 10), id: UUID())
        let recent = try images.write(makePNG(width: 10, height: 10), id: UUID())
        try backdate(images.url(for: recent), by: 30)
        try backdate(images.thumbnailURL(for: recent), by: 30)
        let old = try images.write(makePNG(width: 10, height: 10), id: UUID())
        try backdate(images.url(for: old), by: 120)
        try backdate(images.thumbnailURL(for: old), by: 120)

        // The app calls the scan without an age, so the 60 s default is the one that matters.
        #expect(try images.removeOrphans(keeping: []) == 1)
        #expect(directory.allFiles == [
            fresh, ImageStore.thumbnailFileName(for: fresh),
            recent, ImageStore.thumbnailFileName(for: recent),
        ])
    }
}
