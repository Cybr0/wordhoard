import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

public enum ImageStoreError: Error, Equatable, Sendable {
    /// The name is empty or contains `/`, `\` or `..`; only bare names inside the directory are allowed.
    case invalidFileName
    /// ImageIO could not decode the data; nothing was written.
    case undecodableImage
    /// The decoded image could not be encoded as JPEG; nothing was written.
    case encodingFailed
}

/// Word pictures as files (I6, plan 4.1, #46): `<ImageAsset.id>.jpg` and a derived `<id>-thumb.jpg` in
/// one directory, `Application Support/Images/` in the app. Names are relative and validated on every
/// call; `ImageAsset.fileName` stores only the full image's name.
///
/// `write` decodes anything ImageIO reads (PNG, JPEG, HEIC), applies the EXIF orientation, flattens
/// transparency onto white, keeps the long side ≤ 1024 px (never upscaling) and writes JPEG at quality
/// 0.85 plus a 256 px thumbnail: one lossy pass.
///
/// **Isolation: none.** A `Sendable` value with synchronous methods; callers that care (the 4.4 queue)
/// run them off the main actor. The order everywhere is write file → save row → delete the replaced
/// file, so a crash leaves at worst an orphan, which `removeOrphans` collects at the next launch.
public struct ImageStore: Sendable {
    public static let maxPixelSize = 1024
    public static let thumbnailPixelSize = 256
    public static let jpegQuality = 0.85

    public let directory: URL

    private static let logger = Logger(subsystem: "Wordhoard", category: "images")
    private static let thumbnailSuffix = "-thumb.jpg"

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Images/`, created when missing.
    public static func defaultDirectory() throws -> URL {
        let directory = URL.applicationSupportDirectory.appending(path: "Images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `"<uuid>.jpg"`.
    public static func fileName(for id: UUID) -> String {
        "\(id.uuidString).jpg"
    }

    /// `"<uuid>-thumb.jpg"` for `"<uuid>.jpg"`; derived, never stored.
    public static func thumbnailFileName(for fileName: String) -> String {
        let base = fileName.hasSuffix(".jpg") ? String(fileName.dropLast(4)) : fileName
        return base + thumbnailSuffix
    }

    // MARK: - Writing

    /// Writes the picture for `id` and its thumbnail, replacing any earlier files for the same id.
    /// - Returns: the full image's file name.
    /// - Throws: `.undecodableImage` or `.encodingFailed` with nothing written; file-system errors.
    @discardableResult
    public func write(_ data: Data, id: UUID) throws -> String {
        let fileName = Self.fileName(for: id)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = Self.downsized(source, maxPixelSize: Self.maxPixelSize)
        else {
            throw ImageStoreError.undecodableImage
        }
        let full = try Self.jpeg(image)
        let thumbnail = try Self.thumbnailData(fromJPEG: full)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try full.write(to: url(for: fileName), options: .atomic)
        try thumbnail.write(to: url(for: Self.thumbnailFileName(for: fileName)), options: .atomic)
        return fileName
    }

    // MARK: - Reading

    public func url(for fileName: String) throws -> URL {
        try Self.validate(fileName)
        return directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The thumbnail's URL, regenerating the file from the full image when it is missing.
    public func thumbnailURL(for fileName: String) throws -> URL {
        let thumbnail = try url(for: Self.thumbnailFileName(for: fileName))
        if !FileManager.default.fileExists(atPath: thumbnail.path(percentEncoded: false)) {
            let full = try Data(contentsOf: url(for: fileName))
            try Self.thumbnailData(fromJPEG: full).write(to: thumbnail, options: .atomic)
        }
        return thumbnail
    }

    public func imageData(for fileName: String) throws -> Data {
        try Data(contentsOf: url(for: fileName))
    }

    public func thumbnailData(for fileName: String) throws -> Data {
        try Data(contentsOf: thumbnailURL(for: fileName))
    }

    /// Whether the full image exists; `false` for an invalid name.
    public func exists(_ fileName: String) -> Bool {
        guard let url = try? url(for: fileName) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - Deleting

    /// Deletes the full image and its thumbnail. A missing file is not an error.
    public func delete(_ fileName: String) throws {
        try removeIfPresent(url(for: fileName))
        try removeIfPresent(url(for: Self.thumbnailFileName(for: fileName)))
    }

    /// The full images in the directory (thumbnails excluded); empty when the directory does not exist.
    public func fileNames() throws -> Set<String> {
        try Set(allFileNames().filter(Self.isFullImage))
    }

    /// Deletes every full image not in `referenced` and every thumbnail whose full image is gone,
    /// skipping files modified less than `age` seconds ago (a write whose row is not saved yet).
    /// - Returns: the number of full images removed.
    @discardableResult
    public func removeOrphans(keeping referenced: Set<String>, olderThan age: TimeInterval = 60) throws -> Int {
        let names = try allFileNames()
        let cutoff = Date.now.addingTimeInterval(-age)
        var removed = 0
        for name in names where Self.isFullImage(name) && !referenced.contains(name) {
            if try isOlder(name, than: cutoff) {
                try removeIfPresent(url(for: name))
                removed += 1
            }
        }
        for name in names where name.hasSuffix(Self.thumbnailSuffix) {
            let full = String(name.dropLast(Self.thumbnailSuffix.count)) + ".jpg"
            if !exists(full), try isOlder(name, than: cutoff) {
                try removeIfPresent(url(for: name))
            }
        }
        Self.logger.info("Orphan scan removed \(removed, privacy: .public) picture(s)")
        return removed
    }

    // MARK: - Helpers

    private static func validate(_ fileName: String) throws {
        if fileName.isEmpty || fileName.contains("/") || fileName.contains("\\") || fileName.contains("..") {
            throw ImageStoreError.invalidFileName
        }
    }

    private static func isFullImage(_ name: String) -> Bool {
        name.hasSuffix(".jpg") && !name.hasSuffix(thumbnailSuffix)
    }

    private func allFileNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    }

    private func isOlder(_ name: String, than cutoff: Date) throws -> Bool {
        let values = try url(for: name).resourceValues(forKeys: [.contentModificationDateKey])
        return (values.contentModificationDate ?? .distantPast) < cutoff
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// The upright image with its long side at most `maxPixelSize`, flattened onto white.
    private static func downsized(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? maxPixelSize
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? maxPixelSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return flattened(image)
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageStoreError.encodingFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageStoreError.encodingFailed
        }
        return data as Data
    }

    private static func thumbnailData(fromJPEG data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsized(source, maxPixelSize: thumbnailPixelSize)
        else {
            throw ImageStoreError.undecodableImage
        }
        return try jpeg(image)
    }
}
