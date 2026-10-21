import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Inserts the "book" fixture from issue #26 into `context` and saves: two senses (noun, verb), three
/// examples (two on the noun, one on the verb), one tag and one generated image.
@discardableResult
func insertBookFixture(into context: ModelContext) throws -> Word {
    let word = Word(headword: "book")
    context.insert(word)

    let noun = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
    let verb = Sense(partOfSpeech: .verb, definition: "to reserve", order: 1)
    word.senses = [noun, verb]

    noun.examples = [
        Example(text: "She read a book.", source: .auto, order: 0),
        Example(text: "The book is on the table.", source: .auto, order: 1),
    ]
    verb.examples = [
        Example(text: "I booked a table for two.", source: .auto, order: 0),
    ]

    let tag = WordhoardCore.Tag(name: "reading")
    word.tags = [tag]

    word.image = ImageAsset(fileName: "book.heic", source: .generated)

    try context.save()
    return word
}

/// Asserts that `context` holds exactly the fixture written by `insertBookFixture(into:)`.
func expectBookFixture(in context: ModelContext, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let words = try context.fetch(FetchDescriptor<Word>())
    #expect(words.count == 1, sourceLocation: sourceLocation)
    let word = try #require(words.first, sourceLocation: sourceLocation)
    #expect(word.headword == "book", sourceLocation: sourceLocation)

    let senses = word.sortedSenses
    #expect(senses.count == 2, sourceLocation: sourceLocation)
    #expect(senses.map(\.partOfSpeech) == [.noun, .verb], sourceLocation: sourceLocation)
    #expect(senses.map(\.definition) == ["a written work", "to reserve"], sourceLocation: sourceLocation)

    let nounExamples = senses.first?.sortedExamples.map(\.text) ?? []
    let verbExamples = senses.last?.sortedExamples.map(\.text) ?? []
    #expect(nounExamples == ["She read a book.", "The book is on the table."], sourceLocation: sourceLocation)
    #expect(verbExamples == ["I booked a table for two."], sourceLocation: sourceLocation)
    #expect(try context.fetchCount(FetchDescriptor<Example>()) == 3, sourceLocation: sourceLocation)

    #expect(word.tags.map(\.name) == ["reading"], sourceLocation: sourceLocation)
    #expect(word.image?.fileName == "book.heic", sourceLocation: sourceLocation)
    #expect(word.image?.source == .generated, sourceLocation: sourceLocation)
}
