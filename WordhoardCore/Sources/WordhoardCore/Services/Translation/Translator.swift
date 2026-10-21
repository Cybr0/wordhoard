import Foundation

/// Translations come from Apple's Translation framework, never from the language model (A9, ADR 0001
/// point 3). The generator asks `availability` first and makes one `translate` batch per word.
public protocol Translator: Sendable {
    /// Whether `source` → `target` can be translated right now. Language tags are BCP-47 (`"en"`, `"ru"`).
    func availability(from source: String, to target: String) async -> TranslationAvailability

    /// One framework batch: every text translated, keyed by its source text. Texts the framework did
    /// not answer are missing from the result; the caller treats a missing key as "not translated".
    /// Throws `TranslatorError`.
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String: String]
}

/// Mirrors `LanguageAvailability.Status`.
public enum TranslationAvailability: Equatable, Sendable {
    /// The language pack is on the device; `translate` works offline.
    case installed
    /// The pairing is supported but the pack is not downloaded; the field stays empty with a note.
    case supported
    /// The framework cannot translate this pairing at all.
    case unsupported
}

/// How a translation batch fails.
public enum TranslatorError: Error, Equatable, Sendable {
    /// The pack for this pairing is not installed (or the pairing is unsupported); nothing was sent.
    case languagePackNotInstalled(source: String, target: String)
    /// The framework rejected or failed the batch, with a one-line description for the log.
    case failed(String)
}
