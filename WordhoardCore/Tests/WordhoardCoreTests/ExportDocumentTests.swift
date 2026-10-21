import Foundation
import Testing
import WordhoardCore

/// The DTO codec on its own: no store, no SwiftData.
@Suite("ExportDocument codec")
struct ExportDocumentTests {
    /// Every optional present.
    private static let fullWord = ExportWord(
        id: TransferFixture.uuid(1),
        learningLanguage: "en",
        headword: "book",
        pronunciation: "buk",
        note: "a note",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000.125),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
        tagIDs: [TransferFixture.uuid(100)],
        senses: [
            ExportSense(
                id: TransferFixture.uuid(10),
                order: 0,
                partOfSpeech: .noun,
                senseSource: .model,
                gloss: "a gloss",
                definition: "a definition",
                translation: "книга",
                synonyms: ["volume"],
                antonyms: ["nothing"],
                fieldSources: ["definition": .user, "translation": .auto],
                examples: [
                    ExportExample(
                        id: TransferFixture.uuid(20),
                        order: 0,
                        text: "A sentence with a / slash.",
                        grammarTopic: "en.present_perfect",
                        source: .user
                    ),
                ]
            ),
        ]
    )

    /// Every optional absent, every collection empty.
    private static let bareWord = ExportWord(
        id: TransferFixture.uuid(2),
        learningLanguage: "en",
        headword: "apple",
        pronunciation: nil,
        note: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_001),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
        tagIDs: [],
        senses: [
            ExportSense(
                id: TransferFixture.uuid(11),
                order: 0,
                partOfSpeech: .other,
                senseSource: nil,
                gloss: nil,
                definition: "",
                translation: nil,
                synonyms: [],
                antonyms: [],
                fieldSources: [:],
                examples: [
                    ExportExample(id: TransferFixture.uuid(21), order: 0, text: "", grammarTopic: nil, source: .auto),
                ]
            ),
        ]
    )

    @Test("the document round-trips through its codec with every optional present and absent")
    func exportDocumentRoundTripsThroughItsCodec() throws {
        let document = ExportDocument(
            exportedAt: TransferFixture.exportedAt,
            appVersion: nil,
            settings: makeSettings(nativeLanguage: "ru", activeGrammarTopics: [], autoGenerateImages: false),
            tags: [ExportTag(id: TransferFixture.uuid(100), name: "reading")],
            words: [Self.fullWord, Self.bareWord]
        )

        let data = try document.encode()
        let text = try utf8(data)
        #expect(!text.contains("null"))
        #expect(!text.contains("appVersion"))
        #expect(text.contains("\"createdAt\" : \"2023-11-14T22:13:20.125Z\""))
        #expect(text.contains("A sentence with a / slash."))
        #expect(try ExportDocument.decode(data) == document)
        #expect(try ExportDocument.decode(data).encode() == data)
    }

    @Test("a date without fractional seconds and a lowercase UUID decode")
    func aDateWithoutFractionAndALowercaseUUIDDecode() throws {
        let text = replacing(
            "\"createdAt\" : \"2023-11-14T22:16:40.000Z\"",
            in: GoldenExport.text,
            with: "\"createdAt\" : \"2023-11-14T22:16:40Z\""
        )
        let lowercased = replacing(
            "\"id\" : \"00000000-0000-0000-0000-000000000002\"",
            in: text,
            with: "\"id\" : \"abcdef01-0000-0000-0000-000000000002\""
        )

        let document = try ExportDocument.decode(Data(lowercased.utf8))
        #expect(document.words.last?.createdAt == TransferFixture.appleCreatedAt)
        #expect(document.words.last?.id == UUID(uuidString: "ABCDEF01-0000-0000-0000-000000000002"))
    }

    @Test("the golden text decodes to the document the fixture exports")
    func goldenTextDecodesToTheFixtureDocument() throws {
        let document = try ExportDocument.decode(GoldenExport.data)
        #expect(document.schemaVersion == 1)
        #expect(document.exportedAt == TransferFixture.exportedAt)
        #expect(document.appVersion == TransferFixture.appVersion)
        #expect(document.words.map(\.headword) == ["book", "apple"])
        #expect(document.words.first?.senses.first?.fieldSources == ["definition": .user, "synonyms": .auto])
        #expect(document.words.first?.senses.first?.examples.last?.grammarTopic == "en.no_such_topic")
        #expect(try document.encode() == GoldenExport.data)
    }
}
