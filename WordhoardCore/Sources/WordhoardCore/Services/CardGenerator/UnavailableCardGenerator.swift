import Foundation

/// A generator that is never available: the device has no Apple Intelligence, or the app was launched
/// with `--generator unavailable` (2.3). Never calls anything; every screen must still work (CLAUDE.md).
public struct UnavailableCardGenerator: CardGenerator {
    public let reason: CardGeneratorAvailability.UnavailableReason

    public init(reason: CardGeneratorAvailability.UnavailableReason = .appleIntelligenceNotEnabled) {
        self.reason = reason
    }

    public func availability() async -> CardGeneratorAvailability {
        .unavailable(reason)
    }

    public func generateCard(_ request: CardRequest) async throws -> GeneratedCard {
        throw CardGeneratorError.unavailable(reason)
    }

    public func generateTopicExamples(
        for card: GeneratedCard,
        request: CardRequest
    ) -> AsyncThrowingStream<GeneratedTopicExample, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CardGeneratorError.unavailable(reason))
        }
    }
}
