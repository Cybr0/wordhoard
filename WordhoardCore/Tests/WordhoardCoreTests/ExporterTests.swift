import Foundation
import SwiftData
import Testing
import WordhoardCore

@MainActor
@Suite("Exporter")
struct ExporterTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func export() throws -> Data {
        try Exporter.export(from: store, exportedAt: TransferFixture.exportedAt, appVersion: TransferFixture.appVersion)
    }

    @Test("the fixture exports byte for byte as the golden text")
    func exportMatchesTheGoldenFixture() throws {
        try TransferFixture.insert(into: container)

        let data = try export()
        #expect(try utf8(data) == GoldenExport.text)
        #expect(data == GoldenExport.data)
        #expect(try export() == data, "two exports of the same hoard are identical")
    }

    @Test("soft-deleted words and the tags that hang only on them are left out")
    func deletedWordsAndTheirOnlyTagsAreLeftOut() throws {
        let book = try insertBookFixture(into: ModelContext(container))
        _ = try store.add("apple")
        try store.delete(#require(try store.word(id: book.id)))

        let document = try Exporter.document(
            from: store,
            exportedAt: TransferFixture.exportedAt,
            appVersion: TransferFixture.appVersion
        )
        #expect(document.words.map(\.headword) == ["apple"])
        #expect(document.tags.isEmpty)

        let fresh = try WordhoardContainer.makeInMemory()
        _ = try Importer.import(document.encode(), into: WordStore(container: fresh))
        #expect(try WordStore(container: fresh).words().map(\.headword) == ["apple"])
        #expect(try RowCounts(in: fresh).tags == 0)
        #expect(try RowCounts(in: fresh).words == 1)
    }

    @Test("the file name carries the local date")
    func fileNameUsesTheLocalDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        #expect(try Exporter
            .fileName(for: date, timeZone: #require(TimeZone(identifier: "UTC"))) == "Wordhoard-2023-11-14.json")
        #expect(try Exporter
            .fileName(for: date, timeZone: #require(TimeZone(identifier: "Asia/Tokyo"))) == "Wordhoard-2023-11-15.json")
    }
}
