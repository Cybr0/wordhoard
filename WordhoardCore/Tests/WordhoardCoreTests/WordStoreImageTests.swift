import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `WordStore` picture rows (plan 4.1, #46): one asset row per word, the replaced name handed back.
@MainActor
@Suite("WordStore images")
struct WordStoreImageTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func assetCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<ImageAsset>())
    }

    private func backdated(_ word: Word) throws -> Date {
        let past = Date(timeIntervalSince1970: 1000)
        try store.transaction { _ in
            word.updatedAt = past
        }
        return past
    }

    @Test("setting, replacing and removing a picture keeps one asset row")
    func settingReplacingAndRemovingAnImageKeepsOneAssetRow() throws {
        let word = try store.add("apple").word
        var past = try backdated(word)

        let first = ImageAsset(fileName: "first.jpg", source: .library)
        #expect(try store.setImage(first, for: word) == nil)
        #expect(word.image === first)
        #expect(word.updatedAt > past)
        let stored = try #require(try storedWordOrNil(word.id, in: container))
        #expect(stored.image?.fileName == "first.jpg")
        #expect(stored.image?.source == .library)

        let second = ImageAsset(fileName: "second.jpg", source: .camera)
        #expect(try store.setImage(second, for: word) == "first.jpg")
        #expect(try assetCount() == 1)

        #expect(try store.removeImage(from: word) == "second.jpg")
        #expect(word.image == nil)
        #expect(try assetCount() == 0)

        past = try backdated(word)
        #expect(try store.removeImage(from: word) == nil)
        #expect(word.updatedAt == past)
    }

    @Test("an image asset's source and prompt persist")
    func imageAssetSourceAndPromptPersist() throws {
        let apple = try store.add("apple").word
        let book = try store.add("book").word
        try store.setImage(ImageAsset(fileName: "a.jpg", source: .camera), for: apple)
        try store.setImage(ImageAsset(fileName: "b.jpg", source: .generated, prompt: "a red book"), for: book)

        let storedApple = try #require(try storedWordOrNil(apple.id, in: container))
        let storedBook = try #require(try storedWordOrNil(book.id, in: container))
        #expect(storedApple.image?.source == .camera)
        #expect(storedApple.image?.prompt == nil)
        #expect(storedBook.image?.source == .generated)
        #expect(storedBook.image?.prompt == "a red book")
    }

    @Test("soft-deleting a word drops its image asset and returns the file name")
    func softDeletingAWordDropsItsImageAsset() throws {
        let word = try store.add("apple").word
        try store.setImage(ImageAsset(fileName: "apple.jpg", source: .library), for: word)

        #expect(try store.delete(word) == "apple.jpg")
        #expect(word.deletedAt != nil)
        #expect(try assetCount() == 0)
        #expect(try store.word(id: word.id) != nil)
        #expect(try store.delete(word) == nil)
    }

    @Test("image file names cover every asset row")
    func imageFileNamesCoversEveryAssetRow() throws {
        let apple = try store.add("apple").word
        let pear = try store.add("pear").word
        try store.setImage(ImageAsset(fileName: "apple.jpg", source: .library), for: apple)
        try store.delete(pear)
        try store.transaction { context in
            let asset = ImageAsset(fileName: "pear.jpg", source: .generated)
            context.insert(asset)
            pear.image = asset
        }
        #expect(try store.imageFileNames() == ["apple.jpg", "pear.jpg"])
    }
}
