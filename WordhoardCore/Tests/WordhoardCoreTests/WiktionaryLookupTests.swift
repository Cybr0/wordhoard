import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Phase 7 (owner feedback 2026-10-23): the bundled Simple English Wiktionary is the first sense source,
/// so a word's meanings come in everyday-frequency order with learner definitions.
@Suite("Simple Wiktionary senses")
struct WiktionaryLookupTests {
    private static func sense(
        _ partOfSpeech: PartOfSpeech,
        _ gloss: String,
        example: String? = nil
    ) -> WiktionarySense {
        WiktionarySense(partOfSpeech: partOfSpeech, gloss: gloss, example: example)
    }

    // MARK: - Bundle

    @Test("the bundle and its CC BY-SA license ship with the package and list common meanings first")
    func theBundleListsCommonMeaningsFirst() async throws {
        let bundle = CoreInfo.resourceBundle
        let json = try #require(bundle.url(forResource: "Wiktionary/simplewikt", withExtension: "json"))
        let license = try #require(bundle.url(forResource: "Wiktionary/SIMPLEWIKT-LICENSE", withExtension: "txt"))
        #expect(try Data(contentsOf: json).count <= 10 * 1_048_576)
        #expect(try String(contentsOf: license, encoding: .utf8).contains("CC BY-SA 4.0"))

        let lookup = WiktionaryLookup.shared
        let bank = try #require(await lookup.senses(for: "Bank"))
        #expect(bank.first?.partOfSpeech == .noun)
        #expect(bank.first?.gloss.contains("money") == true)

        let run = try #require(await lookup.senses(for: "run"))
        #expect(run.first?.partOfSpeech == .verb)
        #expect(run.first?.gloss.contains("quickly") == true)

        let light = try #require(await lookup.senses(for: "light"))
        #expect(light.first?.partOfSpeech == .noun)

        #expect(await lookup.senses(for: "despite")?.first?.partOfSpeech == .preposition)
        #expect(await lookup.senses(for: "in respect of")?.first?.partOfSpeech == .phrase)
        #expect(await lookup.senses(for: "asdfgh") == nil)
    }

    @Test("a missing bundle answers nil instead of crashing")
    func aMissingBundleAnswersNil() async throws {
        let lookup = try WiktionaryLookup(bundle: temporaryWordNetBundle(files: [:]))
        #expect(await lookup.senses(for: "run") == nil)
    }

    @Test("an inflected form reads its base word's senses")
    func inflectedFormsReadTheirBaseWord() async throws {
        let lookup = WiktionaryLookup.shared
        #expect(await lookup.senses(for: "ran") == lookup.senses(for: "run"))
        #expect(await lookup.senses(for: "mice") == lookup.senses(for: "mouse"))
        let set = try #require(await lookup.senses(for: "set"))
        #expect(!set.contains { $0.gloss.lowercased().contains("past tense") }, "a grammatical form is not a meaning")
    }

    // MARK: - Generator

    @Test("a word Wiktionary knows gets its definitions without definition or ranking calls")
    func wiktionaryCardsNeedNoDefinitionCalls() async throws {
        let senses = [
            Self.sense(.noun, "A book is paper joined together with writing on it.", example: "I read a book."),
            Self.sense(.verb, "If you book something, you reserve it.", example: "We reserved a table."),
        ]
        let wiktionary = WiktionaryLookup(entries: ["book": senses])
        let calls = ScriptedModelCalls()
        let card = try await makeGenerator(calls, wiktionary: wiktionary).generateCard(makeRequest("book"))

        #expect(card.path == .wiktionary)
        #expect(card.senses.map(\.partOfSpeech) == [.noun, .verb])
        #expect(card.senses.allSatisfy { $0.senseSource == .wiktionary && $0.definition == $0.gloss })
        #expect(card.senses[0].neutralExample?.text == "I read a book.", "the editor's example is kept")
        #expect(
            card.senses[1].neutralExample?.text == "I verb the book",
            "an example without the headword is rewritten"
        )
        #expect(calls.calls(.writeDefinition).isEmpty)
        #expect(calls.calls(.selectSenses).isEmpty)
        #expect(calls.calls(.proposeSenses).isEmpty)
        #expect(calls.calls(.writeExample).count == 1)
    }

    @Test("filling a Wiktionary card twice matches its senses by gloss and adds nothing")
    @MainActor
    func fillingTwiceMatchesWiktionarySenses() async throws {
        let container = try WordhoardContainer.makeInMemory()
        let store = WordStore(container: container)
        let senses = [
            Self.sense(.noun, "A building where you can keep and borrow money.", example: "I went to the bank."),
            Self.sense(.noun, "The dry sides of a river.", example: "We sat on the river bank."),
        ]
        let wiktionary = WiktionaryLookup(entries: ["bank": senses])
        let generator = makeGenerator(ScriptedModelCalls(), wiktionary: wiktionary)
        let service = AutofillService(store: store, generator: generator)
        let word = try store.add("bank").word
        service.enqueue(word)
        await service.drain()
        service.retry(word)
        await service.drain()

        let stored = word.sortedSenses
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.senseSource == .wiktionary })
        let neutral = stored.flatMap(\.examples).filter { $0.grammarTopic == nil }
        #expect(neutral.count == 2)
    }

    @Test("in the app, only the three most common senses get topic examples; every sense keeps its neutral one")
    func topicExamplesStopAtTheThirdSense() async throws {
        let senses = (1 ... 5).map { Self.sense(.noun, "Meaning \($0) of a book.", example: "A book \($0).") }
        let calls = ScriptedModelCalls()
        let generator = FoundationModelsCardGenerator(
            calls: calls,
            lookup: .shared,
            wiktionary: WiktionaryLookup(entries: ["book": senses])
        )
        let request = makeRequest("book", topics: GeneratorFixtures.twoTopics)
        let card = try await generator.generateCard(request)
        #expect(card.senses.count == 5)
        #expect(card.senses.allSatisfy { $0.neutralExample != nil })
        let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))
        #expect(Set(examples.map(\.senseIndex)) == [0, 1, 2])
        #expect(examples.count == 6)
    }
}
