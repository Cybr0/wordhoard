import Foundation
import SwiftData

/// A user label on words. Schema only in v1 (no tag UI, W4 is later); exported by plan task 1.7.
@Model
public final class Tag {
    public var id: UUID = UUID()
    public var name: String = ""
    /// Inverse of `Word.tags`; the `@Relationship` declaration lives on `Word`.
    public var words: [Word] = []

    public init(name: String) {
        self.name = name
    }
}
