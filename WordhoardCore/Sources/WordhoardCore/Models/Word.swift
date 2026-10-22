import Foundation
import SwiftData

/// A headword the user is learning, with its senses (requirements §3, §5).
///
/// Shape is CloudKit-compatible: every property is optional or defaulted, the id is client-generated,
/// deletion is soft via `deletedAt`, and there is no unique constraint — duplicate detection is done
/// by `WordStore` on `normalized` (C4).
@Model
public final class Word {
    public var id: UUID = UUID()
    /// BCP-47 tag of the language being learned. Always `"en"` in v1 (requirements §11).
    public var learningLanguage: String = "en"
    /// The word as the user entered it, verbatim.
    public var headword: String = ""
    /// Comparison key derived from `headword` by `Word.normalize(_:)`.
    public var normalized: String = ""
    /// Reserved for a future pronunciation source; never generated or shown in v1 (A3).
    public var pronunciation: String?
    public var note: String?
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now
    /// Soft-delete marker. A non-nil value hides the word from `Word.activeDescriptor()`.
    public var deletedAt: Date?
    /// Autofill progress (plan 2.3). Defaulted so a word created by anyone is a word to fill in.
    public var autofillState: AutofillState = AutofillState.pending

    @Relationship(deleteRule: .nullify, inverse: \Tag.words)
    public var tags: [Tag] = []

    /// The cascade fires only when the `Word` is hard-deleted. Never assign it directly: assigning a new
    /// asset does not delete the previous one. `WordStore.setImage(_:for:)`, `removeImage(from:)` and
    /// `delete(_:)` keep one row per word and hand back the replaced file's name (plan 4.1).
    @Relationship(deleteRule: .cascade, inverse: \ImageAsset.word)
    public var image: ImageAsset?

    @Relationship(deleteRule: .cascade, inverse: \Sense.word)
    public var senses: [Sense] = []

    public init(headword: String) {
        let now = Date.now
        self.headword = headword
        normalized = Word.normalize(headword)
        createdAt = now
        updatedAt = now
    }

    /// `senses` in `Sense.order`; the relationship itself is unordered.
    public var sortedSenses: [Sense] {
        senses.sorted { $0.order < $1.order }
    }

    /// The comparison key for duplicate detection (C4): lowercased, trimmed of leading and trailing
    /// whitespace and newlines, with internal whitespace runs collapsed to one space, in Unicode
    /// canonical composed form (NFC) so canonically equivalent input yields byte-identical keys that
    /// SQLite predicates can match. No diacritic folding: `café` stays distinct from `cafe`.
    public static func normalize(_ headword: String) -> String {
        headword
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    /// Words that are not soft-deleted, newest first (B1), ties broken by `id` so the order is
    /// stable. The default fetch for every list.
    public static func activeDescriptor() -> FetchDescriptor<Word> {
        FetchDescriptor<Word>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)]
        )
    }
}
