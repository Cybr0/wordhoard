import Foundation
import Synchronization

/// A `Translator` for tests: `x` → `table[x] ?? "<prefix>x"`, records every batch.
///
/// **Isolation: none.** A `Sendable` class with its recorded batches behind a `Mutex`. With
/// `availability != .installed` or a `failure`, `translate` throws the matching `TranslatorError`.
public final class StubTranslator: Translator {
    /// One recorded `translate` call.
    public struct Batch: Equatable, Sendable {
        public var texts: [String]
        public var source: String
        public var target: String
    }

    private let storedAvailability: TranslationAvailability
    private let table: [String: String]
    private let prefix: String
    private let failure: TranslatorError?
    private let recorded = Mutex<[Batch]>([])

    public init(
        availability: TranslationAvailability = .installed,
        table: [String: String] = [:],
        prefix: String = "ru:",
        failure: TranslatorError? = nil
    ) {
        storedAvailability = availability
        self.table = table
        self.prefix = prefix
        self.failure = failure
    }

    /// Every `translate` call, in order, including ones that threw.
    public var batches: [Batch] {
        recorded.withLock { $0 }
    }

    public func availability(from source: String, to target: String) async -> TranslationAvailability {
        storedAvailability
    }

    public func translate(_ texts: [String], from source: String, to target: String) async throws -> [String: String] {
        recorded.withLock { $0.append(Batch(texts: texts, source: source, target: target)) }
        guard storedAvailability == .installed else {
            throw TranslatorError.languagePackNotInstalled(source: source, target: target)
        }
        if let failure {
            throw failure
        }
        return Dictionary(uniqueKeysWithValues: Set(texts).map { ($0, table[$0] ?? prefix + $0) })
    }
}
