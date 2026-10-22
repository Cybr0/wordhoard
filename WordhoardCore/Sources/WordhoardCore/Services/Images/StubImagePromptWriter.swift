import Foundation
import Synchronization

/// A deterministic `ImagePromptWriter` for tests and the `--stub-images` debug hook: answers every call
/// with `result` after `delay` and records the calls. `.success(nil)` is the I5 "nothing to draw" path;
/// an unavailable stub throws `.unavailable` without recording.
public final class StubImagePromptWriter: ImagePromptWriter {
    /// One recorded call.
    public struct Call: Equatable, Sendable {
        public let headword: String
        public let definition: String?

        public init(headword: String, definition: String?) {
            self.headword = headword
            self.definition = definition
        }
    }

    private let configuredAvailability: ImageGeneratorAvailability
    private let respond: @Sendable (String) -> Result<String?, ImagePromptError>
    private let delay: Duration
    private let recorded = Mutex<[Call]>([])

    public convenience init(
        availability: ImageGeneratorAvailability = .available,
        result: Result<String?, ImagePromptError> = .success("A simple illustration."),
        delay: Duration = .zero
    ) {
        self.init(availability: availability, delay: delay) { _ in result }
    }

    /// `respond` receives the headword, so the debug hook can vary the prompt per word.
    public init(
        availability: ImageGeneratorAvailability = .available,
        delay: Duration = .zero,
        respond: @escaping @Sendable (String) -> Result<String?, ImagePromptError>
    ) {
        configuredAvailability = availability
        self.respond = respond
        self.delay = delay
    }

    public var calls: [Call] {
        recorded.withLock { $0 }
    }

    public var availability: ImageGeneratorAvailability {
        get async { configuredAvailability }
    }

    public func imagePrompt(headword: String, definition: String?) async throws -> String? {
        guard configuredAvailability == .available else {
            throw ImagePromptError.unavailable
        }
        recorded.withLock { $0.append(Call(headword: headword, definition: definition)) }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try respond(headword).get()
    }
}
