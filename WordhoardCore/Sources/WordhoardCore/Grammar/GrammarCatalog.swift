import Foundation

/// Why a catalog file was rejected. Every case names the offending value so a broken resource is
/// diagnosed from the message alone.
public enum GrammarCatalogError: Error, Equatable, Sendable {
    /// No `GrammarCatalog/<language>.json` in the package bundle.
    case resourceNotFound(language: String)
    /// `groups` is empty.
    case noGroups
    /// The same key appears on two topics.
    case duplicateKey(GrammarTopicID)
    /// A key does not start with the file's `language` followed by a dot.
    case keyNotNamespaced(GrammarTopicID, language: String)
    /// `defaultActive` names a key that no group contains.
    case unknownDefaultKey(GrammarTopicID)
    /// `defaultActive` lists the same key twice.
    case duplicateDefaultKey(GrammarTopicID)
    /// A topic's `name` is empty or spans more than one line.
    case invalidName(key: GrammarTopicID)
    /// A topic's `description` is empty or spans more than one line.
    case invalidDescription(key: GrammarTopicID)
}

/// The shipped grammar-topic catalog for one learning language (requirements G1, Appendix A).
///
/// The catalog is data: topics live in `Resources/GrammarCatalog/<language>.json`, never in Swift.
/// Groups, topics and default keys keep file order, which is Appendix A order, so lists built from
/// them need no sorting. Use `GrammarCatalog.english`; it is loaded once.
public struct GrammarCatalog: Sendable {
    /// The learning-language code every key is prefixed with, e.g. `"en"`.
    public let language: String
    /// Groups in file order, each with its topics in file order.
    public let groups: [GrammarTopicGroup]
    /// All topics flattened across groups, in file order.
    public let topics: [GrammarTopic]
    /// The "currently learning" set a new `UserSettings` record starts with (G2), in file order.
    public let defaultActiveKeys: [GrammarTopicID]

    private let topicsByKey: [GrammarTopicID: GrammarTopic]

    /// The English catalog bundled with the package. A missing or malformed resource is a build
    /// defect caught by the unit tests, so this terminates rather than returning an empty catalog.
    public static let english: GrammarCatalog = {
        do {
            return try load(language: "en")
        } catch {
            fatalError("WordhoardCore: the bundled English grammar catalog failed to load: \(error)")
        }
    }()

    /// Reads `GrammarCatalog/<language>.json` from the package bundle and validates it.
    public static func load(language: String) throws -> GrammarCatalog {
        guard let url = Bundle.module.url(
            forResource: language, withExtension: "json", subdirectory: "GrammarCatalog"
        ) else {
            throw GrammarCatalogError.resourceNotFound(language: language)
        }
        return try GrammarCatalog(decoding: Data(contentsOf: url))
    }

    /// Decodes a catalog file and validates it. Throws `DecodingError` for malformed JSON and
    /// `GrammarCatalogError` for content that decodes but breaks the catalog's invariants.
    public init(decoding data: Data) throws {
        let file = try JSONDecoder().decode(CatalogFile.self, from: data)
        guard !file.groups.isEmpty else { throw GrammarCatalogError.noGroups }

        let prefix = "\(file.language)."
        var topics: [GrammarTopic] = []
        var topicsByKey: [GrammarTopicID: GrammarTopic] = [:]
        for topic in file.groups.flatMap(\.topics) {
            guard topic.key.hasPrefix(prefix), topic.key.count > prefix.count else {
                throw GrammarCatalogError.keyNotNamespaced(topic.key, language: file.language)
            }
            guard Self.isOneLine(topic.name) else { throw GrammarCatalogError.invalidName(key: topic.key) }
            guard Self.isOneLine(topic.description) else {
                throw GrammarCatalogError.invalidDescription(key: topic.key)
            }
            guard topicsByKey.updateValue(topic, forKey: topic.key) == nil else {
                throw GrammarCatalogError.duplicateKey(topic.key)
            }
            topics.append(topic)
        }
        var seenDefaults: Set<GrammarTopicID> = []
        for key in file.defaultActive {
            guard topicsByKey[key] != nil else { throw GrammarCatalogError.unknownDefaultKey(key) }
            guard seenDefaults.insert(key).inserted else { throw GrammarCatalogError.duplicateDefaultKey(key) }
        }

        language = file.language
        groups = file.groups
        self.topics = topics
        defaultActiveKeys = file.defaultActive
        self.topicsByKey = topicsByKey
    }

    /// The topic for `key`, or `nil` for anything the catalog does not know. Readers treat `nil`
    /// like a neutral example (G4); unknown keys are never a crash.
    public func topic(for key: GrammarTopicID) -> GrammarTopic? {
        topicsByKey[key]
    }

    private static func isOneLine(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !text.contains(where: \.isNewline)
    }

    /// The on-disk shape of a catalog file.
    private struct CatalogFile: Decodable {
        let language: String
        let defaultActive: [GrammarTopicID]
        let groups: [GrammarTopicGroup]
    }
}
