import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Every way a file is refused (issue #36): the typed error, its message, and a store left untouched.
@MainActor
@Suite("Importer refusals")
struct ImporterRefusalTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func expectRefused(
        _ text: String,
        with error: ImportError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectRefused(Data(text.utf8), with: error, sourceLocation: sourceLocation)
    }

    private func expectRefused(
        _ data: Data,
        with error: ImportError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let before = try RowCounts(in: container)
        #expect(sourceLocation: sourceLocation) {
            try Importer.import(data, into: store)
        } throws: { thrown in
            thrown as? ImportError == error
        }
        #expect(try RowCounts(in: container) == before, sourceLocation: sourceLocation)
    }

    @Test("a newer schema version is refused with the update message and nothing written")
    func aNewerSchemaVersionIsRefused() throws {
        let text = replacing("\"schemaVersion\" : 1", in: GoldenExport.text, with: "\"schemaVersion\" : 2")
        try expectRefused(text, with: .newerSchema(found: 2, supported: 1))
        #expect(
            ImportError.newerSchema(found: 2, supported: 1).errorDescription
                == "This file was made by a newer version of Wordhoard. Update the app and try again."
        )
        #expect(try store.words().isEmpty)
    }

    @Test("a string, zero, negative, null or fractional schema version is not a Wordhoard export")
    func aNonIntegerOrZeroSchemaVersionIsNotAnExport() throws {
        for value in ["\"1\"", "0", "-1", "null", "1.5"] {
            let text = replacing("\"schemaVersion\" : 1", in: GoldenExport.text, with: "\"schemaVersion\" : \(value)")
            try expectRefused(text, with: .notAWordhoardExport)
        }
        try expectRefused(
            GoldenExport.text.replacingOccurrences(of: "\"schemaVersion\" : 1,\n", with: ""),
            with: .notAWordhoardExport
        )
        #expect(ImportError.notAWordhoardExport.errorDescription == "This file isn't a Wordhoard export.")
    }

    @Test("malformed input is refused and the store untouched")
    func malformedFilesAreRefused() throws {
        try expectRefused("{", with: .notAWordhoardExport)
        try expectRefused("", with: .notAWordhoardExport)
        try expectRefused("[]", with: .notAWordhoardExport)
        try expectRefused("{\"schemaVersion\" : 1}", with: .notAWordhoardExport)
        try expectRefused(
            GoldenExport.text.replacingOccurrences(
                of: "\"id\" : \"00000000-0000-0000-0000-000000000002\",\n",
                with: ""
            ),
            with: .notAWordhoardExport
        )
        try expectRefused(
            replacing(
                "\"createdAt\" : \"2023-11-14T22:16:40.000Z\"",
                in: GoldenExport.text,
                with: "\"createdAt\" : \"yesterday\""
            ),
            with: .notAWordhoardExport
        )
    }

    @Test("an unknown enum value fails the whole import before any word is written")
    func anUnknownEnumValueFailsTheImportWithoutPartialWrites() throws {
        struct Edit {
            var fragment: String
            var edited: String
            var error: ImportError
        }
        let edits = [
            Edit(
                fragment: "\"partOfSpeech\" : \"other\"",
                edited: "\"partOfSpeech\" : \"determiner\"",
                error: .unknownValue(field: "partOfSpeech", value: "determiner")
            ),
            Edit(
                fragment: "\"senseSource\" : \"wordnet\"",
                edited: "\"senseSource\" : \"oracle\"",
                error: .unknownValue(field: "senseSource", value: "oracle")
            ),
            Edit(
                fragment: "\"source\" : \"user\"",
                edited: "\"source\" : \"magic\"",
                error: .unknownValue(field: "source", value: "magic")
            ),
            Edit(
                fragment: "\"definition\" : \"user\"",
                edited: "\"definition\" : \"robot\"",
                error: .unknownValue(field: "fieldSources", value: "robot")
            ),
        ]
        for edit in edits {
            try expectRefused(replacing(edit.fragment, in: GoldenExport.text, with: edit.edited), with: edit.error)
            #expect(try RowCounts(in: container).words == 0)
        }
        #expect(
            ImportError.unknownValue(field: "partOfSpeech", value: "determiner").errorDescription
                == "This file uses a value this version of Wordhoard doesn't recognize (partOfSpeech: determiner)."
        )
    }

    @Test("a duplicate word, sense, example or tag id in one file fails the import with nothing written")
    func duplicateIDsInOneFileFailTheImport() throws {
        let twice = TransferFixture.uuid(7)
        let twoSenses = makeWord(headword: "book", senses: [makeSense(id: twice), makeSense(id: twice, order: 1)])
        let documents = [
            makeDocument(words: [makeWord(id: twice, headword: "book"), makeWord(id: twice, headword: "apple")]),
            makeDocument(words: [twoSenses]),
            makeDocument(
                words: [makeWord(headword: "book")],
                tags: [ExportTag(id: twice, name: "a"), ExportTag(id: twice, name: "b")]
            ),
            makeDocument(words: [
                makeWord(headword: "book", senses: [makeSense(examples: [makeExample(id: twice)])]),
                makeWord(headword: "pen", senses: [makeSense(examples: [makeExample(id: twice)])]),
            ]),
        ]
        for document in documents {
            try expectRefused(document.encode(), with: .duplicateID(twice))
        }
        #expect(try RowCounts(in: container).words == 0)
        #expect(
            ImportError.duplicateID(twice).errorDescription
                == "This file lists the same item twice (\(twice.uuidString))."
        )
    }

    @Test("a failure on the last word leaves the earlier words, tags and settings unwritten")
    func aFailureAnywhereLeavesTheStoreUntouched() throws {
        let settingsBefore = try store.settings().activeGrammarTopics
        let document = makeDocument(
            words: [
                makeWord(headword: "book", tagIDs: [TransferFixture.uuid(100)]),
                makeWord(headword: "apple"),
                makeWord(headword: "pen", senses: [makeSense()]),
            ],
            tags: [ExportTag(id: TransferFixture.uuid(100), name: "reading")],
            settings: makeSettings(nativeLanguage: "es", activeGrammarTopics: [])
        )
        let text = try replacing(
            "\"partOfSpeech\" : \"noun\"",
            in: utf8(document.encode()),
            with: "\"partOfSpeech\" : \"interjection\""
        )

        try expectRefused(text, with: .unknownValue(field: "partOfSpeech", value: "interjection"))
        #expect(try RowCounts(in: container) == RowCounts(words: 0, senses: 0, examples: 0, tags: 0, settings: 1))
        #expect(try store.settings().nativeLanguage == nil)
        #expect(try store.settings().activeGrammarTopics == settingsBefore)
        #expect(try store.add("book").word.headword == "book", "the store still works after the rollback")
    }
}
