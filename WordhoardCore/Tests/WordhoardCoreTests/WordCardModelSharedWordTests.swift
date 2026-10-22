import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Two cards for the same word on one stack (card → badge → topic → that word's example): two
/// `WordCardModel`s on one `Word`. A sense the upper card removes is hard-deleted behind the lower
/// model's back, and touching its attributes is a SwiftData fatal error, so every late call on it must
/// be a no-op whether or not the lower card has reloaded.
@MainActor
@Suite("WordCardModel: two cards on one word")
struct WordCardModelSharedWordTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    /// `book` with the senses `a`, `b`, `c`, each with one example.
    private func makeBook() throws -> Word {
        let word = try store.add("book").word
        word.senses = ["a", "b", "c"].enumerated().map { offset, definition in
            let sense = Sense(partOfSpeech: .noun, definition: definition, order: offset)
            sense.examples = [Example(text: "\(definition) one", source: .auto, order: 0)]
            return sense
        }
        try store.save(word)
        return word
    }

    private func storedSenses() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<Sense>(sortBy: [SortDescriptor(\.order)]))
            .map { "\($0.definition):\($0.order)" }
    }

    private func storedExamples() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<Example>()).map(\.text).sorted()
    }

    /// Every call the card can make for a sense or its example, as a late commit would.
    private func commitEverything(on model: WordCardModel, sense: Sense, example: Example) {
        model.setDefinition("late", for: sense)
        model.setTranslation("late", for: sense)
        model.setSynonyms("late", for: sense)
        model.setAntonyms("late", for: sense)
        model.setPartOfSpeech(.verb, for: sense)
        model.setExampleText("late", for: example)
        model.moveExamples(in: sense, fromOffsets: [0], toOffset: 1)
        model.removeExample(example)
        model.addExample(to: sense)
        model.removeSense(sense)
    }

    @Test("after reloading, a card no longer lists a sense the other card removed, and late commits on it do nothing")
    func reloadingDropsASenseTheOtherCardRemoved() throws {
        let word = try makeBook()
        let lower = WordCardModel(word: word, store: store)
        let upper = WordCardModel(word: word, store: store)
        let doomed = lower.senses[1]
        let doomedExample = try #require(doomed.examples.first)

        upper.removeSense(upper.senses[1])
        lower.reloadSenses()

        #expect(lower.senses.map(\.definition) == ["a", "c"])
        commitEverything(on: lower, sense: doomed, example: doomedExample)
        #expect(lower.failure == nil)
        #expect(try storedSenses() == ["a:0", "c:1"])
        #expect(try storedExamples() == ["a one", "c one"])
    }

    @Test("without reloading, late commits on a sense the other card removed do nothing and do not crash")
    func lateCommitsWithoutReloadDoNothing() throws {
        let word = try makeBook()
        let lower = WordCardModel(word: word, store: store)
        let upper = WordCardModel(word: word, store: store)
        let doomed = lower.senses[1]
        let doomedExample = try #require(doomed.examples.first)

        upper.removeSense(upper.senses[1])

        commitEverything(on: lower, sense: doomed, example: doomedExample)
        lower.moveSenses(fromOffsets: [2], toOffset: 0)
        lower.addSense()
        #expect(lower.failure == nil)
        #expect(lower.senses.map(\.definition) == ["a", "c", ""])
        #expect(try storedSenses() == ["a:0", "c:1", ":2"])
        #expect(try storedExamples() == ["a one", "c one"])
    }

    @Test("after the other card deletes the word, every edit on this card does nothing")
    func editsAfterTheOtherCardDeletedTheWordDoNothing() throws {
        let word = try makeBook()
        let lower = WordCardModel(word: word, store: store)
        let sense = lower.senses[1]
        let example = try #require(sense.examples.first)

        try store.delete(word)
        let deletedAt = try #require(word.deletedAt)
        let updatedAt = word.updatedAt
        #expect(lower.isWordDeleted)

        commitEverything(on: lower, sense: sense, example: example)
        lower.moveSenses(fromOffsets: [2], toOffset: 0)
        lower.addSense()
        #expect(lower.setHeadword("notebook") == nil)
        #expect(lower.deleteWord(), "deleting again stays idempotent")

        #expect(lower.failure == nil)
        #expect(word.headword == "book")
        #expect(word.deletedAt == deletedAt)
        #expect(word.updatedAt == updatedAt, "nothing was saved")
        #expect(lower.senses.map(\.definition) == ["a", "b", "c"])
        #expect(sense.definition == "b")
        #expect(sense.translation == nil)
        #expect(sense.synonyms.isEmpty)
        #expect(sense.antonyms.isEmpty)
        #expect(sense.partOfSpeech == .noun)
        #expect(sense.fieldSources.isEmpty)
        #expect(example.text == "b one")
        #expect(example.source == .auto)
        #expect(try storedSenses() == ["a:0", "b:1", "c:2"])
        #expect(try storedExamples() == ["a one", "b one", "c one"])
    }
}
