import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `Word.autofillState` (issue #39): the one schema addition of Phase 2, defaulted and CloudKit-safe.
@Suite("AutofillState")
struct AutofillStateTests {
    @Test("autofillState is stored with a pending default")
    func autofillStateIsStoredWithAPendingDefault() throws {
        #expect(Word(headword: "book").autofillState == .pending)
        #expect(AutofillState.allCases.map(\.rawValue) == ["pending", "filling", "ready", "failed", "unavailable"])

        let directory = FileManager.default.temporaryDirectory.appending(path: "wordhoard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Wordhoard.store")

        let id: UUID
        do {
            let first = try WordhoardContainer.makeOnDisk(url: url)
            let context = ModelContext(first)
            let word = Word(headword: "book")
            word.autofillState = .failed
            context.insert(word)
            context.insert(Word(headword: "apple"))
            try context.save()
            id = word.id
        }

        let second = try WordhoardContainer.makeOnDisk(url: url)
        let words = try ModelContext(second).fetch(FetchDescriptor<Word>(sortBy: [SortDescriptor(\.headword)]))
        #expect(words.map(\.autofillState) == [.pending, .failed])
        #expect(words.last?.id == id)
    }
}
