import Foundation
import SwiftData

/// An example sentence for a `Sense`, optionally tagged with one grammar topic (requirements G4).
@Model
public final class Example {
    public var id: UUID = UUID()
    public var sense: Sense?
    public var text: String = ""
    /// Namespaced key into the grammar catalog, e.g. `"en.present_perfect"`; `nil` is a neutral
    /// example. Never validated at the store: the catalog grows with app updates, so readers resolve
    /// the key with `GrammarCatalog.topic(for:)` and treat an unknown one like `nil`.
    public var grammarTopic: GrammarTopicID?
    /// Stored default is `.user` so a record that somehow lacks it is never overwritten.
    public var source: FieldSource = FieldSource.user
    /// Position within `Sense.examples`; the relationship itself is unordered.
    public var order: Int = 0

    public init(text: String = "", source: FieldSource, grammarTopic: GrammarTopicID? = nil, order: Int = 0) {
        self.text = text
        self.source = source
        self.grammarTopic = grammarTopic
        self.order = order
    }
}
