import Foundation
import os

/// The production `CardGenerator` (ADR 0001 points 1–3; requirements A1, A2, A6; no translations, Phase 7).
///
/// **Isolation: none.** A `Sendable` class of `let` collaborators; its methods are `nonisolated` and
/// run off the main actor. Senses come from `WordNetLookup` when the bundle knows the lemma (the model
/// picks ≤ 4 when it lists more, plan 2.6), otherwise from a verified model proposal; the model
/// (`ModelCalls`) writes prose only, one sense per call. The card carries no translation (owner's
/// decision, Phase 7). Per-field failures are `GenerationNote`s on a card that is still produced; only the
/// model-only senses call can fail the card. Every example is checked for the headword and retried
/// once (2.9). Example calls (neutral and topic) run up to `maxConcurrentExampleCalls` at a time, one
/// fresh session each (plan 2.8); every other call is serial. The stages live in sibling extension
/// files: `+Senses` (inventory) and `+Examples` (both example stages).
public final class FoundationModelsCardGenerator: CardGenerator {
    static let logger = Logger(subsystem: "Wordhoard", category: "autofill")

    // Internal, not private: the pipeline's stages live in extensions in sibling files.
    let calls: any ModelCalls
    let lookup: WordNetLookup
    /// The first sense source (Phase 7): learner definitions in frequency order.
    let wiktionary: WiktionaryLookup
    /// At least 1. Neutral examples of one card and the topic stream each keep this many calls in flight.
    let maxConcurrentExampleCalls: Int
    /// At least 1. Only the first this many senses get topic examples.
    let maxTopicExampleSenses: Int

    /// The example-call window the app uses (plan 2.8). A constant, not a setting; the device
    /// measurement (#43) decides whether it stays 3 or becomes 1.
    public static let defaultMaxConcurrentExampleCalls = 3

    /// How many senses, from the most common, get topic examples in the app. Every sense still gets its
    /// neutral example; the rarer ones need no grammar drill and would hold up the queue (Phase 7).
    public static let defaultMaxTopicExampleSenses = 3

    public init(
        calls: any ModelCalls = FoundationModelCalls(),
        lookup: WordNetLookup = .shared,
        wiktionary: WiktionaryLookup = .shared,
        maxConcurrentExampleCalls: Int = FoundationModelsCardGenerator.defaultMaxConcurrentExampleCalls,
        maxTopicExampleSenses: Int = FoundationModelsCardGenerator.defaultMaxTopicExampleSenses
    ) {
        self.calls = calls
        self.lookup = lookup
        self.wiktionary = wiktionary
        self.maxConcurrentExampleCalls = max(1, maxConcurrentExampleCalls)
        self.maxTopicExampleSenses = max(1, maxTopicExampleSenses)
    }

    public func availability() async -> CardGeneratorAvailability {
        await calls.availability()
    }

    public func generateCard(_ request: CardRequest) async throws -> GeneratedCard {
        try await checkAvailability()
        let headword = Self.trimmed(request.headword)

        // Sense inventory (step 2): Simple Wiktionary first (Phase 7: frequency order, learner
        // definitions); then stoplist → model with the section's class as a hint; WordNet; model.
        var card: GeneratedCard = if let senses = await wiktionary.senses(for: headword) {
            wiktionaryCard(headword: headword, senses: senses)
        } else if await lookup.isFunctionWord(headword) {
            try await modelOnlyCard(
                headword: headword, path: .stoplist, wordClass: lookup.functionWordClass(headword)
            )
        } else if let entry = await lookup.entry(for: headword) {
            try await wordNetCard(headword: headword, entry: entry)
        } else {
            try await modelOnlyCard(headword: headword, path: .modelOnly, wordClass: nil)
        }
        guard !card.senses.isEmpty else {
            Self.logger.info("\(headword, privacy: .private(mask: .hash)): not found, no sense invented")
            return card
        }

        try await writeNeutralExamples(&card)
        Self.logger.info(
            """
            card via \(card.path.rawValue, privacy: .public): \(card.senses.count, privacy: .public) senses, \
            \(card.notes.count, privacy: .public) notes
            """
        )
        return card
    }

    public func generateTopicExamples(
        for card: GeneratedCard,
        request: CardRequest
    ) -> AsyncThrowingStream<GeneratedTopicExample, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await checkAvailability()
                    try await streamTopicExamples(for: card, request: request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Step 1: availability

    func checkAvailability() async throws {
        if case let .unavailable(reason) = await calls.availability() {
            throw CardGeneratorError.unavailable(reason)
        }
    }

    static func trimmed(_ headword: String) -> String {
        headword.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
