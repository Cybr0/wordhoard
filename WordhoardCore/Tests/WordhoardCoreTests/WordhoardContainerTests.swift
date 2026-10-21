import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("container schema lists all seven models")
func containerSchemaListsAllSevenModels() throws {
    let container = try WordhoardContainer.makeInMemory()
    let names = Set(container.schema.entities.map(\.name))
    #expect(names == ["Word", "Sense", "Example", "Tag", "ImageAsset", "ReviewEvent", "UserSettings"])
    #expect(container.schema.entities.count == 7)
}

@Test("a word with senses and examples round-trips through a fresh context")
func wordWithSensesAndExamplesRoundTrips() throws {
    let container = try WordhoardContainer.makeInMemory()
    try insertBookFixture(into: ModelContext(container))
    try expectBookFixture(in: ModelContext(container))
}

@Test("an on-disk store survives being closed and reopened")
func onDiskStoreSurvivesReopen() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "wordhoard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Wordhoard.store")

    do {
        let first = try WordhoardContainer.makeOnDisk(url: url)
        try insertBookFixture(into: ModelContext(first))
    }

    let second = try WordhoardContainer.makeOnDisk(url: url)
    try expectBookFixture(in: ModelContext(second))
}

@Test("hard-deleting a word removes its senses, examples and image but not tags")
func hardDeletingAWordRemovesItsSensesExamplesAndImageButNotTags() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = try insertBookFixture(into: context)

    context.delete(word)
    try context.save()

    let fresh = ModelContext(container)
    #expect(try fresh.fetchCount(FetchDescriptor<Word>()) == 0)
    #expect(try fresh.fetchCount(FetchDescriptor<Sense>()) == 0)
    #expect(try fresh.fetchCount(FetchDescriptor<Example>()) == 0)
    #expect(try fresh.fetchCount(FetchDescriptor<ImageAsset>()) == 0)
    #expect(try fresh.fetchCount(FetchDescriptor<WordhoardCore.Tag>()) == 1)
}

@Test("a review event is storable although nothing in v1 writes it")
func reviewEventIsStorableButUnused() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let senseID = UUID()
    context.insert(ReviewEvent(senseID: senseID, rating: 3, direction: .wordToMeaning))
    try context.save()

    let events = try ModelContext(container).fetch(FetchDescriptor<ReviewEvent>())
    #expect(events.count == 1)
    #expect(events.first?.senseID == senseID)
    #expect(events.first?.rating == 3)
    #expect(events.first?.direction == .wordToMeaning)
}
