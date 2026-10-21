#if canImport(Translation)
    import Foundation
    import os
    import Translation

    /// The production `Translator` over Apple's on-device Translation framework (A9).
    ///
    /// **Isolation: none.** `TranslationSession` is not `Sendable`, so `translate` creates it, uses it
    /// and drops it inside one `nonisolated` async function; only `[String: String]` leaves. The
    /// `installedSource:target:` initializer (iOS 26+) needs no SwiftUI host, which is what lets this
    /// live in Core. Escape hatch (issue #38): should the macOS `swift test` host stop compiling the
    /// framework, this one file moves to the app target and is injected; the protocol stays here.
    public struct AppleTranslator: Translator {
        private static let logger = Logger(subsystem: "Wordhoard", category: "autofill")

        public init() {}

        public func availability(from source: String, to target: String) async -> TranslationAvailability {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
            )
            switch status {
            case .installed: return .installed
            case .supported: return .supported
            case .unsupported: return .unsupported
            @unknown default: return .unsupported
            }
        }

        public nonisolated func translate(
            _ texts: [String],
            from source: String,
            to target: String
        ) async throws -> [String: String] {
            guard await availability(from: source, to: target) == .installed else {
                throw TranslatorError.languagePackNotInstalled(source: source, target: target)
            }
            var pending: [String] = []
            for text in texts where !text.isEmpty && !pending.contains(text) {
                pending.append(text)
            }
            guard !pending.isEmpty else { return [:] }

            let session = TranslationSession(
                installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target)
            )
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let requests = pending.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
                let responses = try await session.translations(from: requests)
                var translations: [String: String] = [:]
                for response in responses {
                    translations[response.clientIdentifier ?? response.sourceText] = response.targetText
                }
                Self.logger.debug(
                    """
                    translated \(translations.count, privacy: .public) of \(pending.count, privacy: .public) strings \
                    \(source, privacy: .public)→\(target, privacy: .public) in \
                    \((clock.now - start).formattedSeconds, privacy: .public)
                    """
                )
                return translations
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.debug("translation batch failed: \(String(describing: error), privacy: .public)")
                throw TranslatorError.failed(String(describing: error))
            }
        }
    }
#endif
