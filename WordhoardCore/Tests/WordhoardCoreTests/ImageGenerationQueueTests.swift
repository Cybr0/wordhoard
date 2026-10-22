import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `ImageGenerationQueue` (plan 4.4, #49) with the stubs, an in-memory store and a temporary directory.
@MainActor
@Suite("ImageGenerationQueue")
struct ImageGenerationQueueTests {
    @Test("adding a word saves it, then queues a picture")
    func addingAWordSavesItThenQueuesAPicture() async throws {
        let fixture = try ImageQueueFixture(
            writer: StubImagePromptWriter(result: .success("a red apple"), delay: .milliseconds(200))
        )
        let word = try fixture.add("apple")
        #expect(word.imageStatus == .pending)
        #expect(try fixture.store.words().map(\.id) == [word.id])
        #expect(fixture.writer.calls.isEmpty, "the writer runs after the add has returned")
        await fixture.queue.drain()
        #expect(fixture.writer.calls == [.init(headword: "apple", definition: nil)])
    }

    @Test("a queued word ends with a generated picture")
    func aQueuedWordEndsWithAGeneratedPicture() async throws {
        let fixture = try ImageQueueFixture()
        let word = try fixture.add("apple")
        await fixture.queue.drain()

        let asset = try #require(word.image)
        #expect(asset.source == .generated)
        #expect(asset.prompt == "a red apple")
        #expect(word.imageStatus == nil)
        #expect(fixture.directory.store.exists(asset.fileName))
        #expect(fixture.directory.allFiles.contains(ImageStore.thumbnailFileName(for: asset.fileName)))
        #expect(fixture.queue.runningWordID == nil)
        #expect(fixture.generator.prompts == ["a red apple"])
        let stored = try fixture.storedWord(word)
        #expect(stored.image?.prompt == "a red apple")
    }

    @Test("the prompt writer gets the first sense's definition when the card has one")
    func theWriterGetsTheFirstDefinition() async throws {
        let fixture = try ImageQueueFixture()
        let word = try fixture.store.add("apple").word
        try fixture.store.transaction { _ in
            word.senses = [
                Sense(partOfSpeech: .noun, definition: "a round fruit", order: 0),
                Sense(partOfSpeech: .noun, definition: "a tree", order: 1),
            ]
        }
        try fixture.queue.enqueue(word)
        await fixture.queue.drain()
        #expect(fixture.writer.calls == [.init(headword: "apple", definition: "a round fruit")])
    }

    @Test("the toggle stops automatic pictures but not manual ones")
    func theToggleStopsAutomaticPicturesButNotManualOnes() async throws {
        let fixture = try ImageQueueFixture()
        try fixture.store.updateSettings { $0.autoGenerateImages = false }
        let word = try fixture.add("apple")
        #expect(word.imageStatus == nil)
        await fixture.queue.drain()
        #expect(fixture.writer.calls.isEmpty)

        try fixture.queue.enqueue(word, force: true)
        #expect(word.imageStatus == .pending)
        await fixture.queue.drain()
        #expect(word.image?.source == .generated)
    }

    @Test("re-adding a word does not queue it again")
    func reAddingAWordDoesNotQueueAgain() async throws {
        let fixture = try ImageQueueFixture()
        try fixture.add("apple")
        await fixture.queue.drain()
        try fixture.add("Apple ")
        await fixture.queue.drain()
        #expect(fixture.writer.calls.count == 1)
    }

    @Test("jobs run one at a time in creation order")
    func jobsRunOneAtATimeInCreationOrder() async throws {
        let fixture = try ImageQueueFixture(
            generator: StubImageGenerator(delay: .milliseconds(30)),
            writer: StubImagePromptWriter { .success("a picture of \($0)") }
        )
        try fixture.add("apple")
        try fixture.add("book")
        try fixture.add("pear")
        await fixture.queue.drain()
        #expect(fixture.generator.prompts == ["a picture of apple", "a picture of book", "a picture of pear"])
        #expect(fixture.generator.maxConcurrentCalls == 1)
    }

    enum Outcome: String, CaseIterable, CustomTestStringConvertible {
        case writerNil, writerRefused, writerUnavailable, writerFailed
        case generatorUnavailable, generatorRefused, generatorFailed

        var testDescription: String {
            rawValue
        }

        var expected: ImageStatus {
            switch self {
            case .writerNil: .skipped
            case .writerRefused, .generatorRefused: .refused
            case .writerUnavailable, .generatorUnavailable: .unavailable
            case .writerFailed, .generatorFailed: .failed
            }
        }

        var generator: StubImageGenerator {
            switch self {
            case .generatorUnavailable: StubImageGenerator(availability: .unavailable)
            case .generatorRefused: StubImageGenerator(outcome: .refused)
            case .generatorFailed: StubImageGenerator(outcome: .failed)
            default: StubImageGenerator()
            }
        }

        var writer: StubImagePromptWriter {
            switch self {
            case .writerNil: StubImagePromptWriter(result: .success(nil))
            case .writerRefused: StubImagePromptWriter(result: .failure(.refused))
            case .writerUnavailable: StubImagePromptWriter(availability: .unavailable)
            case .writerFailed: StubImagePromptWriter(result: .failure(.failed))
            default: StubImagePromptWriter(result: .success("a red apple"))
            }
        }

        /// The generator is never asked for a picture when the writer gave none.
        var reachesGenerator: Bool {
            switch self {
            case .generatorRefused, .generatorFailed: true
            default: false
            }
        }
    }

    @Test("each outcome leaves the matching status and no file", arguments: Outcome.allCases)
    func eachOutcomeLeavesTheMatchingStatusAndNoFile(_ outcome: Outcome) async throws {
        let fixture = try ImageQueueFixture(generator: outcome.generator, writer: outcome.writer)
        let word = try fixture.add("apple")
        let card = fixture.cardModel(word)
        await fixture.queue.drain()

        #expect(word.imageStatus == outcome.expected)
        #expect(try fixture.storedWord(word).imageStatus == outcome.expected)
        #expect(word.image == nil)
        #expect(try fixture.assetCount() == 0)
        #expect(fixture.directory.allFiles.isEmpty)
        #expect(card.failure == nil)
        #expect(fixture.generator.prompts.isEmpty == !outcome.reachesGenerator)
    }

    @Test("pending words resume on launch")
    func pendingWordsResumeOnLaunch() async throws {
        let first = try ImageQueueFixture()
        let word = try first.store.add("apple").word
        try first.store.setImageStatus(.pending, for: word)

        let queue = ImageGenerationQueue(
            store: first.store,
            imageStore: first.directory.store,
            generator: StubImageGenerator(),
            promptWriter: StubImagePromptWriter()
        )
        queue.isSceneActive = true
        try queue.resumePending()
        await queue.drain()
        #expect(word.image?.source == .generated)
        #expect(word.imageStatus == nil)
    }

    @Test("a photo chosen during generation is kept")
    func aPhotoChosenDuringGenerationIsKept() async throws {
        let fixture = try ImageQueueFixture(generator: StubImageGenerator(delay: .seconds(1)))
        let word = try fixture.add("apple")
        try await fixture.waitUntil { fixture.generator.prompts.count == 1 }

        let card = fixture.cardModel(word)
        #expect(try card.setImage(data: makePNG(width: 20, height: 20), source: .library))
        let photo = try #require(word.image?.fileName)
        await fixture.queue.drain()

        #expect(word.image?.source == .library)
        #expect(word.image?.fileName == photo)
        #expect(word.imageStatus == nil)
        #expect(fixture.directory.allFiles == [photo, ImageStore.thumbnailFileName(for: photo)])
    }

    @Test("a generated picture finished after the word changed is discarded")
    func aLatePictureIsDiscarded() async throws {
        let fixture = try ImageQueueFixture(generator: StubImageGenerator(delay: .milliseconds(300)))
        let word = try fixture.add("apple")
        try await fixture.waitUntil { fixture.generator.prompts.count == 1 }
        // A status change behind the queue's back, without cancelling the job: the result must not land.
        try fixture.store.setImageStatus(nil, for: word)
        await fixture.queue.drain()
        #expect(word.image == nil)
        #expect(fixture.directory.allFiles.isEmpty)
    }

    @Test("deleting a word drops its pending picture")
    func deletingAWordDropsItsPendingPicture() async throws {
        let fixture = try ImageQueueFixture(generator: StubImageGenerator(delay: .seconds(1)))
        let word = try fixture.add("apple")
        try await fixture.waitUntil { fixture.generator.prompts.count == 1 }

        #expect(fixture.cardModel(word).deleteWord())
        await fixture.queue.drain()
        #expect(word.image == nil)
        #expect(try fixture.assetCount() == 0)
        #expect(fixture.directory.allFiles.isEmpty)
        #expect(fixture.queue.runningWordID == nil)
    }
}
