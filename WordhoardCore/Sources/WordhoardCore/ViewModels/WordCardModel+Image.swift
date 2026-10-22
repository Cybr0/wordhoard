import Foundation

// MARK: - Picture (plan 4.3, #48)

/// The picture slot's actions. Order everywhere: write the file → save the row → delete the replaced
/// file. A failed write or save leaves the card as it was and publishes `.savingImage`; a failed delete
/// of an old file is only logged, because the next launch's orphan scan collects it.
public extension WordCardModel {
    /// The full picture's file, or `nil` when the word has none.
    var imageURL: URL? {
        guard let fileName = word.image?.fileName else {
            return nil
        }
        return try? imageStore?.url(for: fileName)
    }

    /// The thumbnail's file (regenerated when missing), or `nil` when the word has no picture.
    var thumbnailURL: URL? {
        guard let fileName = word.image?.fileName else {
            return nil
        }
        return try? imageStore?.thumbnailURL(for: fileName)
    }

    /// Sets a picture the user chose: `.library` from the photo picker, `.camera` from the camera; no
    /// prompt. Returns whether it was stored; on `false`, `failure == .savingImage` and nothing changed.
    @discardableResult
    func setImage(data: Data, source: ImageSource) -> Bool {
        guard !isWordDeleted, let imageStore else {
            return false
        }
        // The user's picture wins over a generation in flight (4.4).
        imageQueue?.cancel(word.id)
        // Named after the row it belongs to: `<ImageAsset.id>.jpg`.
        let asset = ImageAsset(fileName: "", source: source)
        let fileName: String
        do {
            fileName = try imageStore.write(data, id: asset.id)
            asset.fileName = fileName
        } catch {
            logger.error("Could not write the picture: \(error.localizedDescription, privacy: .public)")
            failure = .savingImage
            return false
        }
        do {
            if let previous = try store.setImage(asset, for: word) {
                deleteImageFile(previous)
            }
            return true
        } catch {
            logger.error("Could not save the picture: \(error.localizedDescription, privacy: .public)")
            deleteImageFile(fileName)
            failure = .savingImage
            return false
        }
    }

    /// Removes the picture and its file, cancels a pending generation and clears the picture status. A
    /// second call, or a word with neither, does nothing.
    func removeImage() {
        guard !isWordDeleted else {
            return
        }
        imageQueue?.cancel(word.id)
        do {
            if let fileName = try store.removeImage(from: word) {
                deleteImageFile(fileName)
            }
        } catch {
            logger.error("Could not remove the picture: \(error.localizedDescription, privacy: .public)")
            failure = .saving
        }
    }

    /// "Generate picture": queues a job that ignores the toggle and replaces any picture (4.4). A queue
    /// error is logged; the card stays as it is.
    func generateImage() {
        guard !isWordDeleted else {
            return
        }
        do {
            try imageQueue?.enqueue(word, force: true)
        } catch {
            logger.error("Could not queue a picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    internal func deleteImageFile(_ fileName: String) {
        do {
            try imageStore?.delete(fileName)
        } catch {
            logger.notice("Could not delete \(fileName, privacy: .public); the orphan scan will")
        }
    }
}
