import Foundation
import Testing
import WordhoardCore

/// The `CardGenerator` seam, its DTOs and the two test doubles (issue #37). Nothing here touches a
/// store or a real model.
@Suite("CardGenerator protocol and stubs")
struct CardGeneratorTests {
    private static let presentPerfect = GrammarCatalog.english.topic(for: "en.present_perfect")!
    private static let passiveVoice = GrammarCatalog.english.topic(for: "en.passive_voice")!
    private static let twoTopics = [presentPerfect, passiveVoice]

    private func collect(
        _ stream: AsyncThrowingStream<GeneratedTopicExample, any Error>
    ) async throws -> [GeneratedTopicExample] {
        var examples: [GeneratedTopicExample] = []
        for try await example in stream {
            examples.append(example)
        }
        return examples
    }

    @Test("the stub returns the fixture for the normalized headword and records the request")
    func stubReturnsTheFixtureCardForTheNormalizedHeadword() async throws {
        let stub = StubCardGenerator()
        let request = CardRequest(headword: "Book ", nativeLanguage: "ru", topics: [])

        let card = try await stub.generateCard(request)

        #expect(card.path == .wordnet)
        #expect(card.senses.map(\.partOfSpeech) == [.noun, .verb])
        #expect(card.senses[1].definition.contains("reserve"))
        #expect(card.senses[1].translation == "бронировать")
        #expect(card.senses.allSatisfy { $0.senseSource == .wordnet && $0.gloss != nil })
        #expect(card.senses.allSatisfy { $0.neutralExample != nil })
        #expect(card.notes.isEmpty)
        #expect(stub.requests == [request])
        #expect(stub.topicRequests.isEmpty)
    }

    @Test("an unknown headword gets the generic fallback, or `.failed` without one")
    func stubFallsBackToAGenericCardOrFails() async throws {
        let card = try await StubCardGenerator().generateCard(CardRequest(
            headword: "zebra",
            nativeLanguage: nil,
            topics: []
        ))
        #expect(card.headword == "zebra")
        #expect(card.path == .wordnet)
        #expect(card.senses.count == 1)
        #expect(card.senses.first?.partOfSpeech == .noun)
        #expect(card.senses.first?.senseSource == .wordnet)
        #expect(card.senses.first?.definition == "a zebra")
        #expect(card.senses.first?.gloss == "zebra")
        #expect(card.senses.first?.neutralExample?.text == "This is a zebra.")

        let strict = StubCardGenerator(fallback: nil)
        await #expect(throws: CardGeneratorError.failed("no fixture")) {
            try await strict.generateCard(CardRequest(headword: "zebra", nativeLanguage: nil, topics: []))
        }
        #expect(strict.requests.count == 1, "a miss is still a recorded call")
    }

    @Test("not-found is a success with no senses, never a throw")
    func notFoundIsACardWithNoSenses() async throws {
        let card = try await StubCardGenerator().generateCard(CardRequest(
            headword: "asdfgh",
            nativeLanguage: "ru",
            topics: []
        ))
        #expect(card.path == .notFound)
        #expect(card.senses.isEmpty)
        #expect(card.notes.isEmpty)
    }

    @Test("a refused definition is a note on a card that keeps the gloss as the definition")
    func aRefusedDefinitionIsANoteAndTheGlossIsKept() async throws {
        let card = try await StubCardGenerator().generateCard(CardRequest(
            headword: "gaslight",
            nativeLanguage: nil,
            topics: []
        ))
        #expect(card.path == .wordnet)
        #expect(card.notes == [.definitionRefused(senseIndex: 0)])
        #expect(card.senses.count == 1)
        #expect(card.senses[0].definition == card.senses[0].gloss)
        #expect(card.senses[0].senseSource == .wordnet)
    }

    @Test("stoplist fixtures are model senses without a gloss: `however` an adverb, `despite` a preposition")
    func stoplistFixturesAreModelSensesWithoutAGloss() async throws {
        let stub = StubCardGenerator()
        let however = try await stub.generateCard(CardRequest(headword: "However", nativeLanguage: "ru", topics: []))
        #expect(however.path == .stoplist)
        #expect(however.senses.map(\.partOfSpeech) == [.adverb])
        #expect(however.senses.first?.senseSource == .model)
        #expect(however.senses.first?.gloss == nil)
        #expect(however.senses.first?.translation == "тем не менее")

        let despite = try await stub.generateCard(CardRequest(headword: "despite", nativeLanguage: "ru", topics: []))
        #expect(despite.path == .stoplist)
        #expect(despite.senses.map(\.partOfSpeech) == [.preposition])
        #expect(despite.senses.first?.senseSource == .model)
        #expect(despite.senses.first?.definition == "in spite of")
        #expect(despite.senses.first?.translation == "несмотря на")
        #expect(stub.requests.map(\.headword) == ["However", "despite"])
    }

    @Test("the topic stream yields one example per sense and requested topic, nothing for no topics")
    func topicExamplesAreYieldedPerSenseAndTopic() async throws {
        let stub = StubCardGenerator()
        let request = CardRequest(headword: "book", nativeLanguage: "ru", topics: Self.twoTopics)
        let card = try await stub.generateCard(request)

        let examples = try await collect(stub.generateTopicExamples(for: card, request: request))

        #expect(examples.count == 4)
        #expect(Set(examples.map(\.senseIndex)) == [0, 1])
        let requestedKeys = Set(Self.twoTopics.map(\.key))
        #expect(examples.allSatisfy { example in
            example.example.grammarTopic.map(requestedKeys.contains) ?? false
        })
        #expect(Set(examples.compactMap(\.example.grammarTopic)) == requestedKeys, "every requested key is used")
        #expect(examples.allSatisfy { $0.example.text.contains("book") })
        #expect(stub.topicRequests == [request])

        let noTopics = CardRequest(headword: "book", nativeLanguage: "ru", topics: [])
        let none = try await collect(stub.generateTopicExamples(for: card, request: noTopics))
        #expect(none.isEmpty)
        #expect(stub.topicRequests == [request, noTopics])
    }

    @Test("overrides drive the stream: a misfit yields nothing, a text replaces, a failure ends it")
    func topicExampleOverridesDriveTheStream() async throws {
        let stub = StubCardGenerator()
        let request = CardRequest(headword: "book", nativeLanguage: nil, topics: Self.twoTopics)
        let card = try await stub.generateCard(request)

        stub.topicExampleOverrides = [.init(1, Self.passiveVoice.key): .doesNotFit]
        let three = try await collect(stub.generateTopicExamples(for: card, request: request))
        #expect(three.count == 3)
        #expect(!three.contains { $0.senseIndex == 1 && $0.example.grammarTopic == Self.passiveVoice.key })

        stub.topicExampleOverrides = [.init(0, Self.presentPerfect.key): .text("custom")]
        let custom = try await collect(stub.generateTopicExamples(for: card, request: request))
        #expect(custom.count == 4)
        #expect(custom.first == GeneratedTopicExample(
            senseIndex: 0,
            example: GeneratedExample(text: "custom", grammarTopic: Self.presentPerfect.key)
        ))

        // (1, present_perfect) is the third slot in (sense, topic) order: two examples arrive first.
        stub.topicExampleOverrides = [.init(1, Self.presentPerfect.key): .failure(.failed("x"))]
        var received: [GeneratedTopicExample] = []
        await #expect(throws: CardGeneratorError.failed("x")) {
            for try await example in stub.generateTopicExamples(for: card, request: request) {
                received.append(example)
            }
        }
        #expect(received.count == 2)
        #expect(received.allSatisfy { $0.senseIndex == 0 })
    }

    @Test("unavailable generators throw `.unavailable(reason)` and record no request")
    func unavailableGeneratorsThrowWithoutCalling() async throws {
        let unavailable = UnavailableCardGenerator()
        let request = CardRequest(headword: "book", nativeLanguage: nil, topics: Self.twoTopics)
        #expect(await unavailable.availability() == .unavailable(.appleIntelligenceNotEnabled))
        await #expect(throws: CardGeneratorError.unavailable(.appleIntelligenceNotEnabled)) {
            try await unavailable.generateCard(request)
        }
        await #expect(throws: CardGeneratorError.unavailable(.appleIntelligenceNotEnabled)) {
            try await collect(unavailable.generateTopicExamples(for: StubFixtures.book, request: request))
        }
        #expect(UnavailableCardGenerator(reason: .modelNotReady).reason == .modelNotReady)

        let stub = StubCardGenerator(availability: .unavailable(.deviceNotEligible))
        #expect(await stub.availability() == .unavailable(.deviceNotEligible))
        await #expect(throws: CardGeneratorError.unavailable(.deviceNotEligible)) {
            try await stub.generateCard(request)
        }
        await #expect(throws: CardGeneratorError.unavailable(.deviceNotEligible)) {
            try await collect(stub.generateTopicExamples(for: StubFixtures.book, request: request))
        }
        #expect(stub.requests.isEmpty)
        #expect(stub.topicRequests.isEmpty)
    }

    @Test("the stub's delay is observable on both stages")
    func stubDelayIsHonored() async throws {
        let stub = StubCardGenerator(delay: .milliseconds(50))
        let request = CardRequest(headword: "book", nativeLanguage: nil, topics: [Self.presentPerfect])
        let clock = ContinuousClock()

        let start = clock.now
        let card = try await stub.generateCard(request)
        #expect(clock.now - start >= .milliseconds(50))

        let streamStart = clock.now
        _ = try await collect(stub.generateTopicExamples(for: card, request: request))
        #expect(clock.now - streamStart >= .milliseconds(50))

        let instant = StubCardGenerator()
        let instantStart = clock.now
        _ = try await instant.generateCard(request)
        #expect(clock.now - instantStart < .milliseconds(50))
    }

    @Test("the DTOs are Equatable, Sendable values and the path raw values are stable")
    func generatedCardTypesAreSendableValues() {
        let card = StubFixtures.book
        let sense = card.senses[0]
        let example = GeneratedExample(text: "t", grammarTopic: nil)
        let topicExample = GeneratedTopicExample(senseIndex: 0, example: example)
        let request = CardRequest(headword: "book", nativeLanguage: nil, topics: Self.twoTopics)
        let note = GenerationNote.exampleRefused(senseIndex: 0, topic: nil)
        let closure: @Sendable () -> Bool = {
            card == card && sense == sense && example == example && topicExample == topicExample
                && request == request && note == note
        }
        #expect(closure())

        #expect(GenerationPath.wordnet.rawValue == "wordnet")
        #expect(GenerationPath.stoplist.rawValue == "stoplist")
        #expect(GenerationPath.modelOnly.rawValue == "modelOnly")
        #expect(GenerationPath.notFound.rawValue == "notFound")
        #expect(CardGeneratorAvailability.UnavailableReason.appleIntelligenceNotEnabled
            .rawValue == "appleIntelligenceNotEnabled")

        var copy = card
        copy.senses[0].definition = "changed"
        #expect(copy != card, "value semantics: a copy is independent")
        #expect(StubFixtures.cards.keys.sorted() == ["asdfgh", "book", "despite", "gaslight", "however", "look up"])
    }
}
