import Foundation
import os

/// The production `CardGenerator` (ADR 0001 points 1–4; requirements A1, A2, A6, A9).
///
/// **Isolation: none.** A `Sendable` class of three `let` collaborators; its methods are
/// `nonisolated` and run off the main actor. Senses come from `WordNetLookup` when the bundle knows
/// the lemma, otherwise from a verified model proposal; the model (`ModelCalls`) writes prose only,
/// one sense per call; translations come from `Translator`, never from the model. Per-field failures
/// are `GenerationNote`s on a card that is still produced; only the model-only senses call can fail
/// the card. Serial in 2.2 (plan 2.8 raises the example concurrency).
public final class FoundationModelsCardGenerator: CardGenerator {
    private static let logger = Logger(subsystem: "Wordhoard", category: "autofill")
    /// The learning language, the source of every translation (requirements §1: English only in v1).
    private static let learningLanguage = "en"

    private let calls: any ModelCalls
    private let lookup: WordNetLookup
    private let translator: any Translator

    public init(
        calls: any ModelCalls = FoundationModelCalls(),
        lookup: WordNetLookup = .shared,
        translator: any Translator = AppleTranslator()
    ) {
        self.calls = calls
        self.lookup = lookup
        self.translator = translator
    }

    public func availability() async -> CardGeneratorAvailability {
        await calls.availability()
    }

    public func generateCard(_ request: CardRequest) async throws -> GeneratedCard {
        try await checkAvailability()
        let headword = Self.trimmed(request.headword)

        // Sense inventory (step 2): stoplist → model; bundle miss → model; otherwise WordNet only.
        var card: GeneratedCard = if await lookup.isFunctionWord(headword) {
            try await modelOnlyCard(headword: headword, path: .stoplist)
        } else if let entry = await lookup.entry(for: headword) {
            try await wordNetCard(headword: headword, entry: entry)
        } else {
            try await modelOnlyCard(headword: headword, path: .modelOnly)
        }
        guard !card.senses.isEmpty else {
            Self.logger.info("\(headword, privacy: .private(mask: .hash)): not found, no sense invented")
            return card
        }

        try await translate(&card, into: request.nativeLanguage)
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
                    let headword = Self.trimmed(request.headword)
                    for (senseIndex, sense) in card.senses.enumerated() {
                        for topic in request.topics {
                            try Task.checkCancellation()
                            if let example = try await topicExample(
                                headword: headword, senseIndex: senseIndex, sense: sense, topic: topic
                            ) {
                                continuation.yield(example)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Step 1: availability

    private func checkAvailability() async throws {
        if case let .unavailable(reason) = await calls.availability() {
            throw CardGeneratorError.unavailable(reason)
        }
    }

    // MARK: - Step 3: WordNet path

    /// One `writeDefinition` call per selected sense, serial. A refused or failed call keeps the gloss
    /// as the definition and leaves a note; a sense WordNet vouches for is never dropped (A6).
    private func wordNetCard(headword: String, entry: WordNetEntry) async throws -> GeneratedCard {
        var senses: [GeneratedSense] = []
        var notes: [GenerationNote] = []
        for (index, sense) in entry.selected.enumerated() {
            try Task.checkCancellation()
            var definition = sense.gloss
            do {
                let written = try await calls.writeDefinition(headword: headword, sense: sense)
                if !written.isEmpty {
                    definition = written
                }
            } catch let error as ModelCallError {
                notes.append(.definitionRefused(senseIndex: index))
                Self.logger.notice(
                    """
                    definition \(index, privacy: .public) kept the gloss: \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
            senses.append(GeneratedSense(
                partOfSpeech: sense.partOfSpeech,
                senseSource: .wordnet,
                gloss: sense.gloss,
                definition: definition,
                translation: nil,
                synonyms: sense.synonyms,
                antonyms: sense.antonyms,
                neutralExample: nil
            ))
        }
        return GeneratedCard(headword: headword, path: .wordnet, senses: senses, notes: notes)
    }

    // MARK: - Step 4: stoplist / model-only path

    /// One `proposeSenses` call, then one `verify` call per proposed sense, serial. "No" drops the
    /// sense; a verify call that throws keeps it; none kept → `.notFound` with no senses (A1).
    private func modelOnlyCard(headword: String, path: GenerationPath) async throws -> GeneratedCard {
        let proposed: [ProposedSense]
        do {
            proposed = try await calls.proposeSenses(headword: headword)
        } catch ModelCallError.refused {
            throw CardGeneratorError.refused
        } catch let ModelCallError.failed(description) {
            throw CardGeneratorError.failed(description)
        }

        var kept: [GeneratedSense] = []
        for sense in proposed where !sense.definition.isEmpty {
            try Task.checkCancellation()
            do {
                guard try await calls.verify(headword: headword, sense: sense) else {
                    continue
                }
            } catch let error as ModelCallError {
                Self.logger.notice("verify failed, sense kept: \(String(describing: error), privacy: .public)")
            }
            kept.append(GeneratedSense(
                partOfSpeech: sense.partOfSpeech,
                senseSource: .model,
                gloss: nil,
                definition: sense.definition,
                translation: nil,
                synonyms: sense.synonyms,
                antonyms: sense.antonyms,
                neutralExample: nil
            ))
        }
        return GeneratedCard(headword: headword, path: kept.isEmpty ? .notFound : path, senses: kept)
    }

    // MARK: - Step 5: translation

    /// One batch per word with every sense's definition (plan 2.10 changes the shape). No native
    /// language → nothing. Pack missing or batch failed → every translation nil plus one note.
    private func translate(_ card: inout GeneratedCard, into nativeLanguage: String?) async throws {
        guard let nativeLanguage else { return }
        try Task.checkCancellation()
        let source = Self.learningLanguage
        guard await translator.availability(from: source, to: nativeLanguage) == .installed else {
            card.notes.append(.translationUnavailable(language: nativeLanguage))
            Self.logger.notice("\(source, privacy: .public)→\(nativeLanguage, privacy: .public) pack not installed")
            return
        }
        do {
            let translations = try await translator.translate(
                card.senses.map(\.definition), from: source, to: nativeLanguage
            )
            for index in card.senses.indices {
                card.senses[index].translation = translations[card.senses[index].definition]
            }
        } catch let error as TranslatorError {
            card.notes.append(.translationUnavailable(language: nativeLanguage))
            Self.logger.notice("translation batch failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Step 6: neutral examples

    /// One `writeExample(topic: nil)` call per sense, serial. Refused, failed or "does not fit" →
    /// no example and a note; the card is still returned (A6).
    private func writeNeutralExamples(_ card: inout GeneratedCard) async throws {
        for index in card.senses.indices {
            try Task.checkCancellation()
            let sense = card.senses[index]
            do {
                let answer = try await calls.writeExample(
                    headword: card.headword,
                    partOfSpeech: sense.partOfSpeech,
                    definition: sense.definition,
                    topic: nil
                )
                if case let .text(text) = answer {
                    card.senses[index].neutralExample = GeneratedExample(text: text, grammarTopic: nil)
                    continue
                }
                Self.logger.notice("neutral example \(index, privacy: .public) came back empty")
            } catch let error as ModelCallError {
                Self.logger.notice(
                    "neutral example \(index, privacy: .public) skipped: \(String(describing: error), privacy: .public)"
                )
            }
            card.notes.append(.exampleRefused(senseIndex: index, topic: nil))
        }
    }

    // MARK: - Stage 2: topic examples

    /// One call; the example carries the requested key, never anything the model said. Refused or
    /// failed → nil, logged (the card is finished, so there is no note to attach it to).
    private func topicExample(
        headword: String,
        senseIndex: Int,
        sense: GeneratedSense,
        topic: GrammarTopic
    ) async throws -> GeneratedTopicExample? {
        do {
            let answer = try await calls.writeExample(
                headword: headword, partOfSpeech: sense.partOfSpeech, definition: sense.definition, topic: topic
            )
            guard case let .text(text) = answer else { return nil }
            return GeneratedTopicExample(
                senseIndex: senseIndex,
                example: GeneratedExample(text: text, grammarTopic: topic.key)
            )
        } catch let error as ModelCallError {
            Self.logger.notice(
                """
                topic example \(senseIndex, privacy: .public)/\(topic.key, privacy: .public) skipped: \
                \(String(describing: error), privacy: .public)
                """
            )
            return nil
        }
    }

    private static func trimmed(_ headword: String) -> String {
        headword.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
