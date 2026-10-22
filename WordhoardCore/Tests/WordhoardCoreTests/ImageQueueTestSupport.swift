import Foundation
import SwiftData
import Testing
import WordhoardCore

/// An in-memory store, a temporary picture directory and a queue over the given stubs.
@MainActor
struct ImageQueueFixture {
    let container: ModelContainer
    let store: WordStore
    let directory = TemporaryImageDirectory()
    let generator: StubImageGenerator
    let writer: StubImagePromptWriter
    /// Every `generate` call waits here; open unless the fixture was made with `holdsGenerator`.
    let generatorGate: Gate
    let queue: ImageGenerationQueue

    init(
        generator: StubImageGenerator = StubImageGenerator(),
        writer: StubImagePromptWriter = StubImagePromptWriter(result: .success("a red apple")),
        holdsGenerator: Bool = false
    ) throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
        self.generator = generator
        self.writer = writer
        let gated = GatedImageGenerator(inner: generator)
        if !holdsGenerator {
            gated.gate.open()
        }
        generatorGate = gated.gate
        queue = ImageGenerationQueue(
            store: store,
            imageStore: directory.store,
            generator: gated,
            promptWriter: writer
        )
        queue.isSceneActive = true
    }

    func listModel() -> WordListModel {
        WordListModel(store: store, imageQueue: queue)
    }

    func cardModel(_ word: Word) -> WordCardModel {
        WordCardModel(word: word, store: store, imageStore: directory.store, imageQueue: queue)
    }

    /// Adds `headword` through the list model, as the add field does.
    @discardableResult
    func add(_ headword: String) throws -> Word {
        let model = listModel()
        model.draft = headword
        return try #require(model.addDraft()).word
    }

    func storedWord(_ word: Word) throws -> Word {
        try #require(try storedWordOrNil(word.id, in: container))
    }

    func assetCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<ImageAsset>())
    }
}

/// An `ImageGenerator` that holds every `generate` call at `gate` until the test opens it, then
/// delegates to `inner`, which records the prompt. A cancelled waiter throws `CancellationError`, as
/// the real call would. No sleeps: a test waits for a running job with `gate.untilWaiting(1)`.
final class GatedImageGenerator: ImageGenerator {
    let inner: StubImageGenerator
    let gate = Gate()

    init(inner: StubImageGenerator) {
        self.inner = inner
    }

    var availability: ImageGeneratorAvailability {
        get async { await inner.availability }
    }

    func generate(prompt: String) async throws -> ImageResult {
        try await gate.wait()
        return try await inner.generate(prompt: prompt)
    }
}
