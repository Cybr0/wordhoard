import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Plan 2.9 (issue #21) in the generator: the typed "does not fit", the headword check with one retry,
/// and the drop. `ScriptedModelCalls` plays the model; the stoplist word *however* keeps every card to
/// one sense so a slot is one call.
@Suite("Example headword check")
struct ExampleHeadwordCheckTests {
    private static let presentPerfect = GeneratorFixtures.presentPerfect
    private static let neutral = ExampleAnswer.text("However, it rained all day.")
    private static let withoutHeadword = ExampleAnswer.text("Nevertheless, it has rained all day.")
    private static let withHeadword = ExampleAnswer.text("However, it has rained all day.")

    /// A generator for *however* whose topic example answers come from `topicAnswers` in call order.
    private func makeHowever(
        neutralAnswers: [ExampleAnswer] = [Self.neutral],
        topicAnswers: [ExampleAnswer]
    ) -> (FoundationModelsCardGenerator, ScriptedModelCalls) {
        let calls = ScriptedModelCalls(script: .init(
            proposeSenses: { _ in [GeneratorFixtures.howeverSense] },
            writeExample: { _, _, _, topic, retry in
                let answers = topic == nil ? neutralAnswers : topicAnswers
                let index = retry ? 1 : 0
                return answers.indices.contains(index) ? answers[index] : answers[0]
            }
        ))
        return (makeGenerator(calls), calls)
    }

    private func topicCalls(_ calls: ScriptedModelCalls) -> [(topic: GrammarTopic?, retry: Bool)] {
        calls.calls(.writeExample).compactMap { call in
            guard case let .writeExample(_, _, _, topic, retry) = call, topic != nil else { return nil }
            return (topic, retry)
        }
    }

    @Test("an example without the headword is asked for once more, with the must-contain line")
    func anExampleWithoutTheHeadwordIsRegeneratedOnce() async throws {
        let (generator, calls) = makeHowever(topicAnswers: [Self.withoutHeadword, Self.withHeadword])
        let request = makeRequest("however", topics: [Self.presentPerfect])
        let card = try await generator.generateCard(request)
        #expect(card.senses.first?.neutralExample?.text == "However, it rained all day.")
        #expect(calls.calls(.writeExample).count == 1, "the neutral example passed the check first time")

        let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))

        let kept = GeneratedTopicExample(
            senseIndex: 0,
            example: GeneratedExample(text: "However, it has rained all day.", grammarTopic: "en.present_perfect")
        )
        #expect(examples == [kept])
        let topicCalls = topicCalls(calls)
        #expect(topicCalls.count == 2, "exactly two calls for the slot")
        #expect(topicCalls.map(\.retry) == [false, true])
        let retryPrompt = ExamplePrompt.prompt(
            headword: "however",
            partOfSpeech: .adverb,
            definition: GeneratorFixtures.howeverSense.definition,
            topic: Self.presentPerfect,
            mustContainHeadword: true
        )
        #expect(retryPrompt.contains("The sentence must contain the word \"however\" itself."))
        let firstPrompt = ExamplePrompt.prompt(
            headword: "however",
            partOfSpeech: .adverb,
            definition: GeneratorFixtures.howeverSense.definition,
            topic: Self.presentPerfect,
            mustContainHeadword: false
        )
        #expect(!firstPrompt.contains("must contain the word"))
    }

    @Test("an example still without the headword after the retry is dropped: nothing yielded, or nil plus a note")
    func anExampleStillWithoutTheHeadwordIsDropped() async throws {
        let (generator, calls) = makeHowever(topicAnswers: [Self.withoutHeadword, Self.withoutHeadword])
        let request = makeRequest("however", topics: [Self.presentPerfect])
        let card = try await generator.generateCard(request)

        let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))
        #expect(examples.isEmpty)
        #expect(topicCalls(calls).map(\.retry) == [false, true], "two calls, then the slot is given up")

        let (neutralGenerator, neutralCalls) = makeHowever(
            neutralAnswers: [Self.withoutHeadword, Self.withoutHeadword], topicAnswers: [Self.withHeadword]
        )
        let dropped = try await neutralGenerator.generateCard(makeRequest("however"))
        #expect(dropped.path == .stoplist)
        #expect(dropped.senses.count == 1, "the card is still returned")
        #expect(dropped.senses.first?.neutralExample == nil)
        #expect(dropped.notes == [.exampleDropped(senseIndex: 0, topic: nil)])
        #expect(neutralCalls.calls(.writeExample).count == 2)
    }

    @Test("`fits == false` is final: no retry, nothing yielded; a blank text with fits true is the same answer")
    func doesNotFitIsNeverRetried() async throws {
        let (generator, calls) = makeHowever(topicAnswers: [.doesNotFit, Self.withHeadword])
        let request = makeRequest("however", topics: [Self.presentPerfect])
        let card = try await generator.generateCard(request)
        let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))
        #expect(examples.isEmpty)
        #expect(topicCalls(calls).map(\.retry) == [false], "one call, no retry")

        let (lateRefusal, lateCalls) = makeHowever(topicAnswers: [Self.withoutHeadword, .doesNotFit])
        let lateCard = try await lateRefusal.generateCard(request)
        let late = try await collectExamples(lateRefusal.generateTopicExamples(for: lateCard, request: request))
        #expect(late.isEmpty, "a retry answering does-not-fit yields nothing either")
        #expect(topicCalls(lateCalls).map(\.retry) == [false, true])

        let (neutralRefusal, _) = makeHowever(neutralAnswers: [.doesNotFit], topicAnswers: [Self.withHeadword])
        let neutralCard = try await neutralRefusal.generateCard(makeRequest("however"))
        #expect(neutralCard.senses.first?.neutralExample == nil)
        #expect(neutralCard.notes == [.exampleRefused(senseIndex: 0, topic: nil)], "a neutral skip reads as a refusal")

        #expect(ExampleAnswer(fits: false, text: "She has booked a table.") == .doesNotFit)
        #expect(ExampleAnswer(fits: true, text: "") == .doesNotFit)
        #expect(ExampleAnswer(fits: true, text: " \n") == .doesNotFit)
        #expect(ExampleAnswer(fits: true, text: "  She has booked a table. ") == .text("She has booked a table."))
    }
}

/// The same rules seen from the store: what the model skips or the matcher drops is never saved.
@MainActor
@Suite("Example headword check through AutofillService")
struct ExampleHeadwordCheckServiceTests {
    @Test("a does-not-fit answer and a twice-dropped example never reach the store")
    func skippedAndDroppedExamplesNeverReachTheStore() async throws {
        let container = try WordhoardContainer.makeInMemory()
        let store = WordStore(container: container)
        try store.settings().activeGrammarTopics = ["en.present_perfect"]
        let calls = ScriptedModelCalls(script: .init(writeExample: { headword, partOfSpeech, definition, topic, _ in
            guard topic != nil else { return .text("I \(partOfSpeech.rawValue) the \(headword) today.") }
            if definition.hasPrefix("def:a written") {
                return .doesNotFit
            }
            if definition.hasPrefix("def:physical objects") {
                return .text("These volumes have been bound in leather.")
            }
            return .text("I have \(partOfSpeech.rawValue)ed the \(headword) twice.")
        }))
        let generator = FoundationModelsCardGenerator(
            calls: calls,
            lookup: .shared,
            wiktionary: WiktionaryLookup(entries: [:]),
            maxTopicExampleSenses: .max
        )
        let service = AutofillService(store: store, generator: generator)

        let word = try store.add("book").word
        service.enqueue(word)
        await service.drain()

        let filled = try storedWord(word.id, in: container)
        #expect(filled.autofillState == .ready)
        let senses = filled.sortedSenses
        #expect(senses.count == 4)
        #expect(senses.allSatisfy { $0.sortedExamples.first?.grammarTopic == nil }, "every neutral example kept")
        let topicExamples = senses.map { $0.sortedExamples.filter { $0.grammarTopic != nil } }
        #expect(topicExamples.map(\.count) == [0, 0, 1, 1])
        #expect(filled.senses.flatMap(\.examples).allSatisfy {
            HeadwordMatcher.contains(headword: "book", in: $0.text)
        })
        #expect(!filled.senses.flatMap(\.examples).contains { $0.text.contains("volumes") })
        let exampleCalls = calls.calls(.writeExample).count
        #expect(exampleCalls == 9, "four neutral, then one skip, one retry pair, two plain")
    }
}
