import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("deleting a sense directly removes its examples and keeps the word")
func deletingASenseDirectlyRemovesItsExamplesAndKeepsTheWord() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = try insertBookFixture(into: context)
    let noun = try #require(word.senses.first { $0.partOfSpeech == .noun })

    context.delete(noun)
    try context.save()

    let fresh = ModelContext(container)
    #expect(try fresh.fetchCount(FetchDescriptor<Word>()) == 1)
    #expect(try fresh.fetchCount(FetchDescriptor<Sense>()) == 1)
    #expect(try fresh.fetchCount(FetchDescriptor<Example>()) == 1)
    let remaining = try #require(try fresh.fetch(FetchDescriptor<Word>()).first)
    #expect(remaining.sortedSenses.map(\.partOfSpeech) == [.verb])
}

@Test("deleting an image asset directly clears the word's image")
func deletingAnImageAssetDirectlyClearsTheWordsImage() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = try insertBookFixture(into: context)
    let image = try #require(word.image)

    context.delete(image)
    try context.save()

    let fresh = ModelContext(container)
    let fetched = try #require(try fresh.fetch(FetchDescriptor<Word>()).first)
    #expect(fetched.image == nil)
    #expect(try fresh.fetchCount(FetchDescriptor<ImageAsset>()) == 0)
}

@Test("deleting a tag directly detaches it from the word and keeps the word")
func deletingATagDirectlyDetachesItFromTheWordAndKeepsTheWord() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = try insertBookFixture(into: context)
    let tag = try #require(word.tags.first)

    context.delete(tag)
    try context.save()

    let fresh = ModelContext(container)
    let fetched = try #require(try fresh.fetch(FetchDescriptor<Word>()).first)
    #expect(fetched.tags.isEmpty)
    #expect(try fresh.fetchCount(FetchDescriptor<WordhoardCore.Tag>()) == 0)
    #expect(fetched.senses.count == 2)
}

@Test("a sense and example attached from the inverse side appear on the word")
func senseAndExampleAttachedFromTheInverseSideAppearOnTheWord() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = Word(headword: "inverse")
    context.insert(word)
    let sense = Sense(partOfSpeech: .noun)
    context.insert(sense)
    sense.word = word
    let example = Example(text: "An inverse example.", source: .user)
    context.insert(example)
    example.sense = sense
    try context.save()

    let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<Word>()).first)
    #expect(fetched.senses.count == 1)
    #expect(fetched.senses.first?.examples.map(\.text) == ["An inverse example."])
}
