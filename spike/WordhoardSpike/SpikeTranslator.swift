// Phase 0 spike: English → Russian with Apple's on-device Translation framework.
//
// The first device run of the WordNet mode (issue #11) showed the language model's Russian
// was unreliable to the point of non-words ("ночальница"), so in that mode the model no
// longer translates anything: the learner definition and every WordNet synonym go through
// a TranslationSession instead. When the en→ru language pack is not installed there is no
// translation at all — never a fall back to the model.
//
// `TranslationSession` is not Sendable, so the session is created and used inside one
// nonisolated function and never crosses an isolation boundary; only `[String: String]`
// comes back. `init(installedSource:target:)` is iOS 26; the SwiftUI `.translationTask`
// modifier would be the iOS 18 way to obtain a session.
//
// No FoundationModels import here on purpose. Throwaway code.

import Foundation
import Translation

enum SpikeTranslator {
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "ru")

    enum Outcome: Sendable {
        /// The language pack is not installed (or the pairing is unsupported); `note` is the log line.
        case unavailable(note: String)
        /// Source → target for every string that translated; failed batches are missing from the map
        /// and described in `log`.
        case translated(translations: [String: String], elapsed: Duration, log: String)
    }

    /// Translates every string of every batch. One framework call per batch; a batch that fails
    /// is logged and skipped, the others still count. Duplicates across batches are translated once.
    nonisolated static func translate(batches: [[String]]) async -> Outcome {
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            let detail = switch status {
            case .supported: "pairing supported, pack not downloaded"
            case .unsupported: "pairing unsupported"
            default: "status \(status)"
            }
            return .unavailable(note: "Translation: en→ru language pack not installed → no translation (\(detail))")
        }

        let session = TranslationSession(installedSource: source, target: target)
        let clock = ContinuousClock()
        let start = clock.now
        var translations: [String: String] = [:]
        var log = ""

        for (index, batch) in batches.enumerated() {
            if Task.isCancelled { break }
            var pending: [String] = []
            for text in batch where !text.isEmpty && translations[text] == nil && !pending.contains(text) {
                pending.append(text)
            }
            guard !pending.isEmpty else { continue }

            let label = "translation batch \(index + 1): \(pending.count) string\(pending.count == 1 ? "" : "s") en→ru"
            let batchStart = clock.now
            do {
                let requests = pending.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
                let responses = try await session.translations(from: requests)
                let elapsed = clock.now - batchStart
                var lines: [String] = []
                for response in responses {
                    let key = response.clientIdentifier ?? response.sourceText
                    translations[key] = response.targetText
                    lines.append("\(key) → \(response.targetText)")
                }
                log += "--- \(label) (\(elapsed.spikeFormatted)) ---\n\(lines.joined(separator: "\n"))\n\n"
                print("=== \(label) (\(elapsed.spikeFormatted)) ===\n\(lines.joined(separator: "\n"))")
            } catch {
                log += "--- \(label) FAILED ---\n\(error)\n\n"
                print("\(label) failed: \(error)")
            }
        }
        return .translated(translations: translations, elapsed: clock.now - start, log: log)
    }
}
