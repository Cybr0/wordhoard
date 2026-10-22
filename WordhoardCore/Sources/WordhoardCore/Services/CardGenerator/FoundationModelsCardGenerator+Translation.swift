import Foundation

/// The translation stage of `FoundationModelsCardGenerator` (A9, plan 2.10, #22): the model proposes,
/// the Translation framework decides. Runs last, after the neutral examples, so the proposal prompt can
/// show the sense in use.
///
/// 1. No native language → nothing. Pack not `.installed` → no proposal call, every translation nil,
///    `.translationUnavailable`: nothing could be verified, and unverified model text is never shown.
/// 2. One `proposeTranslation` call per sense, serial: a 1–3-word equivalent.
/// 3. **One** back-translation batch (native → English) of every proposal. A proposal is accepted when
///    the English contains the headword or one of that sense's synonyms by lemma
///    (`HeadwordMatcher.containsLemma`).
/// 4. **One** second batch translates the definitions of every sense without an accepted proposal
///    (rejected, refused or failed) → `translationIsFallback = true`, `.translationFallback`.
///
/// At most two framework batches per word, never one per sense. A failed batch leaves the affected
/// translations nil with `.translationUnavailable`. Synonyms and antonyms are never translated.
extension FoundationModelsCardGenerator {
    func translate(_ card: inout GeneratedCard, into nativeLanguage: String?) async throws {
        guard let nativeLanguage else { return }
        try Task.checkCancellation()
        let english = Self.learningLanguage
        guard await translator.availability(from: english, to: nativeLanguage) == .installed else {
            card.notes.append(.translationUnavailable(language: nativeLanguage))
            Self.logger.notice("\(english, privacy: .public)→\(nativeLanguage, privacy: .public) pack not installed")
            return
        }

        let proposals = try await proposeTranslations(for: card, nativeLanguage: nativeLanguage)
        guard let accepted = try await confirmedProposals(proposals, of: card, nativeLanguage: nativeLanguage) else {
            card.notes.append(.translationUnavailable(language: nativeLanguage))
            return
        }
        let rejected = card.senses.indices.filter { accepted[$0] == nil }
        let fallbacks = try await translatedDefinitions(of: rejected, in: card, nativeLanguage: nativeLanguage)
        if fallbacks == nil {
            card.notes.append(.translationUnavailable(language: nativeLanguage))
        }

        for index in card.senses.indices {
            if let proposal = accepted[index] {
                card.senses[index].translation = proposal
                card.senses[index].translationIsFallback = false
            } else if let fallback = fallbacks?[card.senses[index].definition] {
                card.senses[index].translation = fallback
                card.senses[index].translationIsFallback = true
                card.notes.append(.translationFallback(senseIndex: index, rejectedProposal: proposals[index]))
            } else {
                card.senses[index].translation = nil
                card.senses[index].translationIsFallback = false
            }
        }
        Self.logger.info(
            "translations: \(accepted.count, privacy: .public) accepted, \(rejected.count, privacy: .public) fallback"
        )
    }

    /// The one back-translation batch: the proposals the English confirms, by sense index. `[:]`
    /// without proposals (no batch); `nil` when the batch failed. Cancellation passes through.
    private func confirmedProposals(
        _ proposals: [Int: String],
        of card: GeneratedCard,
        nativeLanguage: String
    ) async throws -> [Int: String]? {
        guard !proposals.isEmpty else { return [:] }
        let texts = Self.unique(card.senses.indices.compactMap { proposals[$0] })
        let back: [String: String]
        do {
            back = try await translator.translate(texts, from: nativeLanguage, to: Self.learningLanguage)
        } catch let error as TranslatorError {
            Self.logger.notice("back-translation batch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return proposals.filter { index, proposal in
            back[proposal].map { english in
                Self.confirms(english, headword: card.headword, synonyms: card.senses[index].synonyms)
            } ?? false
        }
    }

    /// The one second batch: the definitions of `indices` translated, keyed by definition. `[:]` for no
    /// index (no batch); `nil` when the batch failed.
    private func translatedDefinitions(
        of indices: [Int],
        in card: GeneratedCard,
        nativeLanguage: String
    ) async throws -> [String: String]? {
        guard !indices.isEmpty else { return [:] }
        do {
            return try await translator.translate(
                Self.unique(indices.map { card.senses[$0].definition }),
                from: Self.learningLanguage,
                to: nativeLanguage
            )
        } catch let error as TranslatorError {
            Self.logger.notice("definition batch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// One proposal per sense, serial; a refused or failed call, or a blank answer, is no proposal.
    private func proposeTranslations(
        for card: GeneratedCard,
        nativeLanguage: String
    ) async throws -> [Int: String] {
        var proposals: [Int: String] = [:]
        for (index, sense) in card.senses.enumerated() {
            try Task.checkCancellation()
            do {
                let proposal = try await calls.proposeTranslation(
                    headword: card.headword, sense: sense, nativeLanguage: nativeLanguage
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !proposal.isEmpty {
                    proposals[index] = proposal
                }
            } catch let error as ModelCallError {
                let reason = String(describing: error)
                Self.logger
                    .notice("translation proposal \(index, privacy: .public) failed: \(reason, privacy: .public)")
            }
        }
        return proposals
    }

    /// Whether the English back-translation names the headword or a synonym of the sense, by lemma.
    static func confirms(_ backTranslation: String, headword: String, synonyms: [String]) -> Bool {
        ([headword] + synonyms).contains { HeadwordMatcher.containsLemma(of: $0, in: backTranslation) }
    }

    /// `texts` without repeats, first occurrence kept.
    private static func unique(_ texts: [String]) -> [String] {
        var seen: Set<String> = []
        return texts.filter { seen.insert($0).inserted }
    }
}
