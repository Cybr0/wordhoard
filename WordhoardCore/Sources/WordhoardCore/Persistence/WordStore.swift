import Foundation
import os
import SwiftData

/// Outcome of `WordStore.add(_:)` (C4): either a new card or the card that already held the word.
public enum AddResult: Equatable {
    /// A new `Word` was inserted and saved.
    case created(Word)
    /// An active word with the same `normalized` key already existed; nothing was written.
    case existing(Word)

    /// The word in either case.
    public var word: Word {
        switch self {
        case let .created(word), let .existing(word):
            word
        }
    }
}

public enum WordStoreError: Error, Equatable {
    /// The headword was empty after trimming whitespace and newlines. Nothing was inserted or saved.
    case emptyHeadword
}

/// The one place the app reads and writes words. Views, intents and services go through this class and
/// never touch a `ModelContext` directly.
///
/// **Isolation: `@MainActor`.** The store wraps the container's `mainContext` and returns `@Model`
/// objects, which are not `Sendable`; every v1 caller (SwiftUI views and view models, the App Intent's
/// `perform()`) already runs on the main actor, so the objects can be handed over directly.
///
/// Saves are explicit: every mutating method ends with a save, so a fresh `ModelContext` on the same
/// container sees the change as soon as the method returns. Autosave is switched off on the context so
/// that each save point is visible in this file, and so that the `.existing` and `emptyHeadword` paths
/// provably write nothing. The store is the only writer to the main context in v1.
///
/// SwiftData errors from fetch and save are logged and rethrown, never swallowed.
@MainActor
public final class WordStore {
    private let context: ModelContext
    private let logger = Logger(subsystem: "Wordhoard", category: "store")

    public init(container: ModelContainer) {
        context = container.mainContext
        context.autosaveEnabled = false
    }

    // MARK: - Capture

    /// Adds `headword` or returns the active word that already holds it (C1, C4, C5).
    ///
    /// The headword is trimmed of leading and trailing whitespace and newlines; internal spacing and
    /// letter case are stored as typed, because `headword` is the display form. Duplicate lookup uses
    /// `Word.normalize(_:)` against **active** words only: a soft-deleted word never matches and is
    /// never revived, so re-adding it creates a fresh word with a new `id`. When several active words
    /// match (possible only after a future sync) the oldest wins and nothing is created.
    ///
    /// - Returns: `.created` after inserting and saving a new `Word`; `.existing` when a match was found,
    ///   in which case nothing is modified (not even `updatedAt`) and nothing is saved.
    /// - Throws: `WordStoreError.emptyHeadword` when the trimmed headword is empty; nothing is saved.
    public func add(_ headword: String) throws -> AddResult {
        let trimmed = Self.trimmed(headword)
        guard !trimmed.isEmpty else {
            throw WordStoreError.emptyHeadword
        }
        if let existing = try activeWord(normalized: Word.normalize(trimmed)) {
            return .existing(existing)
        }
        let word = Word(headword: trimmed)
        context.insert(word)
        try save()
        return .created(word)
    }

    // MARK: - Reading

    /// Every word that is not soft-deleted, newest first (B1).
    public func words() throws -> [Word] {
        try context.fetch(Word.activeDescriptor())
    }

    /// Active words whose `normalized` headword contains the normalized `query` as a substring, in the
    /// same order as `words()` (B1). The query goes through `Word.normalize(_:)`, so case, surrounding
    /// whitespace and internal whitespace runs do not matter; whitespace is collapsed, not removed, so
    /// `" bo ok "` does not match `book`. An empty normalized query returns exactly `words()`.
    public func search(_ query: String) throws -> [Word] {
        let key = Word.normalize(query)
        guard !key.isEmpty else {
            return try words()
        }
        var descriptor = Word.activeDescriptor()
        descriptor.predicate = #Predicate { $0.deletedAt == nil && $0.normalized.contains(key) }
        return try context.fetch(descriptor)
    }

    /// The word with this `id`, **including** soft-deleted ones, or `nil` when there is no such row.
    public func word(id: UUID) throws -> Word? {
        var descriptor = FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Mutation

    /// Soft-deletes `word` (W3, §5): sets `deletedAt`, bumps `updatedAt`, saves. Senses, examples, tags
    /// and the image stay stored; the cascade belongs to hard delete. Deleting an already-deleted word
    /// is a no-op that keeps the original `deletedAt`.
    public func delete(_ word: Word) throws {
        guard word.deletedAt == nil else {
            return
        }
        let now = Date.now
        word.deletedAt = now
        word.updatedAt = now
        try save()
    }

    /// Persists in-place edits to `word` and its senses and examples. Trims `headword` with the same
    /// rule as `add(_:)`, re-derives `normalized` so the duplicate key can never drift from the
    /// headword, bumps `updatedAt`, saves. Whether a renamed headword now collides with another word is
    /// the caller's to handle.
    ///
    /// - Throws: `WordStoreError.emptyHeadword` when the trimmed headword is empty; nothing is saved.
    public func save(_ word: Word) throws {
        let trimmed = Self.trimmed(word.headword)
        guard !trimmed.isEmpty else {
            throw WordStoreError.emptyHeadword
        }
        word.headword = trimmed
        word.normalized = Word.normalize(trimmed)
        word.updatedAt = .now
        try save()
    }

    /// The single settings record, created from the English catalog's defaults and saved immediately
    /// on first use, so a second context never creates a second record.
    public func settings() throws -> UserSettings {
        let settings = try UserSettings.current(in: context)
        let isNew = context.insertedModelsArray.contains { ($0 as? UserSettings) === settings }
        if isNew {
            try save()
        }
        return settings
    }

    // MARK: - Helpers

    /// The oldest active word with this `normalized` key (`createdAt` ascending, `id` as tie-break).
    private func activeWord(normalized: String) throws -> Word? {
        var descriptor = FetchDescriptor<Word>(
            predicate: #Predicate { $0.deletedAt == nil && $0.normalized == normalized },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Drops leading and trailing whitespace and newlines, using the same `Character.isWhitespace` test
    /// as `Word.normalize(_:)` so a headword is blank for `add`/`save` exactly when its key is empty.
    private static func trimmed(_ headword: String) -> String {
        guard let first = headword.firstIndex(where: { !$0.isWhitespace }),
              let last = headword.lastIndex(where: { !$0.isWhitespace })
        else {
            return ""
        }
        return String(headword[first ... last])
    }
}
