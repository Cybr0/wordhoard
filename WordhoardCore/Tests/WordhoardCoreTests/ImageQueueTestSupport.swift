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
    let queue: ImageGenerationQueue

    init(
        generator: StubImageGenerator = StubImageGenerator(),
        writer: StubImagePromptWriter = StubImagePromptWriter(result: .success("a red apple"))
    ) throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
        self.generator = generator
        self.writer = writer
        queue = ImageGenerationQueue(
            store: store,
            imageStore: directory.store,
            generator: generator,
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

    /// Polls until `condition` holds or about two seconds pass.
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
