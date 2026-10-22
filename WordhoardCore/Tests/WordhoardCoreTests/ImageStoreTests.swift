import Foundation
import Testing
import WordhoardCore

/// `ImageStore` (plan 4.1, #46): JPEG files named by id, downsized, with a derived thumbnail.
@Suite("ImageStore")
struct ImageStoreTests {
    let directory = TemporaryImageDirectory()

    var images: ImageStore {
        directory.store
    }

    @Test("writing an image stores a JPEG named by its id")
    func writingAnImageStoresAJpegNamedByItsID() throws {
        let id = UUID()
        let name = try images.write(makePNG(width: 300, height: 200), id: id)
        #expect(name == "\(id.uuidString).jpg")
        #expect(images.exists(name))
        let size = try pixelSize(of: images.imageData(for: name))
        #expect(size.width == 300 && size.height == 200)
        let url = try images.url(for: name)
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.url.standardizedFileURL)
        #expect(try images.imageData(for: name).starts(with: [0xFF, 0xD8]), "JPEG magic")
    }

    @Test("large images are downsized to the long-side limit")
    func largeImagesAreDownsizedToTheLongSideLimit() throws {
        let name = try images.write(makePNG(width: 3000, height: 2000), id: UUID())
        let size = try pixelSize(of: images.imageData(for: name))
        #expect(size.width == 1024)
        #expect(size.height == 683)
    }

    @Test("small images are not upscaled")
    func smallImagesAreNotUpscaled() throws {
        let name = try images.write(makePNG(width: 300, height: 300), id: UUID())
        let size = try pixelSize(of: images.imageData(for: name))
        #expect(size.width == 300 && size.height == 300)
    }

    @Test("a transparent PNG is accepted and stored opaque")
    func transparentImagesAreFlattened() throws {
        let name = try images.write(makePNG(width: 64, height: 64, alpha: true), id: UUID())
        #expect(images.exists(name))
    }

    @Test("the thumbnail is written and regenerated when missing")
    func thumbnailIsWrittenAndRegeneratedWhenMissing() throws {
        let name = try images.write(makePNG(width: 2000, height: 1000), id: UUID())
        let thumbnail = try images.thumbnailURL(for: name)
        #expect(FileManager.default.fileExists(atPath: thumbnail.path(percentEncoded: false)))
        #expect(try pixelSize(of: Data(contentsOf: thumbnail)).width == 256)

        try FileManager.default.removeItem(at: thumbnail)
        let regenerated = try images.thumbnailData(for: name)
        #expect(try pixelSize(of: regenerated).width == 256)
        #expect(FileManager.default.fileExists(atPath: thumbnail.path(percentEncoded: false)))
    }

    @Test("writing the same id replaces the files")
    func writingTheSameIDReplacesTheFiles() throws {
        let id = UUID()
        try images.write(makePNG(width: 100, height: 100), id: id)
        let name = try images.write(makePNG(width: 50, height: 40), id: id)
        #expect(directory.allFiles == [name, ImageStore.thumbnailFileName(for: name)])
        #expect(try pixelSize(of: images.imageData(for: name)).width == 50)
    }

    @Test("garbage data is rejected without writing anything")
    func garbageDataIsRejectedWithoutWritingAnything() throws {
        #expect(throws: ImageStoreError.undecodableImage) {
            try images.write(Data("not an image".utf8), id: UUID())
        }
        #expect(throws: ImageStoreError.undecodableImage) {
            try images.write(Data(), id: UUID())
        }
        #expect(directory.allFiles.isEmpty)
    }

    @Test("deleting removes both files and is idempotent")
    func deletingRemovesBothFilesAndIsIdempotent() throws {
        let name = try images.write(makePNG(width: 10, height: 10), id: UUID())
        try images.delete(name)
        try images.delete(name)
        #expect(try images.fileNames().isEmpty)
        #expect(directory.allFiles.isEmpty)
    }

    @Test("path-like file names are rejected")
    func pathLikeFileNamesAreRejected() throws {
        #expect(!ImageStore.fileName(for: UUID()).contains("/"))
        for name in ["../x.jpg", "a/b.jpg", "", "a\\b.jpg", ".."] {
            #expect(throws: ImageStoreError.invalidFileName) {
                try images.url(for: name)
            }
            #expect(throws: ImageStoreError.invalidFileName) {
                try images.delete(name)
            }
            #expect(!images.exists(name))
        }
        try images.write(makePNG(width: 10, height: 10), id: UUID())
        let isDirectory = directory.allFiles.contains { name in
            var flag: ObjCBool = false
            FileManager.default.fileExists(
                atPath: directory.url.appending(path: name).path(percentEncoded: false),
                isDirectory: &flag
            )
            return flag.boolValue
        }
        #expect(!isDirectory)
    }

    @Test("the orphan scan removes unreferenced files and stray thumbnails")
    func orphanScanRemovesUnreferencedFilesAndStrayThumbnails() throws {
        let first = try images.write(makePNG(width: 10, height: 10), id: UUID())
        try images.write(makePNG(width: 10, height: 10), id: UUID())
        try images.write(makePNG(width: 10, height: 10), id: UUID())
        let stray = directory.url.appending(path: "x-thumb.jpg")
        try Data([0]).write(to: stray)

        let removed = try images.removeOrphans(keeping: [first], olderThan: 0)
        #expect(removed == 2)
        #expect(directory.allFiles == [first, ImageStore.thumbnailFileName(for: first)])
    }

    @Test("the orphan scan keeps fresh files")
    func orphanScanKeepsFreshFiles() throws {
        let fresh = try images.write(makePNG(width: 10, height: 10), id: UUID())
        let old = try images.write(makePNG(width: 10, height: 10), id: UUID())
        try backdate(images.url(for: old), by: 7200)
        try backdate(images.thumbnailURL(for: old), by: 7200)

        let removed = try images.removeOrphans(keeping: [], olderThan: 3600)
        #expect(removed == 1)
        #expect(directory.allFiles == [fresh, ImageStore.thumbnailFileName(for: fresh)])
    }

    @Test("the orphan scan on a missing directory removes nothing")
    func orphanScanOnAMissingDirectory() throws {
        #expect(try images.removeOrphans(keeping: [], olderThan: 0) == 0)
        #expect(try images.fileNames().isEmpty)
    }
}
