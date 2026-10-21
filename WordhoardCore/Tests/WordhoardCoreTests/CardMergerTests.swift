import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `CardMerger` (issue #40): generated content fills `.auto` fields, never touches a `.user` field or a
/// hand-entered sense, and applies again without duplicating senses (A4, A7, W2). Example rules and
/// boundaries are in `CardMergerExampleTests`.
@MainActor
@Suite("CardMerger senses and fields")
struct CardMergerTests {
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

    // MARK: - Provenance (A4), written first

    @Test("regenerate keeps a user definition and refreshes auto fields")
    func regenerateKeepsAUserDefinitionAndRefreshesAutoFields() throws {
        let book = try filledBook()
        let (word, noun) = (book.word, book.noun)
        let model = WordCardModel(word: word, store: store)
        model.setDefinition("my own words", for: noun)

        _ = CardMerger.apply(bookWithNoun(definition: "new", synonyms: ["tome"]), to: word)
        try store.save(word)

        let stored = try storedWord(word.id, in: container)
        let storedNoun = try #require(stored.sortedSenses.first)
        #expect(stored.senses.count == 2)
        #expect(storedNoun.definition == "my own words")
        #expect(storedNoun.fieldSource(for: .definition) == .user)
        #expect(storedNoun.synonyms == ["tome"])
        #expect(storedNoun.fieldSource(for: .synonyms) == .auto)
        #expect(storedNoun.fieldSources == ["definition": .user])
        expectNoAutoMarks(stored)
    }

    @Test("each user field is protected independently")
    func eachUserFieldIsProtectedIndependently() throws {
        for field in SenseField.allCases {
            let book = try filledBook()
            let (word, noun) = (book.word, book.noun)
            let model = WordCardModel(word: word, store: store)
            switch field {
            case .definition: model.setDefinition("mine", for: noun)
            case .translation: model.setTranslation("моё", for: noun)
            case .synonyms: model.setSynonyms("mine", for: noun)
            case .antonyms: model.setAntonyms("mine", for: noun)
            }

            _ = CardMerger.apply(
                bookWithNoun(definition: "new", translation: "новое", synonyms: ["new"], antonyms: ["new"]),
                to: word
            )
            try store.save(word)

            let stored = try #require(try storedWord(word.id, in: container).sortedSenses.first)
            #expect(stored.fieldSources == [field.rawValue: .user])
            #expect(stored.definition == (field == .definition ? "mine" : "new"))
            #expect(stored.translation == (field == .translation ? "моё" : "новое"))
            #expect(stored.synonyms == (field == .synonyms ? ["mine"] : ["new"]))
            #expect(stored.antonyms == (field == .antonyms ? ["mine"] : ["new"]))
            try store.delete(word)
        }
    }

    @Test("applying the same card twice changes nothing")
    func applyingTheSameCardTwiceChangesNothing() throws {
        let book = try filledBook()
        let (word, noun, verb) = (book.word, book.noun, book.verb)
        let before = MergeSnapshot(word)

        _ = CardMerger.apply(StubFixtures.book, to: word)
        try store.save(word)
        #expect(MergeSnapshot(word) == before)

        CardMerger.apply(GeneratedExample(text: "I have booked.", grammarTopic: presentPerfectKey), to: verb)
        CardMerger.apply(GeneratedExample(text: "I have a book.", grammarTopic: presentPerfectKey), to: noun)
        try store.save(word)
        let withTopics = MergeSnapshot(word)
        _ = CardMerger.apply(StubFixtures.book, to: word)
        try store.save(word)

        let stored = try storedWord(word.id, in: container)
        #expect(MergeSnapshot(stored) == withTopics)
        #expect(stored.senses.count == 2)
        for sense in stored.sortedSenses {
            let examples = sense.sortedExamples
            #expect(examples.filter { $0.grammarTopic == nil }.count == 1)
            #expect(examples.filter { $0.grammarTopic == presentPerfectKey }.count == 1)
            #expect(examples.map(\.order) == Array(0 ..< examples.count))
        }
        expectNoAutoMarks(stored)
    }

    @Test("hand-entered senses are never matched or modified")
    func handEnteredSensesAreNeverMatchedOrModified() throws {
        let word = try store.add("book").word
        let hand = Sense(partOfSpeech: .verb, definition: "mine", order: 0)
        word.senses = [hand]
        try store.save(word)

        _ = CardMerger.apply(StubFixtures.book, to: word)
        try store.save(word)
        var stored = try storedWord(word.id, in: container)
        #expect(stored.sortedSenses.map(\.partOfSpeech) == [.verb, .noun, .verb])
        #expect(stored.sortedSenses.map(\.senseSource) == [nil, .wordnet, .wordnet])
        #expect(stored.sortedSenses.map(\.order) == [0, 1, 2])
        let storedHand = try #require(stored.sortedSenses.first)
        #expect(storedHand.id == hand.id)
        #expect(storedHand.definition == "mine")
        #expect(storedHand.gloss == nil)
        #expect(storedHand.examples.isEmpty)

        _ = CardMerger.apply(StubFixtures.book, to: word)
        try store.save(word)
        stored = try storedWord(word.id, in: container)
        #expect(stored.senses.count == 3)
        expectNoAutoMarks(stored)
    }

    // MARK: - Filling and matching

    @Test("applying a card to an empty word adds its senses")
    func applyingACardToAnEmptyWordAddsItsSenses() throws {
        let word = try store.add("book").word

        let ids = CardMerger.apply(StubFixtures.book, to: word)
        try store.save(word)

        #expect(ids == word.sortedSenses.map(\.id))
        let stored = try storedWord(word.id, in: container)
        let senses = stored.sortedSenses
        #expect(senses.map(\.partOfSpeech) == [.noun, .verb])
        #expect(senses.map(\.order) == [0, 1])
        #expect(senses.map(\.id) == ids)
        for (sense, generated) in zip(senses, StubFixtures.book.senses) {
            #expect(sense.senseSource == .wordnet)
            #expect(sense.gloss == generated.gloss)
            #expect(sense.definition == generated.definition)
            #expect(sense.translation == generated.translation)
            #expect(sense.synonyms == generated.synonyms)
            #expect(sense.antonyms == generated.antonyms)
            #expect(sense.fieldSources == [:])
            #expect(sense.examples.count == 1)
            let example = try #require(sense.sortedExamples.first)
            #expect(example.text == generated.neutralExample?.text)
            #expect(example.grammarTopic == nil)
            #expect(example.source == .auto)
            #expect(example.order == 0)
        }
    }

    @Test("empty generated values leave stored values alone")
    func emptyGeneratedValuesLeaveStoredValuesAlone() throws {
        let word = try filledBook().word

        _ = CardMerger.apply(bookWithNoun(definition: "", translation: nil, synonyms: [], antonyms: []), to: word)
        try store.save(word)

        let stored = try #require(try storedWord(word.id, in: container).sortedSenses.first)
        let generated = StubFixtures.book.senses[0]
        #expect(stored.definition == generated.definition)
        #expect(stored.translation == generated.translation)
        #expect(stored.synonyms == generated.synonyms)
        #expect(stored.fieldSources == [:])

        _ = CardMerger.apply(bookWithNoun(definition: "  \n", translation: " "), to: word)
        #expect(stored.definition == generated.definition, "blank counts as empty")
        #expect(word.sortedSenses.first?.translation == generated.translation)
    }

    @Test("WordNet senses match by gloss, not order")
    func wordNetSensesMatchByGlossNotOrder() throws {
        let book = try filledBook()
        let (word, noun, verb) = (book.word, book.noun, book.verb)
        let model = WordCardModel(word: word, store: store)
        model.moveSenses(fromOffsets: [1], toOffset: 0)
        #expect(word.sortedSenses.map(\.id) == [verb.id, noun.id])

        let ids = CardMerger.apply(bookWithNoun(definition: "fresh"), to: word)
        try store.save(word)

        #expect(ids == [noun.id, verb.id], "index-aligned with the card, not with the stored order")
        let stored = try storedWord(word.id, in: container)
        #expect(stored.sortedSenses.map(\.id) == [verb.id, noun.id])
        #expect(stored.sortedSenses.map(\.order) == [0, 1])
        #expect(stored.sortedSenses.last?.definition == "fresh")
        #expect(stored.senses.count == 2)
    }

    @Test("model senses match by part of speech in order")
    func modelSensesMatchByPartOfSpeechInOrder() throws {
        let word = try store.add("however").word
        _ = CardMerger.apply(StubFixtures.however, to: word)
        try store.save(word)

        var updated = StubFixtures.however
        updated.senses[0].definition = "nevertheless"
        _ = CardMerger.apply(updated, to: word)
        try store.save(word)
        var stored = try storedWord(word.id, in: container)
        #expect(stored.senses.count == 1)
        #expect(stored.sortedSenses.first?.definition == "nevertheless")
        #expect(stored.sortedSenses.first?.senseSource == .model)

        let two = GeneratedCard(
            headword: "however",
            path: .stoplist,
            senses: [modelAdverb("first"), modelAdverb("second")]
        )
        let ids = CardMerger.apply(two, to: word)
        try store.save(word)
        stored = try storedWord(word.id, in: container)
        #expect(stored.sortedSenses.map(\.definition) == ["first", "second"])
        #expect(stored.sortedSenses.map(\.order) == [0, 1])
        #expect(stored.sortedSenses.map(\.id) == ids)
        #expect(stored.sortedSenses.first?.examples.count == 1, "the neutral slot was replaced, not doubled")
    }

    @Test("a user-changed part of speech is kept and the sense is re-added")
    func aUserChangedPartOfSpeechIsKeptAndTheSenseIsReAdded() throws {
        let book = try filledBook()
        let (word, verb) = (book.word, book.verb)
        let model = WordCardModel(word: word, store: store)
        model.setPartOfSpeech(.adjective, for: verb)

        _ = CardMerger.apply(StubFixtures.book, to: word)
        try store.save(word)

        let stored = try storedWord(word.id, in: container)
        #expect(stored.sortedSenses.map(\.partOfSpeech) == [.noun, .adjective, .verb])
        #expect(stored.sortedSenses.map(\.order) == [0, 1, 2])
        #expect(stored.sortedSenses[1].id == verb.id)
        #expect(stored.sortedSenses[1].gloss == StubFixtures.book.senses[1].gloss)
    }

    @Test("not found leaves the word alone")
    func notFoundLeavesTheWordAlone() throws {
        let word = try store.add("asdfgh").word
        word.senses = [Sense(partOfSpeech: .other, definition: "mine", order: 0)]
        try store.save(word)
        let before = MergeSnapshot(word)

        #expect(CardMerger.apply(StubFixtures.asdfgh, to: word).isEmpty)
        try store.save(word)

        #expect(try MergeSnapshot(storedWord(word.id, in: container)) == before)
    }
}
