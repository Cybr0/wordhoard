import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("two in-memory containers do not share data")
func twoInMemoryContainersDoNotShareData() throws {
    let first = try WordhoardContainer.makeInMemory()
    let second = try WordhoardContainer.makeInMemory()
    let context = ModelContext(first)
    context.insert(Word(headword: "only in the first store"))
    try context.save()

    #expect(try ModelContext(first).fetchCount(FetchDescriptor<Word>()) == 1)
    #expect(try ModelContext(second).fetchCount(FetchDescriptor<Word>()) == 0)
}
