import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Adding, removing and reordering senses and examples on `WordCardModel` (W2, §5 `order`).
@MainActor
@Suite("WordCardModel senses and examples")
struct WordCardModelStructureTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func fresh() -> ModelContext {
        ModelContext(container)
    }

    /// `book` with one unmarked noun sense, saved.
    private func makeBook() throws -> (Word, Sense) {
        let word = try store.add("book").word
        let sense = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
        word.senses = [sense]
        try store.save(word)
        return (word, sense)
    }

    /// `book` with the senses `a`, `b`, `c` in that order; `b` has two examples.
    private func makeBookWithThreeSenses() throws -> (Word, [Sense]) {
        let word = try store.add("book").word
        let senses = ["a", "b", "c"].enumerated().map { offset, definition in
            Sense(partOfSpeech: .noun, definition: definition, order: offset)
        }
        word.senses = senses
        senses[1].examples = [
            Example(text: "b one", source: .auto, order: 0),
            Example(text: "b two", source: .auto, order: 1),
        ]
        try store.save(word)
        return (word, word.sortedSenses)
    }

    private func storedSense(_ id: UUID) throws -> Sense? {
        try fresh().fetch(FetchDescriptor<Sense>(predicate: #Predicate { $0.id == id })).first
    }

    private func storedExample(_ id: UUID) throws -> Example? {
        try fresh().fetch(FetchDescriptor<Example>(predicate: #Predicate { $0.id == id })).first
    }

    private func storedWord(_ id: UUID) throws -> Word? {
        try fresh().fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })).first
    }

    private func model(for word: Word) -> WordCardModel {
        WordCardModel(word: word, store: store)
    }

    // MARK: - Senses

    @Test("adding a sense appends an unmarked hand-entered sense that is marked only where typed into")
    func addingASenseAppendsAnUnmarkedHandEnteredSense() throws {
        let word = try store.add("book").word
        word.senses = [
            Sense(partOfSpeech: .noun, definition: "a", order: 0),
            Sense(partOfSpeech: .verb, definition: "b", order: 1),
        ]
        try store.save(word)
        let model = model(for: word)
        let savedAt = word.updatedAt

        let added = model.addSense()

        #expect(model.senses.count == 3)
        #expect(model.senses.last?.id == added.id)
        #expect(added.order == 2)
        #expect(added.partOfSpeech == .other)
        #expect(added.senseSource == nil)
        #expect(added.definition == "")
        #expect(added.translation == nil)
        #expect(added.synonyms.isEmpty)
        #expect(added.examples.isEmpty)
        #expect(added.fieldSources.isEmpty)
        #expect(word.updatedAt > savedAt)
        let stored = try #require(try storedSense(added.id))
        #expect(stored.order == 2)
        #expect(stored.partOfSpeech == .other)
        #expect(stored.fieldSources.isEmpty)

        model.setDefinition("x", for: added)
        #expect(added.fieldSources == [SenseField.definition.rawValue: .user])
        #expect(try storedSense(added.id)?.definition == "x")
        #expect(try storedWord(word.id)?.sortedSenses.map(\.definition) == ["a", "b", "x"])
    }

    @Test("removing a sense hard-deletes it with its examples and renumbers the rest")
    func removingASenseDeletesItAndRenumbersTheRest() throws {
        let (word, senses) = try makeBookWithThreeSenses()
        let removedID = senses[1].id
        let exampleIDs = senses[1].examples.map(\.id)
        let savedAt = word.updatedAt
        let model = model(for: word)

        model.removeSense(senses[1])

        #expect(model.senses.map(\.definition) == ["a", "c"])
        #expect(model.senses.map(\.order) == [0, 1])
        #expect(word.updatedAt > savedAt)
        #expect(model.failure == nil)
        let context = fresh()
        #expect(try context.fetchCount(FetchDescriptor<Sense>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Sense>(predicate: #Predicate { $0.id == removedID })) == 0)
        for id in exampleIDs {
            #expect(try context.fetchCount(FetchDescriptor<Example>(predicate: #Predicate { $0.id == id })) == 0)
        }
        let stored = try #require(try storedWord(word.id))
        #expect(stored.sortedSenses.map(\.definition) == ["a", "c"])
        #expect(stored.sortedSenses.map(\.order) == [0, 1])
    }

    @Test("removing the last sense leaves an empty, still active card")
    func removingTheLastSenseLeavesAnEmptyCard() throws {
        let (word, sense) = try makeBook()
        let model = model(for: word)

        model.removeSense(sense)

        #expect(model.senses.isEmpty)
        #expect(word.deletedAt == nil)
        #expect(try store.search("book").map(\.id) == [word.id])
        #expect(try storedWord(word.id)?.senses.isEmpty == true)
    }

    @Test("moving a sense updates order for every sense and a fresh context agrees")
    func movingASenseUpdatesOrderForEverySense() throws {
        let (word, _) = try makeBookWithThreeSenses()
        let model = model(for: word)
        let savedAt = word.updatedAt

        model.moveSenses(fromOffsets: [2], toOffset: 0)

        #expect(model.senses.map(\.definition) == ["c", "a", "b"])
        #expect(model.senses.map(\.order) == [0, 1, 2])
        #expect(word.updatedAt > savedAt)
        #expect(try storedWord(word.id)?.sortedSenses.map(\.definition) == ["c", "a", "b"])

        let movedAt = word.updatedAt
        model.moveSenses(fromOffsets: [1], toOffset: 1)
        #expect(model.senses.map(\.definition) == ["c", "a", "b"])
        #expect(word.updatedAt == movedAt, "a move that changes nothing saves nothing")

        model.moveSenses(fromOffsets: [0], toOffset: 2)
        #expect(model.senses.map(\.definition) == ["a", "c", "b"])
        #expect(try storedWord(word.id)?.sortedSenses.map(\.definition) == ["a", "c", "b"])
    }

    // MARK: - Examples

    @Test("adding an example appends a .user example without a topic")
    func addingAnExampleAppendsAUserExample() throws {
        let (word, senses) = try makeBookWithThreeSenses()
        let model = model(for: word)
        let savedAt = word.updatedAt

        let added = model.addExample(to: senses[1])

        #expect(senses[1].sortedExamples.map(\.text) == ["b one", "b two", ""])
        #expect(senses[1].sortedExamples.last?.id == added.id)
        #expect(added.order == 2)
        #expect(added.source == .user)
        #expect(added.grammarTopic == nil)
        #expect(added.text == "")
        #expect(word.updatedAt > savedAt)
        let stored = try #require(try storedExample(added.id))
        #expect(stored.order == 2)
        #expect(stored.source == .user)
        #expect(stored.sense?.id == senses[1].id)

        let onEmptySense = model.addExample(to: senses[0])
        #expect(onEmptySense.order == 0)
        #expect(try storedExample(onEmptySense.id)?.sense?.id == senses[0].id)
    }

    @Test("removing an example deletes it and renumbers the sense's remaining examples")
    func removingAnExampleDeletesItAndRenumbers() throws {
        let (word, senses) = try makeBookWithThreeSenses()
        let sense = senses[1]
        let third = Example(text: "b three", source: .auto, order: 2)
        sense.examples.append(third)
        try store.save(word)
        let removed = sense.sortedExamples[0]
        let removedID = removed.id
        let savedAt = word.updatedAt
        let model = model(for: word)

        model.removeExample(removed)

        #expect(sense.sortedExamples.map(\.text) == ["b two", "b three"])
        #expect(sense.sortedExamples.map(\.order) == [0, 1])
        #expect(word.updatedAt > savedAt)
        let context = fresh()
        #expect(try context.fetchCount(FetchDescriptor<Example>(predicate: #Predicate { $0.id == removedID })) == 0)
        let stored = try #require(try storedSense(sense.id))
        #expect(stored.sortedExamples.map(\.text) == ["b two", "b three"])
        #expect(stored.sortedExamples.map(\.order) == [0, 1])
    }

    @Test("moving an example updates order and a fresh context agrees")
    func movingAnExampleUpdatesOrder() throws {
        let (word, senses) = try makeBookWithThreeSenses()
        let sense = senses[1]
        sense.examples.append(Example(text: "b three", source: .auto, order: 2))
        try store.save(word)
        let model = model(for: word)

        model.moveExamples(in: sense, fromOffsets: [2], toOffset: 0)

        #expect(sense.sortedExamples.map(\.text) == ["b three", "b one", "b two"])
        #expect(sense.sortedExamples.map(\.order) == [0, 1, 2])
        #expect(try storedSense(sense.id)?.sortedExamples.map(\.text) == ["b three", "b one", "b two"])
    }

    // MARK: - Shape

    @Test("the model republishes the word's senses in order on creation")
    func modelPublishesSensesInOrder() throws {
        let (word, senses) = try makeBookWithThreeSenses()
        let model = model(for: word)
        #expect(model.word === word)
        #expect(model.senses.map(\.id) == senses.map(\.id))
        #expect(model.failure == nil)
        #expect(model.headwordRejection == nil)
    }
}
