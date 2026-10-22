import Foundation

/// The translation stage of `FoundationModelsCardGenerator` (A9, plan 2.10, #22): the model proposes,
/// the Translation framework decides. Runs last, after the neutral examples, so the proposal prompt can
/// show the sense in use.
///
/// 1. No native language → nothing. Pack not `.installed` → no proposal call, every translation nil,
///    `.translationUnavailable`: nothing could be verified, and unverified model text is never shown.
/// 2. One `proposeTranslation` call per sense, serial: a 1–3-word equivalent.
/// 3. **One** back-translation batch (native → English) of every proposal. A proposal is accepted when
///    it is written in one script and the English contains the headword or one of that sense's
///    synonyms by lemma (`HeadwordMatcher.containsLemma`).
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
            guard Self.isSingleScript(proposal) else { return false }
            return back[proposal].map { english in
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

    /// Whether every letter of `text` belongs to one writing system. The host model was seen writing
    /// "заबुक" and "один 점" for Russian, and the framework back-translated the first to *book*; a
    /// mixed-script proposal is never a dictionary equivalent, so it is rejected before the lemma check.
    /// Coarse blocks: Latin, Greek, Cyrillic, Armenian, Hebrew, Arabic, Devanagari, Thai, Georgian,
    /// Hangul, and Han with kana as one (Japanese mixes them); any other letter by its 128-code block.
    public static func isSingleScript(_ text: String) -> Bool {
        var scripts: Set<Int> = []
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            scripts.insert(scriptBlock(scalar.value))
        }
        return scripts.count <= 1
    }

    private static func scriptBlock(_ value: UInt32) -> Int {
        scriptRanges.first { $0.range.contains(value) }?.script ?? 100 + Int(value >> 7)
    }

    /// Letter ranges → coarse script id; Han and kana share one.
    private static let scriptRanges: [(range: ClosedRange<UInt32>, script: Int)] = [
        (0x0041 ... 0x024F, 1), (0x1E00 ... 0x1EFF, 1), // Latin
        (0x0370 ... 0x03FF, 2), (0x1F00 ... 0x1FFF, 2), // Greek
        (0x0400 ... 0x052F, 3), (0x2DE0 ... 0x2DFF, 3), (0xA640 ... 0xA69F, 3), // Cyrillic
        (0x0530 ... 0x058F, 4), // Armenian
        (0x0590 ... 0x05FF, 5), // Hebrew
        (0x0600 ... 0x06FF, 6), (0x0750 ... 0x077F, 6), // Arabic
        (0x0900 ... 0x097F, 7), // Devanagari
        (0x0E00 ... 0x0E7F, 8), // Thai
        (0x10A0 ... 0x10FF, 9), // Georgian
        (0x1100 ... 0x11FF, 10), (0x3130 ... 0x318F, 10), (0xAC00 ... 0xD7AF, 10), // Hangul
        (0x3040 ... 0x30FF, 11), (0x3400 ... 0x4DBF, 11), (0x4E00 ... 0x9FFF, 11), (0xF900 ... 0xFAFF, 11),
    ]

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
