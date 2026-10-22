import Foundation

/// Whether pictures (or picture prompts) can be made right now (I4, §6 Availability fallback).
public enum ImageGeneratorAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// Why no picture was made. Cancellation is `CancellationError`, not one of these.
public enum ImageGeneratorError: Error, Equatable, Sendable {
    /// Image Playground cannot run here (device, region, Apple Intelligence off).
    case unavailable
    /// The prompt or the result was refused.
    case refused
    /// Anything else, including creation refused because the app was in the background.
    case failed
}

/// One generated picture.
public struct ImageResult: Equatable, Sendable {
    /// PNG-encoded; `ImageStore` makes the JPEG.
    public let data: Data
    /// The style it was made in, e.g. `"illustration"`; `nil` from stubs.
    public let style: String?

    public init(data: Data, style: String?) {
        self.data = data
        self.style = style
    }
}

/// Makes a picture from a short visual description (I1). Production: `ImagePlaygroundGenerator`;
/// tests and the `--stub-images` hook: `StubImageGenerator`.
public protocol ImageGenerator: Sendable {
    /// Checked before every generation; not cached, because it changes when Apple Intelligence does.
    var availability: ImageGeneratorAvailability { get async }
    /// Throws `ImageGeneratorError`, or `CancellationError` when cancelled.
    func generate(prompt: String) async throws -> ImageResult
}
