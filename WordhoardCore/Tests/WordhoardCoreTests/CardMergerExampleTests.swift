import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `CardMerger` example rules (slot replacement, duplicates, topic routing) and boundaries (issue #40).
@MainActor
@Suite("CardMerger examples and boundaries")
struct CardMergerExampleTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    /// `book` filled from the fixture and saved.
    private func filledBook() throws -> FilledBook {
        try FilledBook(store: store)
    }

    // MARK: - Examples

    @Test("auto examples are replaced in place and user examples kept")
    func autoExamplesAreReplacedInPlaceAndUserExamplesKept() throws {
        let book = try filledBook()
        let (word, noun, verb) = (book.word, book.noun, book.verb)
        let autoExample = try #require(noun.sortedExamples.first)
        #expect(autoExample.source == .auto)

        CardMerger.apply(GeneratedExample(text: "B", grammarTopic: nil), to: noun)
        try store.save(word)
        #expect(noun.examples.count == 1)
        #expect(noun.sortedExamples.first?.id == autoExample.id)
        #expect(noun.sortedExamples.first?.text == "B")
        #expect(noun.sortedExamples.first?.source == .auto)

        let model = WordCardModel(word: word, store: store)
        let userExample = try #require(verb.sortedExamples.first)
        model.setExampleText("A", for: userExample)
        CardMerger.apply(GeneratedExample(text: "B", grammarTopic: nil), to: verb)
        try store.save(word)

        let stored = try #require(try storedWord(word.id, in: container).sortedSenses.last)
        let examples = stored.sortedExamples
        #expect(examples.map(\.text) == ["A", "B"])
        #expect(examples.map(\.source) == [.user, .auto])
        #expect(examples.map(\.order) == [0, 1])
        #expect(examples.first?.id == userExample.id)
    }

    @Test("duplicate text is not appended")
    func duplicateTextIsNotAppended() throws {
        let book = try filledBook()
        let (word, verb) = (book.word, book.verb)
        let model = WordCardModel(word: word, store: store)
        let userExample = try #require(verb.sortedExamples.first)
        model.setExampleText("A", for: userExample)

        CardMerger.apply(GeneratedExample(text: " a  ", grammarTopic: nil), to: verb)
        try store.save(word)

        let stored = try #require(try storedWord(word.id, in: container).sortedSenses.last)
        #expect(stored.examples.count == 1)
        #expect(stored.sortedExamples.first?.text == "A")
        #expect(stored.sortedExamples.first?.source == .user)
    }

    @Test("topic examples fill their slot once")
    func topicExamplesFillTheirSlotOnce() throws {
        let book = try filledBook()
        let (word, verb) = (book.word, book.verb)

        CardMerger.apply(GeneratedExample(text: "Have you booked?", grammarTopic: presentPerfectKey), to: verb)
        try store.save(word)
        var examples = verb.sortedExamples
        #expect(examples.map(\.grammarTopic) == [nil, presentPerfectKey])
        #expect(examples.last?.source == .auto)
        #expect(examples.last?.order == 1)
        let topicExample = try #require(examples.last)

        CardMerger.apply(GeneratedExample(text: "I have booked a room.", grammarTopic: presentPerfectKey), to: verb)
        try store.save(word)
        examples = verb.sortedExamples
        #expect(examples.count == 2)
        #expect(examples.last?.id == topicExample.id)
        #expect(examples.last?.text == "I have booked a room.")

        let model = WordCardModel(word: word, store: store)
        model.setExampleText("We have booked twice.", for: topicExample)
        CardMerger.apply(GeneratedExample(text: "She has booked.", grammarTopic: presentPerfectKey), to: verb)
        try store.save(word)

        let stored = try #require(try storedWord(word.id, in: container).sortedSenses.last)
        #expect(stored.sortedExamples.map(\.text) == [
            StubFixtures.book.senses[1].neutralExample?.text ?? "",
            "We have booked twice.",
            "She has booked.",
        ])
        #expect(stored.sortedExamples.map(\.source) == [.auto, .user, .auto])
        #expect(stored.sortedExamples.map(\.order) == [0, 1, 2])
    }

    // MARK: - Boundaries

    @Test("the merger never touches word-level fields")
    func theMergerNeverTouchesWordLevelFields() throws {
        let word = try store.add("apple").word
        let (headword, normalized, state, updatedAt, deletedAt) =
            (word.headword, word.normalized, word.autofillState, word.updatedAt, word.deletedAt)

        _ = CardMerger.apply(StubFixtures.book, to: word)

        #expect(word.headword == headword, "card.headword is ignored")
        #expect(word.normalized == normalized)
        #expect(word.autofillState == state)
        #expect(word.updatedAt == updatedAt)
        #expect(word.deletedAt == deletedAt)
        #expect(word.senses.count == 2)
    }

    @Test("the merger never writes provenance")
    func theMergerNeverWritesProvenance() throws {
        let book = try filledBook()
        let (word, noun, verb) = (book.word, book.noun, book.verb)
        let model = WordCardModel(word: word, store: store)
        model.setAntonyms("none", for: verb)

        _ = CardMerger.apply(bookWithNoun(definition: "again"), to: word)
        CardMerger.apply(GeneratedExample(text: "Topic.", grammarTopic: presentPerfectKey), to: noun)
        try store.save(word)

        let stored = try storedWord(word.id, in: container)
        #expect(stored.sortedSenses.map(\.fieldSources) == [[:], ["antonyms": .user]])
        expectNoAutoMarks(stored)
    }
}
