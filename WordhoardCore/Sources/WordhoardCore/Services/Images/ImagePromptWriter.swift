import Foundation

/// Why no picture prompt was written. Cancellation is `CancellationError`, not one of these.
public enum ImagePromptError: Error, Equatable, Sendable {
    case unavailable
    case refused
    case failed
}

/// Writes the short visual description a picture is made from (I1), or says there is nothing to draw
/// (I5). Production: `FoundationModelsImagePromptWriter`; tests and `--stub-images`: `StubImagePromptWriter`.
public protocol ImagePromptWriter: Sendable {
    /// Checked before any model session is created.
    var availability: ImageGeneratorAvailability { get async }
    /// `nil` = "no suitable image" (I5). `definition` is the first sense's definition when the card has
    /// one. Throws `ImagePromptError`, or `CancellationError`.
    func imagePrompt(headword: String, definition: String?) async throws -> String?
}
