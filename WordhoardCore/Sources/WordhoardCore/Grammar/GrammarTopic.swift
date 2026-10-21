/// A fully namespaced grammar topic key, e.g. the language code, a dot and a snake_case name.
///
/// A typealias rather than a wrapper struct: `Example.grammarTopic` and
/// `UserSettings.activeGrammarTopics` are stored as strings, and the catalog lookup
/// (`GrammarCatalog.topic(for:)`) is the only check a key needs.
public typealias GrammarTopicID = String

/// One grammar topic from the catalog (requirements G1, Appendix A).
public struct GrammarTopic: Hashable, Sendable, Identifiable, Decodable {
    /// Namespaced key, exactly as stored on `Example.grammarTopic`.
    public let key: GrammarTopicID
    /// Display name. Lives in the catalog file, not the String Catalog, like any other shipped data.
    public let name: String
    /// One line, "form, use", for the example prompt (plan task 3.2).
    public let description: String

    public var id: GrammarTopicID {
        key
    }

    public init(key: GrammarTopicID, name: String, description: String) {
        self.key = key
        self.name = name
        self.description = description
    }
}

/// A named group of topics in catalog order, e.g. the tenses.
public struct GrammarTopicGroup: Hashable, Sendable, Decodable {
    public let name: String
    public let topics: [GrammarTopic]

    public init(name: String, topics: [GrammarTopic]) {
        self.name = name
        self.topics = topics
    }
}
