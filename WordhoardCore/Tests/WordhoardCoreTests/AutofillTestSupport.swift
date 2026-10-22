import Foundation
import SwiftData
import Synchronization
import Testing
import WordhoardCore

/// A `CardGenerator` that is available but throws `error` from `generateCard`.
struct ThrowingCardGenerator: CardGenerator {
    let error: CardGeneratorError

    func availability() async -> CardGeneratorAvailability {
        .available
    }

    func generateCard(_ request: CardRequest) async throws -> GeneratedCard {
        throw error
    }

    func generateTopicExamples(
        for card: GeneratedCard,
        request: CardRequest
    ) -> AsyncThrowingStream<GeneratedTopicExample, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// A `CardGenerator` whose behaviour a test swaps mid-run, like a device that gains Apple Intelligence.
final class SwitchingCardGenerator: CardGenerator {
    private let state: Mutex<any CardGenerator>

    init(_ initial: any CardGenerator) {
        state = Mutex(initial)
    }

    var current: any CardGenerator {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func availability() async -> CardGeneratorAvailability {
        await current.availability()
    }

    func generateCard(_ request: CardRequest) async throws -> GeneratedCard {
        try await current.generateCard(request)
    }

    func generateTopicExamples(
        for card: GeneratedCard,
        request: CardRequest
    ) -> AsyncThrowingStream<GeneratedTopicExample, any Error> {
        current.generateTopicExamples(for: card, request: request)
    }
}

/// The `Word` with `id` through a fresh context, or `nil`.
@MainActor
func storedWordOrNil(_ id: UUID, in container: ModelContainer) throws -> Word? {
    try ModelContext(container).fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })).first
}

/// A word inserted directly with `state` and `createdAt`, saved through the store.
@MainActor
func insertWord(_ headword: String, state: AutofillState, createdAt: Date, into store: WordStore) throws -> Word {
    let word = try store.add(headword).word
    try store.transaction { _ in
        word.autofillState = state
        word.createdAt = createdAt
    }
    return word
}
