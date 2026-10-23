import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The card's only mutation path (W2, A4, C4): every setter applies the change, marks provenance where §5
/// says so, and saves once; an unchanged commit does nothing at all.
@MainActor
@Suite("WordCardModel")
struct WordCardModelTests {
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
    private func makeBook(definition: String = "a written work") throws -> (Word, Sense) {
        let word = try store.add("book").word
        let sense = Sense(partOfSpeech: .noun, definition: definition, order: 0)
        word.senses = [sense]
        try store.save(word)
        return (word, sense)
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

    // MARK: - Provenance (A4)

    @Test("editing a definition marks it .user and persists it")
    func editingADefinitionMarksItUserAndPersistsIt() throws {
        let (word, sense) = try makeBook()
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setDefinition("a bound set of pages", for: sense)

        #expect(sense.definition == "a bound set of pages")
        #expect(sense.fieldSource(for: .definition) == .user)
        #expect(sense.fieldSource(for: .translation) == .auto)
        #expect(sense.fieldSource(for: .synonyms) == .auto)
        #expect(sense.fieldSource(for: .antonyms) == .auto)
        #expect(sense.fieldSources.count == 1)
        #expect(word.updatedAt > savedAt)
        #expect(model.failure == nil)
        let stored = try #require(try storedSense(sense.id))
        #expect(stored.definition == "a bound set of pages")
        #expect(stored.fieldSource(for: .definition) == .user)
    }

    @Test("editing synonyms marks only synonyms .user and persists the split list")
    func editingSynonymsMarksThemUserAndPersistsThem() throws {
        let (word, sense) = try makeBook()
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setSynonyms("volume, tome", for: sense)

        #expect(sense.synonyms == ["volume", "tome"])
        #expect(sense.fieldSources == [SenseField.synonyms.rawValue: .user])
        #expect(word.updatedAt > savedAt)
        #expect(try storedSense(sense.id)?.synonyms == ["volume", "tome"])
        #expect(try storedSense(sense.id)?.fieldSource(for: .synonyms) == .user)
    }

    @Test("editing antonyms marks only antonyms .user and persists the split list")
    func editingAntonymsMarksThemUserAndPersistsThem() throws {
        let (word, sense) = try makeBook()
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setAntonyms("cancel", for: sense)

        #expect(sense.antonyms == ["cancel"])
        #expect(sense.fieldSources == [SenseField.antonyms.rawValue: .user])
        #expect(word.updatedAt > savedAt)
        #expect(try storedSense(sense.id)?.antonyms == ["cancel"])
        #expect(try storedSense(sense.id)?.fieldSource(for: .antonyms) == .user)
    }

    @Test("list fields split on commas, trim and deduplicate")
    func listFieldsSplitOnCommasTrimAndDeduplicate() throws {
        #expect(WordCardModel.splitList("big,  large,,big ") == ["big", "large"])
        #expect(WordCardModel.splitList("") == [])
        #expect(WordCardModel.splitList(" , ,") == [])
        #expect(WordCardModel.splitList(",,,") == [])
        #expect(WordCardModel.splitList("one") == ["one"])
        #expect(WordCardModel.splitList("Big, big") == ["Big", "big"])
        #expect(WordCardModel.splitList("\u{00A0}large\u{00A0},\ttome\n") == ["large", "tome"])

        let (word, sense) = try makeBook()
        let model = WordCardModel(word: word, store: store)
        model.setSynonyms("big,  large,,big ", for: sense)
        #expect(sense.synonyms == ["big", "large"])
        #expect(sense.synonyms.joined(separator: ", ") == "big, large")
        #expect(try storedSense(sense.id)?.synonyms == ["big", "large"])

        model.setAntonyms(" , ,", for: sense)
        #expect(sense.antonyms == [])
        #expect(sense.fieldSource(for: .antonyms) == .auto, "an empty list over an empty list is unchanged")
    }

    @Test("committing an unchanged value does not mark or save")
    func committingAnUnchangedValueDoesNotMarkOrSave() throws {
        let (word, sense) = try makeBook()
        sense.synonyms = ["big", "large"]
        try store.save(word)
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setDefinition("a written work", for: sense)
        model.setSynonyms("big , large", for: sense)
        model.setSynonyms("big,large,big", for: sense)
        model.setAntonyms("", for: sense)
        model.setPartOfSpeech(.noun, for: sense)

        #expect(sense.fieldSources.isEmpty)
        #expect(sense.definition == "a written work")
        #expect(sense.synonyms == ["big", "large"])
        #expect(sense.translation == nil)
        #expect(word.updatedAt == savedAt)
        #expect(try storedWord(word.id)?.updatedAt == savedAt)
        #expect(try storedSense(sense.id)?.fieldSources.isEmpty == true)
        #expect(model.failure == nil)
    }

    @Test("editing an example's text marks it .user; the same text leaves it .auto")
    func editingAnExampleTextMarksItUser() throws {
        let (word, sense) = try makeBook()
        let example = Example(text: "She read a book.", source: .auto, order: 0)
        sense.examples = [example]
        try store.save(word)
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setExampleText("She read a book.", for: example)
        #expect(example.source == .auto)
        #expect(word.updatedAt == savedAt)

        model.setExampleText("She read a thick book.", for: example)
        #expect(example.text == "She read a thick book.")
        #expect(example.source == .user)
        #expect(word.updatedAt > savedAt)
        #expect(sense.fieldSources.isEmpty, "an example edit marks the example, not the sense")
        let stored = try #require(try storedExample(example.id))
        #expect(stored.text == "She read a thick book.")
        #expect(stored.source == .user)
    }

    @Test("changing the part of speech saves without a provenance mark; the same one saves nothing")
    func changingPartOfSpeechSavesWithoutAMark() throws {
        let (word, sense) = try makeBook()
        let savedAt = word.updatedAt
        let model = WordCardModel(word: word, store: store)

        model.setPartOfSpeech(.verb, for: sense)
        #expect(sense.partOfSpeech == .verb)
        #expect(sense.fieldSources.isEmpty)
        #expect(word.updatedAt > savedAt)
        #expect(try storedSense(sense.id)?.partOfSpeech == .verb)

        let changedAt = word.updatedAt
        model.setPartOfSpeech(.verb, for: sense)
        #expect(word.updatedAt == changedAt)
        #expect(sense.fieldSources.isEmpty)
    }
}
