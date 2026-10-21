import Foundation
import SwiftData

/// A picture for a `Word`. The image is a file in the app container referenced by name (I6); no
/// `Data` blobs. File handling is plan task 4.1.
@Model
public final class ImageAsset {
    public var id: UUID = UUID()
    public var fileName: String = ""
    public var source: ImageSource = ImageSource.library
    /// The prompt the image was generated from, if `source == .generated`.
    public var prompt: String?
    public var word: Word?

    public init(fileName: String, source: ImageSource, prompt: String? = nil) {
        self.fileName = fileName
        self.source = source
        self.prompt = prompt
    }
}
