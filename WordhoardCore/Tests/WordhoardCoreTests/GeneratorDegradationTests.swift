import Foundation
import Testing
import WordhoardCore

/// `FoundationModelsCardGenerator` over `ScriptedModelCalls` and `StubTranslator` (issue #38, part b):
/// per-field degradation (A6), the translation rules (A9), the topic-example stream (A2) and cancellation.
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
        #expect(card.senses[2].translation == "ru:book", "a refused definition does not stop the translation")
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

    // MARK: - Translation

    @Test("no native language → no translator call; no pack or a failed batch → nil translations and one note")
    func translationIsSkippedWithoutALanguageOrAPack() async throws {
        let silent = StubTranslator()
        let none = try await makeGenerator(ScriptedModelCalls(), translator: silent).generateCard(makeRequest(
            "book",
            native: nil
        ))
        #expect(none.senses.allSatisfy { $0.translation == nil })
        #expect(none.notes.isEmpty)
        #expect(silent.batches.isEmpty)

        let notDownloaded = StubTranslator(availability: .supported)
        let noPack = try await makeGenerator(ScriptedModelCalls(), translator: notDownloaded)
            .generateCard(makeRequest("book"))
        #expect(noPack.senses.count == 4)
        #expect(noPack.senses.allSatisfy { $0.translation == nil })
        #expect(noPack.notes == [.translationUnavailable(language: "ru")])
        #expect(notDownloaded.batches.isEmpty, "no translate call without an installed pack")
        #expect(noPack.senses.allSatisfy { $0.neutralExample != nil }, "the pipeline continues past the pack")

        let broken = StubTranslator(failure: .failed("xpc"))
        let failed = try await makeGenerator(ScriptedModelCalls(), translator: broken).generateCard(makeRequest("book"))
        #expect(failed.senses.allSatisfy { $0.translation == nil })
        #expect(failed.notes == [.translationUnavailable(language: "ru")])
        #expect(broken.batches.count == 1)
        #expect(failed.senses.allSatisfy { $0.neutralExample != nil })
    }

    @Test("a partial translation map leaves only the missing senses untranslated")
    func aPartialTranslationLeavesTheRestUntranslated() async throws {
        // The back-translation answers nothing, so every proposal falls back; the definition batch
        // answers only the *reserve* definition.
        let partial = PartialTranslator(answering: "def:\(GeneratorFixtures.reserveGloss)", with: "бронировать")
        let card = try await FoundationModelsCardGenerator(
            calls: ScriptedModelCalls(), lookup: .shared, translator: partial
        ).generateCard(makeRequest("book"))
        #expect(card.senses[3].translation == "бронировать")
        #expect(card.senses[3].translationIsFallback)
        #expect(card.senses[0 ..< 3].allSatisfy { $0.translation == nil && !$0.translationIsFallback })
        #expect(card.notes == [.translationFallback(senseIndex: 3, rejectedProposal: "ru:book")])
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
        let calls = ScriptedModelCalls(delay: .milliseconds(20))
        // Serial, so "cancelled within sense 0" is exact; the window is covered in ExampleConcurrencyTests.
        let generator = makeGenerator(calls, maxConcurrentExampleCalls: 1)
        let card = try await generator.generateCard(makeRequest("book"))

        let none = try await collectExamples(generator.generateTopicExamples(for: card, request: makeRequest("book")))
        #expect(none.isEmpty)
        let before = calls.calls.count

        let request = makeRequest("book", topics: GeneratorFixtures.twoTopics)
        let consumer = Task { try await collectExamples(generator.generateTopicExamples(for: card, request: request)) }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        let delivered = try await consumer.value
        #expect(delivered.count < 8, "cancelled before the 8 slots were filled")
        #expect(delivered.allSatisfy { $0.senseIndex == 0 })

        try await Task.sleep(for: .milliseconds(100))
        let after = calls.calls.count
        #expect(after < before + 8, "the producer was cancelled with it")
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.calls.count == after, "and makes no further calls")
    }

    @Test("cancelling `generateCard` throws `CancellationError` and stops the calls")
    func cancellingTheCardThrowsCancellationError() async throws {
        let calls = ScriptedModelCalls(delay: .milliseconds(30))
        let generator = makeGenerator(calls)
        let producer = Task { try await generator.generateCard(makeRequest("book")) }
        try await Task.sleep(for: .milliseconds(40))
        producer.cancel()
        await #expect(throws: CancellationError.self) {
            try await producer.value
        }
        let after = calls.calls.count
        #expect(after < 8, "four definitions and four examples would have been made")
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.calls.count == after)
    }
}

/// A translator answering one text only, to model a partial framework response.
private struct PartialTranslator: Translator {
    let text: String
    let answer: String

    init(answering text: String, with answer: String) {
        self.text = text
        self.answer = answer
    }

    func availability(from source: String, to target: String) async -> TranslationAvailability {
        .installed
    }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String: String] {
        texts.contains(text) ? [text: answer] : [:]
    }
}
