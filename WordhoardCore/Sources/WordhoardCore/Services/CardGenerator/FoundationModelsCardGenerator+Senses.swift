import Foundation

/// The sense-inventory stages of `FoundationModelsCardGenerator` (ADR 0001 point 1, plan 2.6): the
/// WordNet path with the selection call, and the stoplist / model-only path with the verifier.
extension FoundationModelsCardGenerator {
    // MARK: - Step 3: WordNet path

    /// The senses (`selectSenses`), then one `writeDefinition` call per selected sense, serial. A
    /// refused or failed call keeps the gloss as the definition and leaves a note; a sense WordNet
    /// vouches for is never dropped (A6).
    func wordNetCard(headword: String, entry: WordNetEntry) async throws -> GeneratedCard {
        var senses: [GeneratedSense] = []
        var notes: [GenerationNote] = []
        let selected = try await selectSenses(headword: headword, entry: entry, notes: &notes)
        for (index, sense) in selected.enumerated() {
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

    /// Which WordNet senses the card gets (plan 2.6). Up to `maxSensesTotal` bundled senses → all of
    /// them, no call. More → one `selectSenses` call over the round-robin candidates, post-processed by
    /// `WordNetLookup.selection`; a refused or failed call, or an answer with no usable index, falls
    /// back to `entry.selected` (2 per part of speech) with `.senseSelectionFellBack`.
    private func selectSenses(
        headword: String,
        entry: WordNetEntry,
        notes: inout [GenerationNote]
    ) async throws -> [WordNetSense] {
        guard entry.senses.count > WordNetLookup.maxSensesTotal else {
            return entry.senses
        }
        try Task.checkCancellation()
        let candidates = entry.candidates
        do {
            let indices = try await calls.selectSenses(headword: headword, candidates: candidates)
            if let selected = WordNetLookup.selection(indices, from: candidates) {
                return selected
            }
            Self.logger.notice("sense selection answered no usable index; 2-per-part-of-speech fallback")
        } catch let error as ModelCallError {
            Self.logger.notice(
                "sense selection failed, 2-per-part-of-speech fallback: \(String(describing: error), privacy: .public)"
            )
        }
        notes.append(.senseSelectionFellBack)
        return entry.selected
    }

    // MARK: - Step 4: stoplist / model-only path

    /// One `proposeSenses` call, then one `verify` call per proposed sense, serial. "No" drops the
    /// sense; a verify call that throws keeps it; none kept → `.notFound` with no senses (A1).
    /// `wordClass` (stoplist words only) reaches both prompts as a hint (2.7).
    func modelOnlyCard(
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
}
