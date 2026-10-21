import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Edge cases around `WordCardModel` that #34 implies but does not spell out: marks on unchanged and
/// cleared values, whitespace-only and long text, the order of a list field, stale move offsets, and
/// commits that land after the thing they target was removed or deleted.
@MainActor
@Suite("WordCardModel edge cases")
struct WordCardModelEdgeCaseTests {
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

    /// `book` with the senses `a`, `b`, `c` in that order.
    private func makeBookWithThreeSenses() throws -> Word {
        let word = try store.add("book").word
        word.senses = ["a", "b", "c"].enumerated().map { offset, definition in
            Sense(partOfSpeech: .noun, definition: definition, order: offset)
        }
        try store.save(word)
        return word
    }

    /// `book` with the senses `a`, `b`, `c` in that order; `b` has two examples.
    private func makeBookWithThreeSensesAndExamples() throws -> (Word, [Sense]) {
        let word = try makeBookWithThreeSenses()
        let middle = try #require(word.sortedSenses.first { $0.definition == "b" })
        middle.examples = [
            Example(text: "b one", source: .auto, order: 0),
            Example(text: "b two", source: .auto, order: 1),
        ]
        try store.save(word)
        return (word, word.sortedSenses)
    }

    private func storedSense(_ id: UUID) throws -> Sense? {
        try fresh().fetch(FetchDescriptor<Sense>(predicate: #Predicate { $0.id == id })).first
    }

    private func storedWord(_ id: UUID) throws -> Word? {
        try fresh().fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: - Provenance (A4)

    @Test("committing a value equal to the stored one leaves existing marks exactly as they were")
    func sameValueLeavesExistingMarksUntouched() throws {
        let (word, sense) = try makeBook()
        sense.translation = "книга"
        sense.synonyms = ["a", "b"]
        sense.fieldSources = [SenseField.definition.rawValue: .user, SenseField.translation.rawValue: .auto]
        try store.save(word)
        let marks = sense.fieldSources
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setDefinition("a written work", for: sense)
        model.setTranslation("книга", for: sense)
        model.setSynonyms("a, b", for: sense)
        model.setAntonyms(" , ", for: sense)

        #expect(sense.fieldSources == marks, "a .user stays .user, an explicit .auto stays .auto, no key is added")
        #expect(word.updatedAt == savedAt)
        #expect(try storedSense(sense.id)?.fieldSources == marks)
    }

    @Test("clearing a .user field keeps it .user")
    func clearingAUserFieldKeepsItUser() throws {
        let (word, sense) = try makeBook()
        sense.translation = "книга"
        sense.synonyms = ["a"]
        sense.fieldSources = [
            SenseField.definition.rawValue: .user,
            SenseField.translation.rawValue: .user,
            SenseField.synonyms.rawValue: .user,
        ]
        try store.save(word)
        let model = WordCardModel(word: word, store: store)

        model.setDefinition("", for: sense)
        model.setTranslation("", for: sense)
        model.setSynonyms("", for: sense)

        #expect(sense.definition == "")
        #expect(sense.translation == nil)
        #expect(sense.synonyms == [])
        for field in [SenseField.definition, .translation, .synonyms] {
            #expect(sense.fieldSource(for: field) == .user, "\(field)")
        }
        let stored = try #require(try storedSense(sense.id))
        #expect(stored.definition == "")
        #expect(stored.fieldSource(for: .definition) == .user)
        #expect(stored.fieldSource(for: .synonyms) == .user)
    }

    @Test("whitespace-only and very long text are stored verbatim and marked .user")
    func whitespaceOnlyAndLongTextAreStoredVerbatim() throws {
        let (word, sense) = try makeBook()
        let example = Example(text: "She read a book.", source: .auto, order: 0)
        sense.examples = [example]
        try store.save(word)
        let model = WordCardModel(word: word, store: store)

        model.setDefinition("   ", for: sense)
        #expect(sense.definition == "   ")
        #expect(sense.fieldSource(for: .definition) == .user)

        let long = String(repeating: "a", count: 500)
        model.setDefinition(long, for: sense)
        #expect(try storedSense(sense.id)?.definition == long)

        model.setExampleText("  \n", for: example)
        #expect(example.text == "  \n")
        #expect(example.source == .user)
        #expect(try storedSense(sense.id)?.sortedExamples.map(\.text) == ["  \n"])
    }

    @Test("the comma rule drops blanks and repeats wherever they appear")
    func splitListDropsBlanksAndRepeatsAnywhere() {
        #expect(WordCardModel.splitList(" , a,,b , a ") == ["a", "b"])
        #expect(WordCardModel.splitList(",") == [])
        #expect(WordCardModel.splitList("a,") == ["a"])
        #expect(WordCardModel.splitList(" a ") == ["a"])
        #expect(WordCardModel.splitList("a b, c") == ["a b", "c"], "internal spaces are kept")
    }

    @Test("reordering a list field is an edit: stored in the new order, marked .user and saved")
    func reorderingAListFieldIsAnEdit() throws {
        let (word, sense) = try makeBook()
        sense.synonyms = ["a", "b"]
        try store.save(word)
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setSynonyms("b, a", for: sense)

        #expect(sense.synonyms == ["b", "a"])
        #expect(sense.fieldSources == [SenseField.synonyms.rawValue: .user])
        #expect(word.updatedAt > savedAt)
        #expect(try storedSense(sense.id)?.synonyms == ["b", "a"])
    }

    @Test("a hand-added sense stays .auto on every field the user has not typed into")
    func handAddedSenseKeepsAutoOnUntouchedFields() throws {
        let (word, _) = try makeBook()
        let model = WordCardModel(word: word, store: store)
        let added = model.addSense()
        let addedAt = word.updatedAt

        // Tabbing through the empty sense commits each field unchanged.
        model.setPartOfSpeech(.other, for: added)
        model.setDefinition("", for: added)
        model.setTranslation("", for: added)
        model.setSynonyms("", for: added)
        model.setAntonyms("", for: added)
        #expect(added.fieldSources.isEmpty)
        #expect(word.updatedAt == addedAt)

        model.setDefinition("x", for: added)
        model.setAntonyms("y", for: added)
        #expect(added.fieldSources == [SenseField.definition.rawValue: .user, SenseField.antonyms.rawValue: .user])
        #expect(added.fieldSource(for: .translation) == .auto)
        #expect(added.fieldSource(for: .synonyms) == .auto)
        #expect(try storedSense(added.id)?.fieldSources.count == 2)
    }

    // MARK: - Structure

    @Test("moves with stale or out-of-range offsets never trap and save nothing")
    func movesWithOutOfRangeOffsetsAreIgnored() throws {
        let word = try makeBookWithThreeSenses()
        let model = WordCardModel(word: word, store: store)
        let savedAt = word.updatedAt

        model.moveSenses(fromOffsets: [5], toOffset: 0)
        model.moveSenses(fromOffsets: [], toOffset: 1)
        model.moveSenses(fromOffsets: [0], toOffset: -1)
        model.moveSenses(fromOffsets: [7], toOffset: 99)
        model.moveSenses(fromOffsets: [2], toOffset: 3) // the end of the list is a valid destination
        #expect(model.senses.map(\.definition) == ["a", "b", "c"])
        #expect(word.updatedAt == savedAt)

        model.moveSenses(fromOffsets: [0], toOffset: 99)
        #expect(model.senses.map(\.definition) == ["b", "c", "a"], "a destination past the end lands last")
        #expect(model.senses.map(\.order) == [0, 1, 2])
        #expect(try storedWord(word.id)?.sortedSenses.map(\.definition) == ["b", "c", "a"])

        model.moveSenses(fromOffsets: [0, 2], toOffset: 1)
        #expect(model.senses.map(\.definition) == ["b", "a", "c"], "onMove semantics for several offsets")

        let sense = model.senses[0]
        sense.examples = [
            Example(text: "one", source: .auto, order: 0),
            Example(text: "two", source: .auto, order: 1),
        ]
        try store.save(word)
        let examplesSavedAt = word.updatedAt
        model.moveExamples(in: sense, fromOffsets: [7], toOffset: 0)
        #expect(sense.sortedExamples.map(\.text) == ["one", "two"])
        #expect(word.updatedAt == examplesSavedAt)
        model.moveExamples(in: sense, fromOffsets: [0], toOffset: 99)
        #expect(sense.sortedExamples.map(\.text) == ["two", "one"])
        #expect(try storedSense(sense.id)?.sortedExamples.map(\.order) == [0, 1])
    }

    @Test("a late commit on a removed sense is dropped without a trap, a mark or a save")
    func aLateCommitOnARemovedSenseIsDropped() throws {
        let (word, senses) = try makeBookWithThreeSensesAndExamples()
        let removed = senses[1]
        let example = try #require(removed.sortedExamples.first)
        let model = WordCardModel(word: word, store: store)
        model.removeSense(removed)
        let savedAt = word.updatedAt

        // Every setter the view can fire from `onDisappear` or a focus change after "Remove sense".
        model.setDefinition("late", for: removed)
        model.setTranslation("late", for: removed)
        model.setSynonyms("late", for: removed)
        model.setAntonyms("late", for: removed)
        model.setPartOfSpeech(.verb, for: removed)
        model.setExampleText("late", for: example)
        _ = model.addExample(to: removed)
        model.moveExamples(in: removed, fromOffsets: [0], toOffset: 1)
        model.removeExample(example)
        model.removeSense(removed)

        #expect(model.failure == nil)
        #expect(word.updatedAt == savedAt)
        #expect(model.senses.map(\.definition) == ["a", "c"])
        #expect(try storedWord(word.id)?.sortedSenses.map(\.definition) == ["a", "c"])
        #expect(try fresh().fetchCount(FetchDescriptor<Example>()) == 0)
    }

    @Test("a late commit on a removed example is dropped and does not touch its sense")
    func aLateCommitOnARemovedExampleIsDropped() throws {
        let (word, senses) = try makeBookWithThreeSensesAndExamples()
        let sense = senses[1]
        let removed = try #require(sense.sortedExamples.first)
        let kept = try #require(sense.sortedExamples.last)
        let model = WordCardModel(word: word, store: store)
        model.removeExample(removed)
        let savedAt = word.updatedAt

        model.setExampleText("late", for: removed)
        model.removeExample(removed)

        #expect(model.failure == nil)
        #expect(word.updatedAt == savedAt)
        #expect(sense.sortedExamples.map(\.id) == [kept.id])
        #expect(try storedSense(sense.id)?.sortedExamples.map(\.order) == [0])

        // The sense itself is untouched and still editable.
        model.setDefinition("still here", for: sense)
        #expect(try storedSense(sense.id)?.definition == "still here")
    }

    @Test("a late example commit after its removal writes nothing back")
    func lateExampleCommitAfterRemovalWritesNothing() throws {
        let (word, sense) = try makeBook()
        let example = Example(text: "She read a book.", source: .auto, order: 0)
        sense.examples = [example]
        try store.save(word)
        let model = WordCardModel(word: word, store: store)

        model.removeExample(example)
        model.setExampleText("late", for: example)

        #expect(model.failure == nil)
        #expect(sense.sortedExamples.isEmpty)
        #expect(try fresh().fetchCount(FetchDescriptor<Example>()) == 0)
    }

    // MARK: - Headword after delete

    @Test("a headword commit that lands after the word was deleted does not revive it")
    func lateHeadwordCommitAfterDeleteDoesNotReviveTheWord() throws {
        let (word, _) = try makeBook()
        _ = try store.add("apple")
        let model = WordCardModel(word: word, store: store)
        #expect(model.deleteWord())

        #expect(model.setHeadword("notebook") == nil)
        #expect(word.deletedAt != nil)
        #expect(try store.words().map(\.headword) == ["apple"])
        #expect(try store.search("notebook").isEmpty)
        #expect(try storedWord(word.id)?.deletedAt != nil)

        #expect(model.setHeadword("   ") == .empty)
        #expect(model.setHeadword("Apple") == .collision(existingHeadword: "apple"), "a tombstone takes no live key")
        #expect(model.failure == nil)
    }
}
