import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The topic-example contract end to end (plan 3.2, #56; A2, G4): every topic example was asked for
/// with the topic's catalog name and description in the prompt, carries exactly the requested key
/// whatever the model wrote, and a pair the model says does not fit produces nothing. Prompt text →
/// generator → service → stored `Example`, so a refactor of any layer cannot quietly break it. Topics
/// are always resolved from `GrammarCatalog.english`, never built by hand.
@Suite("Topic example contract")
struct TopicExampleContractTests {
    static let catalog = GrammarCatalog.english
    static let presentPerfectKey: GrammarTopicID = "en.present_perfect"
    static let passiveVoiceKey: GrammarTopicID = "en.passive_voice"

    static func topic(_ key: GrammarTopicID) throws -> GrammarTopic {
        try #require(catalog.topic(for: key))
    }

    /// The topic `writeExample` calls, in order: (definition, topic).
    static func topicCalls(_ calls: ScriptedModelCalls) -> [(definition: String, topic: GrammarTopic)] {
        calls.calls(.writeExample).compactMap { call in
            guard case let .writeExample(_, _, definition, topic?, _) = call else {
                return nil
            }
            return (definition, topic)
        }
    }

    // MARK: - Prompt text

    @Test("the topic prompt contains the catalog name and description, never the key")
    func theTopicPromptContainsTheCatalogNameAndDescription() throws {
        let topic = try Self.topic(Self.presentPerfectKey)
        let definition = "to reserve a seat, room, ticket, etc. in advance"

        let prompt = ExamplePrompt.prompt(headword: "book", partOfSpeech: .verb, definition: definition, topic: topic)
        #expect(prompt.contains(topic.name))
        #expect(prompt.contains(topic.description))
        #expect(!prompt.contains("en.present_perfect"))
        #expect(!prompt.contains("en."))

        let neutral = ExamplePrompt.prompt(headword: "book", partOfSpeech: .verb, definition: definition, topic: nil)
        #expect(!neutral.contains(topic.name))
        #expect(!neutral.contains(topic.description))
    }

    @Test("every catalog topic renders its own name and description into the prompt")
    func everyCatalogTopicRendersIntoThePrompt() {
        #expect(Self.catalog.topics.count == 32)
        for topic in Self.catalog.topics {
            let prompt = ExamplePrompt.prompt(
                headword: "book", partOfSpeech: .noun, definition: "a written work", topic: topic
            )
            #expect(prompt.contains(topic.name), "\(topic.key)")
            #expect(prompt.contains(topic.description), "\(topic.key)")
            #expect(!prompt.contains(topic.key), "\(topic.key)")
        }
    }

    // MARK: - Generator

    @Test("one topic call per sense carries the requested topic, and the key comes from the request")
    func oneTopicCallPerSenseCarriesTheRequestedTopic() async throws {
        let presentPerfect = try Self.topic(Self.presentPerfectKey)
        let calls = ScriptedModelCalls()
        let generator = makeGenerator(calls)
        let request = makeRequest("book", topics: [presentPerfect])
        let card = try await generator.generateCard(request)
        #expect(card.senses.count == 4)
        #expect(Self.topicCalls(calls).isEmpty, "the first card makes neutral calls only")

        let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))

        let topicCalls = Self.topicCalls(calls)
        #expect(topicCalls.count == 4)
        #expect(topicCalls.allSatisfy { $0.topic == presentPerfect })
        #expect(Set(topicCalls.map(\.definition)) == Set(card.senses.map(\.definition)))
        #expect(Set(topicCalls.map(\.definition)).count == 4, "each call names a different sense")
        #expect(examples.count == 4)
        #expect(examples.allSatisfy { $0.example.grammarTopic == Self.presentPerfectKey })
        #expect(examples.map(\.senseIndex).sorted() == [0, 1, 2, 3])

        let noTopics = ScriptedModelCalls()
        let plain = makeGenerator(noTopics)
        let plainRequest = makeRequest("book", topics: [])
        let plainCard = try await plain.generateCard(plainRequest)
        let nothing = try await collectExamples(plain.generateTopicExamples(for: plainCard, request: plainRequest))
        #expect(nothing.isEmpty)
        #expect(Self.topicCalls(noTopics).isEmpty)
    }

    @Test("the key is never parsed from the model text")
    func theKeyIsNeverParsedFromTheModelText() async throws {
        let request = try makeRequest("book", topics: [Self.topic(Self.presentPerfectKey)])
        let card = try await makeGenerator(ScriptedModelCalls()).generateCard(request)
        let firstDefinition = try #require(card.senses.first?.definition)
        let misleading = "The table was booked in the passive voice."
        let calls = ScriptedModelCalls(script: .init(writeExample: { headword, partOfSpeech, definition, topic, _ in
            topic != nil && definition == firstDefinition
                ? .text(misleading)
                : .text("I \(partOfSpeech.rawValue) the \(headword)")
        }))

        let examples = try await collectExamples(
            makeGenerator(calls).generateTopicExamples(for: card, request: request)
        )

        let first = try #require(examples.first { $0.senseIndex == 0 })
        #expect(first.example.text == misleading)
        #expect(first.example.grammarTopic == Self.presentPerfectKey)
        #expect(!examples.contains { $0.example.grammarTopic == Self.passiveVoiceKey })
        #expect(examples.allSatisfy { $0.example.grammarTopic == Self.presentPerfectKey })
    }

    @Test("misfits and refusals yield nothing for their pair only")
    func misfitsAndRefusalsYieldNothingForTheirPairOnly() async throws {
        let presentPerfect = try Self.topic(Self.presentPerfectKey)
        let passiveVoice = try Self.topic(Self.passiveVoiceKey)
        let request = makeRequest("book", topics: [presentPerfect, passiveVoice])
        let card = try await makeGenerator(ScriptedModelCalls()).generateCard(request)
        #expect(card.senses.count == 4)
        let definitions = card.senses.map(\.definition)
        let misfit = (definition: definitions[1], key: Self.passiveVoiceKey)
        let refused = (definition: definitions[2], key: Self.presentPerfectKey)
        let calls = ScriptedModelCalls(script: .init(writeExample: { headword, partOfSpeech, definition, topic, _ in
            if definition == misfit.definition, topic?.key == misfit.key {
                return .doesNotFit
            }
            if definition == refused.definition, topic?.key == refused.key {
                throw ModelCallError.refused
            }
            return .text("I \(partOfSpeech.rawValue) the \(headword)")
        }))

        let examples = try await collectExamples(
            makeGenerator(calls).generateTopicExamples(for: card, request: request)
        )

        #expect(Self.topicCalls(calls).count == 8, "one call per pair, no retry for either")
        #expect(examples.count == 6)
        let pairs = Set(examples.map { "\($0.senseIndex)/\($0.example.grammarTopic ?? "nil")" })
        #expect(!pairs.contains("1/\(Self.passiveVoiceKey)"))
        #expect(!pairs.contains("2/\(Self.presentPerfectKey)"))
        #expect(pairs.count == 6)
        #expect(examples
            .allSatisfy { [Self.presentPerfectKey, Self.passiveVoiceKey].contains($0.example.grammarTopic) })
    }

    // MARK: - Service and store

    /// The dropped key is logged by `AutofillService.makeRequest` at `.notice` ("Dropped unknown grammar
    /// topics: en.bogus"); the service has no log seam, so this test pins what reaches the generator and
    /// the store, and the log line is checked by inspection (PR).
    @MainActor
    @Test("active topics become tagged examples and unknown keys are dropped")
    func activeTopicsBecomeTaggedExamplesAndUnknownKeysAreDropped() async throws {
        let container = try WordhoardContainer.makeInMemory()
        let store = WordStore(container: container)
        try store.updateSettings { $0.activeGrammarTopics = [Self.presentPerfectKey, "en.bogus"] }
        let stub = StubCardGenerator()
        let service = AutofillService(store: store, generator: stub)
        let list = WordListModel(store: store, autofill: service)

        list.draft = "book"
        let word = try #require(list.addDraft()).word
        await service.drain()

        let request = try #require(stub.topicRequests.last)
        #expect(request.topics.map(\.key) == [Self.presentPerfectKey])
        #expect(try request.topics.map(\.description) == [Self.topic(Self.presentPerfectKey).description])
        let stored = try #require(try storedWordOrNil(word.id, in: container))
        #expect(stored.senses.count == 2)
        for sense in stored.senses {
            let tagged = sense.examples.filter { $0.grammarTopic == Self.presentPerfectKey }
            #expect(tagged.count == 1)
            #expect(tagged.allSatisfy { $0.source == .auto })
            #expect(sense.examples.count(where: { $0.grammarTopic == nil }) == 1)
            #expect(sense.examples.allSatisfy { $0.grammarTopic == nil || $0.grammarTopic == Self.presentPerfectKey })
        }
    }

    @MainActor
    @Test("a misfit leaves no example until regenerated")
    func aMisfitLeavesNoExampleUntilRegenerated() async throws {
        let container = try WordhoardContainer.makeInMemory()
        let store = WordStore(container: container)
        try store.updateSettings { $0.activeGrammarTopics = [Self.presentPerfectKey] }
        let stub = StubCardGenerator()
        stub.topicExampleOverrides = [.init(1, Self.presentPerfectKey): .doesNotFit]
        let service = AutofillService(store: store, generator: stub)
        let word = try store.add("book").word

        service.enqueue(word)
        await service.drain()

        func tagged(_ index: Int) throws -> [Example] {
            let stored = try #require(try storedWordOrNil(word.id, in: container))
            return stored.sortedSenses[index].examples.filter { $0.grammarTopic == Self.presentPerfectKey }
        }
        #expect(try tagged(1).isEmpty, "no placeholder, no neutral copy")
        let first = try tagged(0)
        #expect(first.count == 1)

        stub.topicExampleOverrides = [:]
        service.retry(word)
        await service.drain()

        #expect(try tagged(1).count == 1)
        #expect(try tagged(0).map(\.id) == first.map(\.id), "the slot rule keeps sense 0's example")
    }
}
