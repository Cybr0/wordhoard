import Foundation
import SwiftData

/// Picture rows (plans 4.1, 4.4). A word has at most one `ImageAsset` row: setting or removing a picture
/// hard-deletes the previous row in the same save and returns its file name, which the caller deletes
/// **after** the save succeeded (write file → save row → delete the replaced file).
public extension WordStore {
    /// Attaches `asset` to `word`, hard-deletes the previous asset row, bumps
    /// `updatedAt`, saves. On a save error the context is rolled back and the error rethrown.
    /// - Returns: the replaced picture's file name, or `nil` when there was none.
    @discardableResult
    func setImage(_ asset: ImageAsset, for word: Word) throws -> String? {
        try transaction { context in
            let previous = word.image
            context.insert(asset)
            word.image = asset
            word.updatedAt = .now
            if let previous, previous !== asset {
                context.delete(previous)
                return previous.fileName
            }
            return nil
        }
    }

    /// Detaches and hard-deletes `word`'s asset row, bumps `updatedAt`, saves.
    /// - Returns: the removed picture's file name; `nil`, with nothing saved, when there was none.
    @discardableResult
    func removeImage(from word: Word) throws -> String? {
        guard let asset = word.image else {
            return nil
        }
        return try transaction { context in
            let fileName = asset.fileName
            word.image = nil
            context.delete(asset)
            word.updatedAt = .now
            return fileName
        }
    }

    /// Every `ImageAsset.fileName` in the store, soft-deleted words included: the orphan scan's
    /// reference set.
    func imageFileNames() throws -> Set<String> {
        try Set(context.fetch(FetchDescriptor<ImageAsset>()).map(\.fileName))
    }
}
