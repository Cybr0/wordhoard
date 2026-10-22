import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WordhoardCore

/// A fresh temporary directory for one test's `ImageStore`; removed when the value is deinitialised.
final class TemporaryImageDirectory {
    let url: URL
    let store: ImageStore

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "WordhoardImages-\(UUID().uuidString)")
        store = ImageStore(directory: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Every file name in the directory, thumbnails included.
    var allFiles: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? [])
    }
}

/// A `width` × `height` PNG in one colour.
func makePNG(width: Int, height: Int, alpha: Bool = false) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: info.rawValue
    ))
    context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: alpha ? 0.5 : 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// The pixel size of encoded image data.
func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    return (width, height)
}

/// Sets a file's modification date, so the orphan scan's age rule can be exercised.
func backdate(_ url: URL, by seconds: TimeInterval) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-seconds)],
        ofItemAtPath: url.path(percentEncoded: false)
    )
}
