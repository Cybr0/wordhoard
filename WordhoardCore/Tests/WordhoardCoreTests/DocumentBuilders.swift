import Foundation
import SwiftData
import Testing
import WordhoardCore

// Short constructors for hand-built export documents in the importer tests. Defaults are the plainest
// valid values; tests name only what they are about.

func makeDocument(
    words: [ExportWord],
    tags: [ExportTag] = [],
    settings: ExportSettings = makeSettings(),
    schemaVersion: Int = ExportDocument.currentSchemaVersion
) -> ExportDocument {
    ExportDocument(
        schemaVersion: schemaVersion,
        exportedAt: TransferFixture.exportedAt,
        appVersion: TransferFixture.appVersion,
        settings: settings,
        tags: tags,
        words: words
    )
}

func makeSettings(
    nativeLanguage: String? = nil,
    learningLanguage: String = "en",
    activeGrammarTopics: [GrammarTopicID] = GrammarCatalog.english.defaultActiveKeys,
    autoGenerateImages: Bool = true
) -> ExportSettings {
    ExportSettings(
        nativeLanguage: nativeLanguage,
        learningLanguage: learningLanguage,
        activeGrammarTopics: activeGrammarTopics,
        autoGenerateImages: autoGenerateImages
    )
}

func makeWord(
    id: UUID = UUID(),
    headword: String,
    note: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    tagIDs: [UUID] = [],
    senses: [ExportSense] = []
) -> ExportWord {
    ExportWord(
        id: id,
        learningLanguage: "en",
        headword: headword,
        pronunciation: nil,
        note: note,
        createdAt: createdAt,
        updatedAt: updatedAt,
        tagIDs: tagIDs,
        senses: senses
    )
}

func makeSense(
    id: UUID = UUID(),
    order: Int = 0,
    partOfSpeech: PartOfSpeech = .noun,
    definition: String = "a definition",
    examples: [ExportExample] = []
) -> ExportSense {
    ExportSense(
        id: id,
        order: order,
        partOfSpeech: partOfSpeech,
        senseSource: nil,
        gloss: nil,
        definition: definition,
        translation: nil,
        synonyms: [],
        antonyms: [],
        fieldSources: [:],
        examples: examples
    )
}

func makeExample(id: UUID = UUID(), order: Int = 0, text: String = "An example.") -> ExportExample {
    ExportExample(id: id, order: order, text: text, grammarTopic: nil, source: .auto)
}

/// Everything an import can read back, in a plain `Equatable` shape, with dates to the millisecond.
/// Comparing two stores' snapshots is the field-by-field half of the round-trip criterion.
struct HoardSnapshot: Equatable {
    struct Example: Equatable {
        var text: String
        var grammarTopic: String?
        var source: FieldSource
        var order: Int
    }

    struct Sense: Equatable {
        var partOfSpeech: PartOfSpeech
        var senseSource: SenseSource?
        var gloss: String?
        var definition: String
        var translation: String?
        var translationIsFallback: Bool
        var synonyms: [String]
        var antonyms: [String]
        var fieldSources: [String: FieldSource]
        var order: Int
        var examples: [Example]
    }

    struct Word: Equatable {
        var id: UUID
        var headword: String
        var normalized: String
        var learningLanguage: String
        var pronunciation: String?
        var note: String?
        var createdAtMilliseconds: Int
        var updatedAtMilliseconds: Int
        var tagNames: [String]
        var senses: [Sense]
    }

    var words: [Word]
    var nativeLanguage: String?
    var learningLanguage: String
    var activeGrammarTopics: [String]
    var autoGenerateImages: Bool

    @MainActor
    init(of store: WordStore) throws {
        words = try store.words()
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { word in
                Word(
                    id: word.id,
                    headword: word.headword,
                    normalized: word.normalized,
                    learningLanguage: word.learningLanguage,
                    pronunciation: word.pronunciation,
                    note: word.note,
                    createdAtMilliseconds: Int((word.createdAt.timeIntervalSince1970 * 1000).rounded()),
                    updatedAtMilliseconds: Int((word.updatedAt.timeIntervalSince1970 * 1000).rounded()),
                    tagNames: word.tags.map(\.name).sorted(),
                    senses: word.sortedSenses.map { sense in
                        Sense(
                            partOfSpeech: sense.partOfSpeech,
                            senseSource: sense.senseSource,
                            gloss: sense.gloss,
                            definition: sense.definition,
                            translation: sense.translation,
                            translationIsFallback: sense.translationIsFallback,
                            synonyms: sense.synonyms,
                            antonyms: sense.antonyms,
                            fieldSources: sense.fieldSources,
                            order: sense.order,
                            examples: sense.sortedExamples.map { example in
                                Example(
                                    text: example.text,
                                    grammarTopic: example.grammarTopic,
                                    source: example.source,
                                    order: example.order
                                )
                            }
                        )
                    }
                )
            }
        let settings = try store.settings()
        nativeLanguage = settings.nativeLanguage
        learningLanguage = settings.learningLanguage
        activeGrammarTopics = settings.activeGrammarTopics
        autoGenerateImages = settings.autoGenerateImages
    }
}
