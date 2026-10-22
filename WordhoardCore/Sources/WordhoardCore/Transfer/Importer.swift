import Foundation
import os

/// Restores an `ExportDocument` into a `WordStore` (requirements S3, C4).
///
/// **Isolation: `@MainActor`**, like the store it writes. Decodes and validates the file before touching
/// the store, then does every write inside one `WordStore.transaction`, so any error (a typed
/// `ImportError` or a SwiftData error) leaves the store exactly as it was. The merge rules live in
/// `ImportMerge`.
@MainActor
public enum Importer {
    /// Merges `data` into `store` and reports what changed. Importing a file into the store it came from,
    /// or the same file twice, changes nothing and returns `ImportSummary.nothing`.
    ///
    /// - Throws: `ImportError` for a file this build cannot or will not read (nothing is written);
    ///   SwiftData errors as they are (the transaction was rolled back).
    public static func `import`(_ data: Data, into store: WordStore) throws -> ImportSummary {
        let document = try ExportDocument.decode(data)
        try checkForDuplicateIDs(in: document)
        return try store.transaction { context in
            var merge = try ImportMerge(document: document, context: context)
            return try merge.run()
        }
    }

    /// The same word, sense, example or tag id twice in one file is a hand-editing accident that the
    /// merge could only resolve by guessing, so the whole import is refused.
    private static func checkForDuplicateIDs(in document: ExportDocument) throws {
        var wordIDs = Set<UUID>()
        var senseIDs = Set<UUID>()
        var exampleIDs = Set<UUID>()
        var tagIDs = Set<UUID>()
        for tag in document.tags {
            try note(tag.id, in: &tagIDs)
        }
        for word in document.words {
            try note(word.id, in: &wordIDs)
            for sense in word.senses {
                try note(sense.id, in: &senseIDs)
                for example in sense.examples {
                    try note(example.id, in: &exampleIDs)
                }
            }
        }
    }

    private static func note(_ id: UUID, in seen: inout Set<UUID>) throws {
        guard seen.insert(id).inserted else {
            throw ImportError.duplicateID(id)
        }
    }

    /// Drops leading and trailing whitespace and newlines with the same `Character.isWhitespace` test as
    /// `WordStore` and `Word.normalize(_:)`, so a headword is blank for the importer exactly when the
    /// store would refuse it. Mirrors the store's private rule rather than widening the store's API.
    static func trimmed(_ text: String) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace })
        else {
            return ""
        }
        return String(text[first ... last])
    }
}

public extension Importer {
    /// The one import path of the app's models (1.7, 5.3): `import(_:into:)`, then the autofill sweep,
    /// so imported words without senses (saved `pending`) are filled now, not at the next foreground. A
    /// sweep error is logged; the import itself has already been saved.
    @MainActor
    static func importAndFill(_ data: Data, into store: WordStore, autofill: AutofillService?) throws -> ImportSummary {
        let summary = try self.import(data, into: store)
        do {
            try autofill?.resumeAfterLaunch()
        } catch {
            Logger(subsystem: "Wordhoard", category: "transfer")
                .error("Could not queue imported words: \(error.localizedDescription, privacy: .public)")
        }
        return summary
    }
}
