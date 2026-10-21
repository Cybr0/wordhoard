import Foundation
import Testing
import WordhoardCore

@MainActor
@Suite("WordListModel import")
struct WordListModelImportTests {
    let store: WordStore
    let model: WordListModel

    init() throws {
        store = try WordStore(container: WordhoardContainer.makeInMemory())
        model = WordListModel(store: store)
    }

    @Test("importing through the list model publishes the summary or the failure and re-reads the list")
    func importingThroughTheListModelPublishesTheSummaryOrTheFailure() {
        model.draft = "pen"
        _ = model.addDraft()
        #expect(model.words.map(\.headword) == ["pen"])

        model.importWords(GoldenExport.data)
        #expect(model.importSummary?.wordsCreated == 2)
        #expect(model.failure == nil)
        #expect(model.words.map(\.headword) == ["pen", "apple", "book"])

        model.importSummary = nil
        let newer = replacing("\"schemaVersion\" : 1", in: GoldenExport.text, with: "\"schemaVersion\" : 2")
        model.importWords(Data(newer.utf8))
        #expect(model.failure == .importing(.newerSchema(found: 2, supported: 1)))
        #expect(model.importSummary == nil)
        #expect(model.words.map(\.headword) == ["pen", "apple", "book"])
    }

    @Test("a failed import clears a summary left from an earlier one")
    func aFailedImportClearsAnEarlierSummary() {
        model.importWords(GoldenExport.data)
        #expect(model.importSummary != nil)

        model.importWords(Data("{".utf8))
        #expect(model.importSummary == nil)
        #expect(model.failure == .importing(.notAWordhoardExport))
    }
}
