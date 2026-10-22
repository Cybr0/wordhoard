import Foundation

/// The export file, schema v1 (requirements S3, plan task 1.7).
///
/// A plain `Codable` mirror of the user's hoard, separate from the `@Model` classes so the file format
/// can be read and written without a store. The number in `schemaVersion` changes only when a v1 reader
/// could misread the file; adding optional keys is not a change. `appVersion` is informational and
/// optional on input; the other top-level keys are required.
///
/// Not in the file: the derived duplicate key (recomputed on import), tombstones, images and review
/// events (a future sync ADR decides about those).
public struct ExportDocument: Codable, Equatable, Sendable {
    /// The schema this build writes and the newest it reads.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var settings: ExportSettings
    public var tags: [ExportTag]
    public var words: [ExportWord]

    public init(
        schemaVersion: Int = ExportDocument.currentSchemaVersion,
        exportedAt: Date,
        appVersion: String?,
        settings: ExportSettings,
        tags: [ExportTag],
        words: [ExportWord]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.settings = settings
        self.tags = tags
        self.words = words
    }

    // MARK: - Codec

    /// Encodes with sorted keys, two-space pretty printing and unescaped slashes, so two exports of the
    /// same hoard are byte-identical and files diff cleanly. Dates are ISO 8601 UTC with milliseconds;
    /// `nil` optionals are omitted.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.format(date))
        }
        return try encoder.encode(self)
    }

    /// Decodes `data`, checking the schema version first.
    ///
    /// - Throws: `ImportError.notAWordhoardExport` for malformed JSON, a wrong shape, a missing or
    ///   non-integer `schemaVersion` or one below 1; `ImportError.newerSchema` for a version above
    ///   `currentSchemaVersion`; `ImportError.unknownValue` for an enum raw value this build does not know.
    ///   Unknown keys are ignored.
    public static func decode(_ data: Data) throws -> ExportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            do {
                return try roundedToMillisecond(dateFormat.parse(text))
            } catch {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not an ISO 8601 date: \(text)"
                ))
            }
        }

        let probe: SchemaProbe
        do {
            probe = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            throw ImportError.notAWordhoardExport
        }
        guard probe.schemaVersion >= 1 else {
            throw ImportError.notAWordhoardExport
        }
        guard probe.schemaVersion <= currentSchemaVersion else {
            throw ImportError.newerSchema(found: probe.schemaVersion, supported: currentSchemaVersion)
        }

        do {
            return try decoder.decode(ExportDocument.self, from: data)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.notAWordhoardExport
        }
    }

    /// Parses `2026-10-21T12:34:56.789Z`, also without the fraction. Not used for output: this style
    /// truncates the fraction, and a parsed `.362` sits just below the millisecond, so it would print `.361`.
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondFormat = Date.ISO8601FormatStyle()

    /// `2026-10-21T12:34:56.789Z`, rounded to the nearest millisecond; the fraction is built from an
    /// integer so every millisecond value is a fixed point of format → parse → format.
    static func format(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1000)
        let whole = Date(timeIntervalSince1970: seconds).formatted(Self.wholeSecondFormat)
        return whole.dropLast() + String(format: ".%03dZ", fraction)
    }

    /// The nearest representable instant to the millisecond `date` names.
    static func roundedToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// Just enough of the top level to read the version before the rest is decoded.
    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }
}

/// The four fields of `UserSettings`.
public struct ExportSettings: Codable, Equatable, Sendable {
    public var nativeLanguage: String?
    public var learningLanguage: String
    public var activeGrammarTopics: [GrammarTopicID]
    public var autoGenerateImages: Bool

    public init(
        nativeLanguage: String?,
        learningLanguage: String,
        activeGrammarTopics: [GrammarTopicID],
        autoGenerateImages: Bool
    ) {
        self.nativeLanguage = nativeLanguage
        self.learningLanguage = learningLanguage
        self.activeGrammarTopics = activeGrammarTopics
        self.autoGenerateImages = autoGenerateImages
    }
}

/// A `Tag` attached to at least one exported word.
public struct ExportTag: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// An active `Word` with its senses, in `createdAt` order within the file.
public struct ExportWord: Codable, Equatable, Sendable {
    public var id: UUID
    public var learningLanguage: String
    public var headword: String
    public var pronunciation: String?
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Sorted by `uuidString`; every entry refers to `ExportDocument.tags`.
    public var tagIDs: [UUID]
    /// In `order`.
    public var senses: [ExportSense]

    public init(
        id: UUID,
        learningLanguage: String,
        headword: String,
        pronunciation: String?,
        note: String?,
        createdAt: Date,
        updatedAt: Date,
        tagIDs: [UUID],
        senses: [ExportSense]
    ) {
        self.id = id
        self.learningLanguage = learningLanguage
        self.headword = headword
        self.pronunciation = pronunciation
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tagIDs = tagIDs
        self.senses = senses
    }
}

/// A `Sense`. Enum fields are written as case names; a value this build does not know fails the decode
/// with `ImportError.unknownValue` rather than being mapped or skipped.
public struct ExportSense: Codable, Equatable, Sendable {
    public var id: UUID
    public var order: Int
    public var partOfSpeech: PartOfSpeech
    public var senseSource: SenseSource?
    public var gloss: String?
    public var definition: String
    public var translation: String?
    /// Written as the optional key `translationIsFallback` only when `true`; a missing key reads as
    /// `false` (plan 2.10), so files from before the field and files without fallbacks are unchanged.
    public var translationIsFallback: Bool
    public var synonyms: [String]
    public var antonyms: [String]
    /// Only the keys present; a missing key means `.auto`, as in `Sense.fieldSource(for:)`.
    public var fieldSources: [String: FieldSource]
    /// In `order`.
    public var examples: [ExportExample]

    public init(
        id: UUID,
        order: Int,
        partOfSpeech: PartOfSpeech,
        senseSource: SenseSource?,
        gloss: String?,
        definition: String,
        translation: String?,
        translationIsFallback: Bool = false,
        synonyms: [String],
        antonyms: [String],
        fieldSources: [String: FieldSource],
        examples: [ExportExample]
    ) {
        self.id = id
        self.order = order
        self.partOfSpeech = partOfSpeech
        self.senseSource = senseSource
        self.gloss = gloss
        self.definition = definition
        self.translation = translation
        self.translationIsFallback = translationIsFallback
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.fieldSources = fieldSources
        self.examples = examples
    }

    private enum CodingKeys: String, CodingKey {
        case id, order, partOfSpeech, senseSource, gloss, definition, translation, translationIsFallback
        case synonyms, antonyms, fieldSources, examples
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(order, forKey: .order)
        try container.encode(partOfSpeech, forKey: .partOfSpeech)
        try container.encodeIfPresent(senseSource, forKey: .senseSource)
        try container.encodeIfPresent(gloss, forKey: .gloss)
        try container.encode(definition, forKey: .definition)
        try container.encodeIfPresent(translation, forKey: .translation)
        if translationIsFallback {
            try container.encode(true, forKey: .translationIsFallback)
        }
        try container.encode(synonyms, forKey: .synonyms)
        try container.encode(antonyms, forKey: .antonyms)
        try container.encode(fieldSources, forKey: .fieldSources)
        try container.encode(examples, forKey: .examples)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)
        partOfSpeech = try container.decodeCase(PartOfSpeech.self, forKey: .partOfSpeech)
        senseSource = try container.decodeCaseIfPresent(SenseSource.self, forKey: .senseSource)
        gloss = try container.decodeIfPresent(String.self, forKey: .gloss)
        definition = try container.decode(String.self, forKey: .definition)
        translation = try container.decodeIfPresent(String.self, forKey: .translation)
        translationIsFallback = try container.decodeIfPresent(Bool.self, forKey: .translationIsFallback) ?? false
        synonyms = try container.decode([String].self, forKey: .synonyms)
        antonyms = try container.decode([String].self, forKey: .antonyms)
        fieldSources = try container.decode([String: String].self, forKey: .fieldSources).mapValues { raw in
            guard let source = FieldSource(rawValue: raw) else {
                throw ImportError.unknownValue(field: CodingKeys.fieldSources.stringValue, value: raw)
            }
            return source
        }
        examples = try container.decode([ExportExample].self, forKey: .examples)
    }
}

/// An `Example`. `grammarTopic` is any key, known to this build's catalog or not.
public struct ExportExample: Codable, Equatable, Sendable {
    public var id: UUID
    public var order: Int
    public var text: String
    public var grammarTopic: GrammarTopicID?
    public var source: FieldSource

    public init(id: UUID, order: Int, text: String, grammarTopic: GrammarTopicID?, source: FieldSource) {
        self.id = id
        self.order = order
        self.text = text
        self.grammarTopic = grammarTopic
        self.source = source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)
        text = try container.decode(String.self, forKey: .text)
        grammarTopic = try container.decodeIfPresent(GrammarTopicID.self, forKey: .grammarTopic)
        source = try container.decodeCase(FieldSource.self, forKey: .source)
    }
}

private extension KeyedDecodingContainer {
    /// Decodes a string-backed enum, turning a raw value this build does not know into
    /// `ImportError.unknownValue` named after the JSON key.
    func decodeCase<Value: RawRepresentable<String>>(_: Value.Type, forKey key: Key) throws -> Value {
        let raw = try decode(String.self, forKey: key)
        guard let value = Value(rawValue: raw) else {
            throw ImportError.unknownValue(field: key.stringValue, value: raw)
        }
        return value
    }

    func decodeCaseIfPresent<Value: RawRepresentable<String>>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        return try decodeCase(type, forKey: key)
    }
}
