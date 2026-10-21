import Foundation
import Testing
import WordhoardCore

/// `FoundationModelsCardGenerator` over `ScriptedModelCalls` and `StubTranslator` (issue #38, part b):
/// availability and the three sense-inventory paths. The bundled WordNet is used as is; the real model
/// and the real Translation framework are never called. Helpers live in `GeneratorTestSupport.swift`.
@Suite("FoundationModelsCardGenerator paths")
struct FoundationModelsCardGeneratorPathTests {
    // MARK: - Availability

    @Test("an unavailable model throws `.unavailable` from both stages before any call")
    func unavailableModelThrowsBeforeAnyCall() async throws {
        let calls = ScriptedModelCalls(availability: .unavailable(.appleIntelligenceNotEnabled))
        let generator = makeGenerator(calls)
        let request = makeRequest("book", topics: GeneratorFixtures.twoTopics)

        #expect(await generator.availability() == .unavailable(.appleIntelligenceNotEnabled))
        await #expect(throws: CardGeneratorError.unavailable(.appleIntelligenceNotEnabled)) {
            try await generator.generateCard(request)
        }
        let card = GeneratedCard(headword: "book", path: .wordnet, senses: [], notes: [])
        await #expect(throws: CardGeneratorError.unavailable(.appleIntelligenceNotEnabled)) {
            try await collectExamples(generator.generateTopicExamples(for: card, request: request))
        }
        #expect(calls.calls.isEmpty)
    }

    // MARK: - WordNet path

    @Test("`book` takes the WordNet path: four written senses, no senses call, one translation batch")
    func bookTakesTheWordNetPathWithOneTranslationBatch() async throws {
        let calls = ScriptedModelCalls()
        let translator = StubTranslator(table: ["def:\(GeneratorFixtures.reserveGloss)": "бронировать"])
        let card = try await makeGenerator(calls, translator: translator).generateCard(makeRequest("Book "))

        #expect(card.headword == "Book")
        #expect(card.path == .wordnet)
        #expect(card.senses.map(\.partOfSpeech) == [.noun, .noun, .verb, .verb])
        #expect(card.senses.allSatisfy { $0.senseSource == .wordnet && $0.gloss != nil })
        #expect(card.senses.allSatisfy { $0.definition == "def:\($0.gloss ?? "")" })
        #expect(card.senses[3].gloss == GeneratorFixtures.reserveGloss)
        #expect(card.senses[3].translation == "бронировать")
        #expect(card.senses[0 ..< 3].allSatisfy { $0.translation == "ru:\($0.definition)" })
        #expect(card.senses.allSatisfy { $0.neutralExample != nil })
        #expect(card.senses[2].neutralExample == GeneratedExample(text: "I verb the Book", grammarTopic: nil))
        #expect(card.senses[3].synonyms.contains("reserve"), "synonyms come from WordNet, not the model")
        #expect(card.notes.isEmpty)

        #expect(calls.calls(.writeDefinition).count == 4)
        #expect(calls.calls(.writeExample).count == 4)
        #expect(calls.calls(.proposeSenses).isEmpty)
        #expect(calls.calls(.verify).isEmpty)
        #expect(calls.calls.prefix(4).allSatisfy { $0.method == .writeDefinition }, "definitions before examples")
        #expect(translator.batches.count == 1)
        #expect(translator.batches.first?.texts == card.senses.map(\.definition))
        #expect(translator.batches.first?.source == "en")
        #expect(translator.batches.first?.target == "ru")
    }

    @Test("every prose call names exactly one sense; only the senses call returns several items")
    func everyProseCallCarriesOneSense() async throws {
        let calls = ScriptedModelCalls()
        let card = try await makeGenerator(calls).generateCard(makeRequest("book"))
        let glosses = card.senses.compactMap(\.gloss)
        #expect(glosses.count == 4)

        for call in calls.calls {
            switch call {
            case let .writeDefinition(headword, sense):
                let prompt = DefinitionPrompt.prompt(headword: headword, sense: sense)
                #expect(glosses.filter { prompt.contains($0) } == [sense.gloss], "one gloss per definition prompt")
            case let .writeExample(headword, partOfSpeech, definition, topic):
                let prompt = ExamplePrompt.prompt(
                    headword: headword, partOfSpeech: partOfSpeech, definition: definition, topic: topic
                )
                let mentioned = card.senses.filter { prompt.contains($0.definition) }
                #expect(mentioned.count == 1, "one definition per example prompt")
            case .proposeSenses, .verify:
                Issue.record("the WordNet path must not propose or verify senses")
            }
        }
    }

    // MARK: - Stoplist and model-only paths

    @Test("`however` takes the stoplist path: one verified model sense and no bundle entry consulted")
    func howeverTakesTheStoplistPath() async throws {
        // A bundle that *does* know "however" as a noun: if the lookup were consulted the path would
        // be `.wordnet` and the trap gloss would show up.
        let bundle = try temporaryWordNetBundle(files: [
            "oewn-2024.json": """
            {"edition":"trap","synsets":[["a trap gloss that must never be used",["trap"]]],\
            "lemmas":{"however":{"n":[0]}}}
            """,
            "function-words.txt": "# connectives\nhowever\n",
        ])
        let calls = ScriptedModelCalls(script: .init(proposeSenses: { _ in [GeneratorFixtures.howeverSense] }))
        let card = try await makeGenerator(calls, lookup: WordNetLookup(bundle: bundle))
            .generateCard(makeRequest("however"))

        #expect(card.path == .stoplist)
        #expect(card.senses.count == 1)
        #expect(card.senses.first?.partOfSpeech == .adverb)
        #expect(card.senses.first?.senseSource == .model)
        #expect(card.senses.first?.gloss == nil)
        #expect(card.senses.first?.definition == GeneratorFixtures.howeverSense.definition)
        #expect(card.senses.first?.translation == "ru:\(GeneratorFixtures.howeverSense.definition)")
        #expect(card.senses.first?.synonyms == ["nevertheless"])
        #expect(card.senses.first?.neutralExample?.text == "I adverb the however")
        #expect(card.notes.isEmpty)
        #expect(calls.calls.map(\.method) == [.proposeSenses, .verify, .writeExample])
        #expect(calls.calls.first == .proposeSenses(headword: "however", wordClass: nil))
        #expect(calls.calls[1] == .verify(headword: "however", sense: GeneratorFixtures.howeverSense, wordClass: nil))
    }

    @Test("a word nobody knows is `.notFound` with no sense when the verifier rejects every proposal")
    func unknownWordsAreNotFoundWhenEveryProposedSenseIsRejected() async throws {
        let calls = ScriptedModelCalls(script: .init(
            proposeSenses: { _ in GeneratorFixtures.nonsenseSenses },
            verify: { _, _ in false }
        ))
        let translator = StubTranslator()
        let card = try await makeGenerator(calls, translator: translator).generateCard(makeRequest("asdfgh"))

        #expect(card.path == .notFound)
        #expect(card.senses.isEmpty)
        #expect(card.notes.isEmpty)
        #expect(calls.calls.map(\.method) == [.proposeSenses, .verify, .verify])
        #expect(calls.calls(.writeExample).isEmpty)
        #expect(translator.batches.isEmpty)
    }

    @Test("a verify call that throws keeps its sense; only an explicit no drops one")
    func aFailingVerifyCallKeepsTheSense() async throws {
        let calls = ScriptedModelCalls(script: .init(
            proposeSenses: { _ in GeneratorFixtures.nonsenseSenses },
            verify: { _, sense in
                if sense.partOfSpeech == .verb {
                    throw ModelCallError.failed("flaky")
                }
                return true
            }
        ))
        let card = try await makeGenerator(calls).generateCard(makeRequest("asdfgh"))

        #expect(card.path == .modelOnly)
        #expect(card.senses.map(\.partOfSpeech) == [.noun, .verb])
        #expect(card.senses.allSatisfy { $0.senseSource == .model && $0.gloss == nil })
        #expect(calls.calls(.verify).count == 2)
        #expect(calls.calls(.writeExample).count == 2)
    }

    @Test("a refused senses call fails the card with `.refused`; any other failure with `.failed`")
    func aRefusedSensesCallFailsTheCard() async throws {
        let refused = ScriptedModelCalls(script: .init(proposeSenses: { _ in throw ModelCallError.refused }))
        await #expect(throws: CardGeneratorError.refused) {
            try await makeGenerator(refused).generateCard(makeRequest("asdfgh"))
        }
        #expect(refused.calls.map(\.method) == [.proposeSenses])

        let failed = ScriptedModelCalls(script: .init(proposeSenses: { _ in throw ModelCallError.failed("boom") }))
        await #expect(throws: CardGeneratorError.failed("boom")) {
            try await makeGenerator(failed).generateCard(makeRequest("asdfgh"))
        }
    }
}
