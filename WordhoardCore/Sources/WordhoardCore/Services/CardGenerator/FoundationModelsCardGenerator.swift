import Foundation
import os

/// The production `CardGenerator` (ADR 0001 points 1–4; requirements A1, A2, A6, A9).
///
/// **Isolation: none.** A `Sendable` class of three `let` collaborators; its methods are
/// `nonisolated` and run off the main actor. Senses come from `WordNetLookup` when the bundle knows
/// the lemma, otherwise from a verified model proposal; the model (`ModelCalls`) writes prose only,
/// one sense per call; translations come from `Translator`, never from the model. Per-field failures
/// are `GenerationNote`s on a card that is still produced; only the model-only senses call can fail
/// the card. Every example is checked for the headword and retried once (2.9). Serial in 2.2 (plan
/// 2.8 raises the example concurrency).
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

        // Sense inventory (step 2): stoplist → model with the section's class as a hint; bundle miss →
        // model; otherwise WordNet only.
        var card: GeneratedCard = if await lookup.isFunctionWord(headword) {
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
    /// `wordClass` (stoplist words only) reaches both prompts as a hint (2.7).
    private func modelOnlyCard(
        headword: String,
        path: GenerationPath,
        wordClass: FunctionWordClass?
    ) async throws -> GeneratedCard {
        let proposed: [ProposedSense]
        do {
            proposed = try await calls.proposeSenses(headword: headword, wordClass: wordClass)
        } catch ModelCallError.refused {
            throw CardGeneratorError.refused
        } catch let ModelCallError.failed(description) {
            throw CardGeneratorError.failed(description)
        }

        var kept: [GeneratedSense] = []
        for sense in proposed where !sense.definition.isEmpty {
            try Task.checkCancellation()
            do {
                guard try await calls.verify(headword: headword, sense: sense, wordClass: wordClass) else {
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

    /// One example per sense, serial, through `requestExample`. Refused, failed or "does not fit" →
    /// no example and `.exampleRefused`; written twice without the headword → no example and
    /// `.exampleDropped`; the card is still returned (A6).
    private func writeNeutralExamples(_ card: inout GeneratedCard) async throws {
        for index in card.senses.indices {
            try Task.checkCancellation()
            switch try await requestExample(headword: card.headword, sense: card.senses[index], topic: nil) {
            case let .text(text):
                card.senses[index].neutralExample = GeneratedExample(text: text, grammarTopic: nil)
            case .doesNotFit:
                Self.logger.notice("neutral example \(index, privacy: .public) came back as not fitting")
                card.notes.append(.exampleRefused(senseIndex: index, topic: nil))
            case let .failed(error):
                Self.logger.notice(
                    "neutral example \(index, privacy: .public) skipped: \(String(describing: error), privacy: .public)"
                )
                card.notes.append(.exampleRefused(senseIndex: index, topic: nil))
            case .dropped:
                Self.logger.notice("neutral example \(index, privacy: .public) dropped: no headword after a retry")
                card.notes.append(.exampleDropped(senseIndex: index, topic: nil))
            }
        }
    }

    // MARK: - Stage 2: topic examples

    /// One slot through `requestExample`; the example carries the requested key, never anything the
    /// model said. Anything but a sentence → nil, logged (the card is finished, so there is no note to
    /// attach it to).
    private func topicExample(
        headword: String,
        senseIndex: Int,
        sense: GeneratedSense,
        topic: GrammarTopic
    ) async throws -> GeneratedTopicExample? {
        switch try await requestExample(headword: headword, sense: sense, topic: topic) {
        case let .text(text):
            return GeneratedTopicExample(
                senseIndex: senseIndex,
                example: GeneratedExample(text: text, grammarTopic: topic.key)
            )
        case .doesNotFit:
            return nil
        case let .failed(error):
            Self.logger.notice(
                """
                topic example \(senseIndex, privacy: .public)/\(topic.key, privacy: .public) skipped: \
                \(String(describing: error), privacy: .public)
                """
            )
            return nil
        case .dropped:
            Self.logger.notice(
                "topic example \(senseIndex, privacy: .public)/\(topic.key, privacy: .public) dropped: no headword"
            )
            return nil
        }
    }

    // MARK: - One example, checked

    /// One `writeExample` call. A sentence without the headword (`HeadwordMatcher`) is asked for once
    /// more with the "must contain the word" line; a second miss drops it. `.doesNotFit` is final on
    /// either call. Cancellation passes through.
    private func requestExample(
        headword: String,
        sense: GeneratedSense,
        topic: GrammarTopic?
    ) async throws -> ExampleOutcome {
        do {
            for mustContainHeadword in [false, true] {
                try Task.checkCancellation()
                let answer = try await calls.writeExample(
                    headword: headword,
                    partOfSpeech: sense.partOfSpeech,
                    definition: sense.definition,
                    topic: topic,
                    mustContainHeadword: mustContainHeadword
                )
                guard case let .text(text) = answer else { return .doesNotFit }
                if HeadwordMatcher.contains(headword: headword, in: text) {
                    return .text(text)
                }
                let slot = topic?.key ?? "neutral"
                Self.logger.debug("example \(slot, privacy: .public) lacks the headword; retry \(mustContainHeadword)")
            }
            return .dropped
        } catch let error as ModelCallError {
            return .failed(error)
        }
    }

    private static func trimmed(_ headword: String) -> String {
        headword.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How one example slot of `FoundationModelsCardGenerator` ended.
private enum ExampleOutcome {
    /// A sentence that contains the headword.
    case text(String)
    /// The model set `fits` to false; never retried.
    case doesNotFit
    /// Two sentences, neither with the headword (2.9).
    case dropped
    /// The call was refused or failed.
    case failed(ModelCallError)
}
