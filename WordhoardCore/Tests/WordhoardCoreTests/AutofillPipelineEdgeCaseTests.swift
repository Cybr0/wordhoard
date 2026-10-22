import Foundation
import SwiftData
import Testing
import WordhoardCore

/// qa edge cases across the real pipeline seam (issues #20, #21): the example window and the headword
/// check on multi-word headwords whose first word is inflected.
@MainActor
@Suite("Autofill pipeline edge cases")
struct AutofillPipelineEdgeCaseTests {
    private static let topicKeys: [GrammarTopicID] = ["en.present_perfect", "en.passive_voice", "en.past_simple"]

    /// Every example names its topic and definition, so no two collide in the merger's duplicate check.
    private static let taggedScript = ScriptedModelCalls.Script(writeExample: { headword, _, definition, topic, _ in
        .text("\(headword) \(topic?.key ?? "neutral") \(definition)")
    })

    private struct StoredExample: Hashable {
        var topic: GrammarTopicID?
        var text: String
    }

    /// `book` filled through `AutofillService` with a scripted generator limited to `limit` example calls;
    /// returns each sense's examples as values, checking order and routing on the way.
    private func fillBook(maxConcurrentExampleCalls limit: Int) async throws -> [Set<StoredExample>] {
        let store = try WordStore(container: WordhoardContainer.makeInMemory())
        try store.settings().activeGrammarTopics = Self.topicKeys
        let generator = FoundationModelsCardGenerator(
            calls: ScriptedModelCalls(script: Self.taggedScript),
            lookup: .shared,
            translator: StubTranslator(),
            maxConcurrentExampleCalls: limit
        )
        let service = AutofillService(store: store, generator: generator)
        let word = try store.add("book").word
        service.enqueue(word)
        await service.drain()
        #expect(word.autofillState == .ready)
        #expect(word.senses.count == 4)
        for sense in word.sortedSenses {
            #expect(sense.examples.count == 1 + Self.topicKeys.count, "limit \(limit)")
            #expect(sense.sortedExamples.map(\.order) == Array(0 ..< sense.examples.count), "gapless")
            #expect(sense.examples.allSatisfy { $0.text.contains(sense.definition) }, "routed to its sense")
        }
        return word.sortedSenses.map { sense in
            Set(sense.examples.map { StoredExample(topic: $0.grammarTopic, text: $0.text) })
        }
    }

    @Test("one or three concurrent example calls store the same examples on the same senses")
    func exampleConcurrencyDoesNotChangeWhatIsStored() async throws {
        let serial = try await fillBook(maxConcurrentExampleCalls: 1)
        let windowed = try await fillBook(maxConcurrentExampleCalls: 3)
        #expect(serial.count == 4)
        #expect(serial == windowed)
    }

    @Test("a multi-word headword matches when its first word is inflected or irregular")
    func phrasalHeadwordsMatchInflectedFirstWords() {
        func matches(_ headword: String, _ sentence: String) -> Bool {
            HeadwordMatcher.contains(headword: headword, in: sentence)
        }
        #expect(matches("look up", "He is looking up the word."))
        #expect(matches("look up", "She looked it up yesterday."))
        #expect(matches("give up", "She gave up smoking."))
        #expect(matches("give up", "He has given it up."))
        #expect(matches("give up", "They are giving up."))
        #expect(matches("run out", "We ran out of milk."))
        #expect(matches("take off", "The plane took off."))
        #expect(matches("break down", "The car broke down."))
        #expect(matches("bring up", "She brought up the topic."))

        #expect(!matches("look up", "I looked at the menu."), "the particle is required")
        #expect(!matches("give up", "She gave a speech."))
    }
}
