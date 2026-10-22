import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The card's picture actions (plan 4.3, #48) over an in-memory store and a temporary `ImageStore`.
@MainActor
@Suite("WordCardModel pictures")
struct WordCardModelImageTests {
    let container: ModelContainer
    let store: WordStore
    let directory = TemporaryImageDirectory()

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func makeModel(_ headword: String = "apple") throws -> WordCardModel {
        let word = try store.add(headword).word
        try store.transaction { _ in
            word.updatedAt = Date(timeIntervalSince1970: 1000)
        }
        return WordCardModel(word: word, store: store, imageStore: directory.store)
    }

    @Test("choosing a photo stores the file and a library asset")
    func choosingAPhotoStoresTheFileAndALibraryAsset() throws {
        let model = try makeModel()
        let before = model.word.updatedAt

        #expect(try model.setImage(data: makePNG(width: 400, height: 300), source: .library))
        let asset = try #require(model.word.image)
        #expect(asset.source == .library)
        #expect(asset.prompt == nil)
        #expect(asset.fileName == ImageStore.fileName(for: asset.id))
        #expect(directory.store.exists(asset.fileName))
        #expect(directory.allFiles.contains(ImageStore.thumbnailFileName(for: asset.fileName)))
        #expect(try model.imageURL == (directory.store.url(for: asset.fileName)))
        #expect(model.word.updatedAt > before)
        let stored = try #require(try storedWordOrNil(model.word.id, in: container))
        #expect(stored.image?.fileName == asset.fileName)
        #expect(model.failure == nil)
    }

    @Test("taking a photo stores a camera asset")
    func takingAPhotoStoresACameraAsset() throws {
        let model = try makeModel()
        #expect(try model.setImage(data: makePNG(width: 40, height: 30), source: .camera))
        #expect(model.word.image?.source == .camera)
    }

    @Test("replacing a picture removes the previous file")
    func replacingAPictureRemovesThePreviousFile() throws {
        let model = try makeModel()
        try model.setImage(data: makePNG(width: 40, height: 30), source: .library)
        let first = try #require(model.word.image?.fileName)
        try model.setImage(data: makePNG(width: 50, height: 30), source: .camera)
        let second = try #require(model.word.image?.fileName)

        #expect(first != second)
        #expect(!directory.store.exists(first))
        #expect(directory.allFiles == [second, ImageStore.thumbnailFileName(for: second)])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ImageAsset>()) == 1)
    }

    @Test("removing a picture deletes the file and the asset")
    func removingAPictureDeletesTheFileAndTheAsset() throws {
        let model = try makeModel()
        try model.setImage(data: makePNG(width: 40, height: 30), source: .library)
        let before = model.word.updatedAt

        model.removeImage()
        #expect(model.word.image == nil)
        #expect(directory.allFiles.isEmpty)
        #expect(model.imageURL == nil)
        #expect(model.word.updatedAt >= before)
        let removedAt = model.word.updatedAt

        model.removeImage()
        #expect(model.word.updatedAt == removedAt)
        #expect(model.failure == nil)
    }

    @Test("a broken photo leaves the card unchanged and reports it")
    func aBrokenPhotoLeavesTheCardUnchangedAndReportsIt() throws {
        let model = try makeModel()
        #expect(!model.setImage(data: Data("not a photo".utf8), source: .library))
        #expect(model.word.image == nil)
        #expect(directory.allFiles.isEmpty)
        #expect(model.failure == .savingImage)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ImageAsset>()) == 0)
    }

    @Test("deleting the word deletes its picture file")
    func deletingTheWordDeletesItsPictureFile() throws {
        let model = try makeModel()
        try model.setImage(data: makePNG(width: 40, height: 30), source: .library)
        #expect(model.deleteWord())
        #expect(directory.allFiles.isEmpty)
        #expect(try !model.setImage(data: makePNG(width: 40, height: 30), source: .library))
        #expect(directory.allFiles.isEmpty)
    }
}
