import Foundation
import Synchronization
import Testing
import WordhoardCore

/// `FoundationModelsCardGenerator` over `ScriptedModelCalls` (issue #38, part b): per-field degradation
/// (A6), the topic-example stream (A2) and cancellation.
@Suite("FoundationModelsCardGenerator degradation and stage 2")
struct GeneratorDegradationTests {
    // MARK: - Per-field degradation

    @Test("a refused definition keeps the gloss, a refused neutral example is skipped; the card is produced")
    func refusedCallsDegradeOnlyTheirField() async throws {
        let calls = ScriptedModelCalls(script: .init(
            writeDefinition: { _, sense in
                if sense.partOfSpeech == .verb, sense.gloss != GeneratorFixtures.reserveGloss {
                    throw ModelCallError.refused
                }
                return "def:\(sense.gloss)"
            },
            writeExample: { _, partOfSpeech, definition, topic, _ in
                if topic == nil, partOfSpeech == .noun, definition.hasPrefix("def:a written") {
                    throw ModelCallError.failed("timeout")
                }
                return .text("I \(partOfSpeech.rawValue) the book")
            }
        ))
        let card = try await makeGenerator(calls).generateCard(makeRequest("book"))

        #expect(card.path == .wordnet)
        #expect(card.senses.count == 4)
        #expect(card.senses[2].definition == card.senses[2].gloss)
        #expect(card.senses[3].definition == "def:\(GeneratorFixtures.reserveGloss)")
        #expect(card.senses[0].neutralExample == nil)
        #expect(card.senses[1].neutralExample != nil)
        #expect(card.notes == [
            .definitionRefused(senseIndex: 2),
            .exampleRefused(senseIndex: 0, topic: nil),
        ])
        #expect(calls.calls(.writeDefinition).count == 4)
        #expect(calls.calls(.writeExample).count == 4, "a refusal never stops the remaining calls")
    }

    @Test("an empty neutral example is a skipped example with a note, not a sentence")
    func anEmptyNeutralExampleIsSkipped() async throws {
        let calls = ScriptedModelCalls(script: .init(writeExample: { _, _, _, _, _ in .doesNotFit }))
        let card = try await makeGenerator(calls).generateCard(makeRequest("book"))
        #expect(card.senses.allSatisfy { $0.neutralExample == nil })
        #expect(card.notes == (0 ..< 4).map { .exampleRefused(senseIndex: $0, topic: nil) })
    }

    // MARK: - Topic examples

    @Test("topic examples carry the requested key, skip misfits and refusals, and reach the prompt builder")
    func topicExamplesCarryTheRequestedKeyAndSkipMisfits() async throws {
        let calls = ScriptedModelCalls(script: .init(writeExample: { headword, partOfSpeech, definition, topic, _ in
            guard let topic else { return .text("I \(partOfSpeech.rawValue) the \(headword)") }
            if topic.key == GeneratorFixtures.passiveVoice.key, definition.hasPrefix("def:physical objects") {
                return .doesNotFit
            }
            if topic.key == GeneratorFixtures.presentPerfect.key, definition.hasPrefix("def:a written") {
                throw ModelCallError.refused
            }
            return .text("\(headword) \(topic.name)")
        }))
        let generator = makeGenerator(calls)
        let request = makeRequest("book", topics: GeneratorFixtures.twoTopics)
        let card = try await generator.generateCard(request)
        #expect(card.senses[0].gloss?.hasPrefix("a written") == true)
        #expect(card.senses[1].gloss?.hasPrefix("physical objects") == true)

        let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))

        #expect(examples.count == 6, "8 slots minus one misfit minus one refusal")
        #expect(examples.allSatisfy { $0.senseIndex < 4 })
        #expect(examples.allSatisfy { GeneratorFixtures.twoTopics.map(\.key).contains($0.example.grammarTopic ?? "") })
        #expect(!examples
            .contains { $0.senseIndex == 1 && $0.example.grammarTopic == GeneratorFixtures.passiveVoice.key })
        #expect(!examples
            .contains { $0.senseIndex == 0 && $0.example.grammarTopic == GeneratorFixtures.presentPerfect.key })
        #expect(examples.contains {
            $0.senseIndex == 3
                && $0.example == GeneratedExample(
                    text: "book \(GeneratorFixtures.passiveVoice.name)",
                    grammarTopic: "en.passive_voice"
                )
        })

        let topicCalls = calls.calls(.writeExample).dropFirst(4)
        #expect(topicCalls.count == 8)
        for call in topicCalls {
            guard case let .writeExample(headword, partOfSpeech, definition, requested, _) = call else { continue }
            let topic = try #require(requested)
            let prompt = ExamplePrompt.prompt(
                headword: headword,
                partOfSpeech: partOfSpeech,
                definition: definition,
                topic: topic
            )
            #expect(prompt.contains(topic.description), "the descriptor reaches the prompt builder")
            #expect(prompt.contains(topic.name))
        }
    }

    @Test("no topics → an empty stream; a cancelled consumer stops the producer's calls")
    func topicStreamHandlesNoTopicsAndCancellation() async throws {
        // Sense 0's topic calls answer; the first call for any later sense waits at the gate.
        let calls = GatedModelCalls(inner: ScriptedModelCalls()) { definition, topic in
            topic != nil && !definition.hasPrefix("def:a written")
        }
        // Serial, so "cancelled within sense 0" is exact; the window is covered in ExampleConcurrencyTests.
        let generator = FoundationModelsCardGenerator(
            calls: calls, lookup: .shared, wiktionary: WiktionaryLookup(entries: [:]), maxConcurrentExampleCalls: 1,
            maxTopicExampleSenses: .max
        )
        let card = try await generator.generateCard(makeRequest("book"))

        let none = try await collectExamples(generator.generateTopicExamples(for: card, request: makeRequest("book")))
        #expect(none.isEmpty)
        let before = calls.inner.calls.count

        let request = makeRequest("book", topics: GeneratorFixtures.twoTopics)
        let received = Mutex<[GeneratedTopicExample]>([])
        let consumer = Task {
            for try await example in generator.generateTopicExamples(for: card, request: request) {
                received.withLock { $0.append(example) }
            }
        }
        await calls.gate.untilWaiting(1)
        try await waitUntil { received.withLock(\.count) == 2 }
        consumer.cancel()
        try await consumer.value
        let delivered = received.withLock { $0 }
        #expect(delivered.count == 2, "sense 0's two slots, then the stream was cancelled")
        #expect(delivered.allSatisfy { $0.senseIndex == 0 })

        try await waitUntil { calls.gate.waiting == 0 }
        #expect(calls.inner.calls.count == before + 2, "the producer was cancelled with it")
        #expect(calls.gate.arrivals == 1, "and makes no further calls")
    }

    @Test("cancelling `generateCard` throws `CancellationError` and stops the calls")
    func cancellingTheCardThrowsCancellationError() async throws {
        // Definitions answer; every neutral example waits at the gate, which never opens.
        let calls = GatedModelCalls(inner: ScriptedModelCalls()) { _, topic in topic == nil }
        let generator = FoundationModelsCardGenerator(
            calls: calls,
            lookup: .shared,
            wiktionary: WiktionaryLookup(entries: [:])
        )
        let producer = Task { try await generator.generateCard(makeRequest("book")) }
        await calls.gate.untilWaiting(1)
        producer.cancel()
        await #expect(throws: CancellationError.self) {
            try await producer.value
        }
        // `generateCard` is structured: once it has thrown, none of its calls is still running.
        #expect(calls.gate.waiting == 0)
        #expect(calls.inner.calls(.writeExample).isEmpty, "no neutral example was written")
        #expect(calls.gate.arrivals <= FoundationModelsCardGenerator.defaultMaxConcurrentExampleCalls)
        #expect(calls.inner.calls.count < 8, "four definitions and four examples would have been made")
    }
}
