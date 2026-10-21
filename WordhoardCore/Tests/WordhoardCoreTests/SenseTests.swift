import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("a WordNet sense keeps its source, gloss and field sources")
func wordnetSenseKeepsItsSourceGlossAndFieldSources() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = Word(headword: "book")
    context.insert(word)
    word.senses = [
        Sense(
            partOfSpeech: .noun,
            definition: "a written work",
            senseSource: .wordnet,
            gloss: "a written work or composition that has been published",
            fieldSources: ["definition": .user]
        ),
    ]
    try context.save()

    let senses = try ModelContext(container).fetch(FetchDescriptor<Sense>())
    let sense = try #require(senses.first)
    #expect(senses.count == 1)
    #expect(sense.senseSource == .wordnet)
    #expect(sense.gloss == "a written work or composition that has been published")
    #expect(sense.fieldSources == ["definition": .user])
    #expect(sense.fieldSource(for: .definition) == .user)
}

@Test("a hand-entered sense has no source and no field sources")
func handEnteredSenseHasNoSourceAndNoFieldSources() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = Word(headword: "book")
    context.insert(word)
    word.senses = [Sense(partOfSpeech: .verb, definition: "to reserve")]
    try context.save()

    let sense = try #require(try ModelContext(container).fetch(FetchDescriptor<Sense>()).first)
    #expect(sense.senseSource == nil)
    #expect(sense.gloss == nil)
    #expect(sense.fieldSources == [:])
}

@Test("a missing field source means auto")
func missingFieldSourceMeansAuto() {
    let sense = Sense(partOfSpeech: .noun, fieldSources: ["definition": .user])
    #expect(sense.fieldSource(for: .definition) == .user)
    #expect(sense.fieldSource(for: .translation) == .auto)
    #expect(sense.fieldSource(for: .synonyms) == .auto)
    #expect(sense.fieldSource(for: .antonyms) == .auto)
}

@Test("an example keeps its topic key without validation")
func exampleKeepsItsTopicKeyWithoutValidation() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = Word(headword: "book")
    context.insert(word)
    let sense = Sense(partOfSpeech: .noun)
    word.senses = [sense]
    sense.examples = [
        Example(text: "I have read this book.", source: .auto, grammarTopic: "en.present_perfect", order: 0),
        Example(text: "The book is red.", source: .user, grammarTopic: nil, order: 1),
    ]
    try context.save()

    let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<Sense>()).first)
    let examples = fetched.sortedExamples
    #expect(examples.map(\.grammarTopic) == ["en.present_perfect", nil])
    #expect(examples.map(\.source) == [.auto, .user])
}
