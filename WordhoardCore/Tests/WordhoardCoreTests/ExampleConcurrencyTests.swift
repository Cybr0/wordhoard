import Foundation
import Synchronization
import Testing
import WordhoardCore

/// Plan 2.8 (#20): example calls run in a window of `maxConcurrentExampleCalls`, the first card returns
/// before any topic call, cancellation closes the window, and translation stays batched per word.
@Suite("Example concurrency")
struct ExampleConcurrencyTests {
    private static let threeTopics = ["en.present_perfect", "en.passive_voice", "en.past_simple"].compactMap {
        GrammarCatalog.english.topic(for: $0)
    }

    /// Every example names its definition and topic, so routing can be checked on any yield order.
    private static let taggedScript = ScriptedModelCalls.Script(writeExample: { headword, _, definition, topic, _ in
        .text("\(headword) | \(definition) | \(topic?.key ?? "neutral")")
    })

    @Test("example calls run up to the configured concurrency, every slot once, routed by sense and topic")
    func exampleCallsRunUpToTheConfiguredConcurrency() async throws {
        #expect(Self.threeTopics.count == 3)
        for (limit, expected) in [(nil, 3), (1, 1)] as [(Int?, Int)] {
            let calls = ScriptedModelCalls(script: Self.taggedScript, delays: [.writeExample: .milliseconds(50)])
            let generator = limit.map {
                FoundationModelsCardGenerator(
                    calls: calls, lookup: .shared, translator: StubTranslator(), maxConcurrentExampleCalls: $0
                )
            } ?? FoundationModelsCardGenerator(calls: calls, lookup: .shared, translator: StubTranslator())
            let request = makeRequest("book", native: nil, topics: Self.threeTopics)
            let card = try await generator.generateCard(request)
            #expect(card.senses.count == 4)
            #expect(card.senses.enumerated().allSatisfy { index, sense in
                sense.neutralExample?.text == "book | \(card.senses[index].definition) | neutral"
            }, "neutral examples land on their own sense")

            let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))

            #expect(calls.maxInFlight(.writeExample) == expected, "limit \(String(describing: limit))")
            #expect(examples.count == 12)
            for example in examples {
                let definition = card.senses[example.senseIndex].definition
                #expect(example.example.text == "book | \(definition) | \(example.example.grammarTopic ?? "")")
            }
            let topicSlots = calls.calls(.writeExample).compactMap { call -> String? in
                guard case let .writeExample(_, _, definition, topic, _) = call, let topic else { return nil }
                return "\(definition)/\(topic.key)"
            }
            #expect(topicSlots.count == 12)
            #expect(Set(topicSlots).count == 12, "every (sense, topic) pair exactly once")
        }
    }

    @Test("yield order follows completion, and routing stays correct when later slots finish first")
    func outOfOrderCompletionKeepsRouting() async throws {
        let inner = ScriptedModelCalls(script: Self.taggedScript)
        let calls = LatencyCalls(inner: inner) { definition, topic in
            // The very first slot is the slowest, so the slots after it overtake it.
            guard let topic else { return .zero }
            let first = definition.contains("a written work") && topic.key == "en.present_perfect"
            return first ? .milliseconds(150) : .milliseconds(10)
        }
        let generator = FoundationModelsCardGenerator(calls: calls, lookup: .shared, translator: StubTranslator())
        let request = makeRequest("book", native: nil, topics: Self.threeTopics)
        let card = try await generator.generateCard(request)
        let examples = try await collectExamples(generator.generateTopicExamples(for: card, request: request))

        let requested = card.senses.indices.flatMap { index in Self.threeTopics.map { "\(index)/\($0.key)" } }
        let yielded = examples.map { "\($0.senseIndex)/\($0.example.grammarTopic ?? "")" }
        #expect(yielded != requested, "a later slot was yielded before the first")
        #expect(yielded.sorted() == requested.sorted())
        for example in examples {
            #expect(example.example.text.contains(card.senses[example.senseIndex].definition))
            #expect(example.example.text.hasSuffix(example.example.grammarTopic ?? "-"))
        }
    }

    @Test("`generateCard` returns before any topic example is requested")
    func noTopicExampleIsRequestedBeforeTheFirstCardReturns() async throws {
        let calls = ScriptedModelCalls(delays: [.writeExample: .milliseconds(10)])
        let generator = makeGenerator(calls)
        let request = makeRequest("book", native: nil, topics: Self.threeTopics)
        let card = try await generator.generateCard(request)
        let atReturn = calls.calls(.writeExample)
        #expect(atReturn.count == 4)
        #expect(atReturn.allSatisfy { call in
            guard case let .writeExample(_, _, _, topic, _) = call else { return false }
            return topic == nil
        })
        _ = try await collectExamples(generator.generateTopicExamples(for: card, request: request))
        #expect(calls.calls(.writeExample).count == 16)
    }

    @Test("cancelling the stream's consumer stops new calls within one window")
    func cancellingTheStreamStopsNewCalls() async throws {
        let calls = ScriptedModelCalls(delays: [.writeExample: .milliseconds(50)])
        let generator = makeGenerator(calls)
        let request = makeRequest("book", native: nil, topics: Self.threeTopics)
        let card = try await generator.generateCard(request)
        let beforeStream = calls.calls(.writeExample).count

        let firstArrived = Mutex(false)
        let consumer = Task {
            var received = 0
            for try await _ in generator.generateTopicExamples(for: card, request: request) {
                received += 1
                firstArrived.withLock { $0 = true }
            }
            return received
        }
        while !firstArrived.withLock({ $0 }) {
            await Task.yield()
        }
        consumer.cancel()
        let atCancel = calls.calls(.writeExample).count
        let received = try await consumer.value
        try await Task.sleep(for: .milliseconds(200))
        let after = calls.calls(.writeExample).count

        #expect(received < 12)
        #expect(after - atCancel <= 3, "at most one window more")
        #expect(after - beforeStream < 12, "the stream did not run to the end")
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.calls(.writeExample).count == after, "and nothing afterwards")
    }

    @Test("translation stays at most two framework batches per word")
    func translationUsesAtMostTwoBatchesPerWord() async throws {
        let translator = StubTranslator()
        let generator = makeGenerator(ScriptedModelCalls(), translator: translator)
        let card = try await generator.generateCard(makeRequest("book", topics: Self.threeTopics))
        #expect(card.senses.count == 4)
        #expect((1 ... 2).contains(translator.batches.count))
    }
}

/// Forwards to a `ScriptedModelCalls`, sleeping a per-slot latency in `writeExample` first.
private struct LatencyCalls: ModelCalls {
    let inner: ScriptedModelCalls
    let latency: @Sendable (_ definition: String, _ topic: GrammarTopic?) -> Duration

    func availability() async -> CardGeneratorAvailability {
        await inner.availability()
    }

    func proposeSenses(headword: String, wordClass: FunctionWordClass?) async throws -> [ProposedSense] {
        try await inner.proposeSenses(headword: headword, wordClass: wordClass)
    }

    func verify(headword: String, sense: ProposedSense, wordClass: FunctionWordClass?) async throws -> Bool {
        try await inner.verify(headword: headword, sense: sense, wordClass: wordClass)
    }

    func selectSenses(headword: String, candidates: [WordNetSense]) async throws -> [Int] {
        try await inner.selectSenses(headword: headword, candidates: candidates)
    }

    func writeDefinition(headword: String, sense: WordNetSense) async throws -> String {
        try await inner.writeDefinition(headword: headword, sense: sense)
    }

    func proposeTranslation(headword: String, sense: GeneratedSense, nativeLanguage: String) async throws -> String {
        try await inner.proposeTranslation(headword: headword, sense: sense, nativeLanguage: nativeLanguage)
    }

    func writeExample(
        headword: String,
        partOfSpeech: PartOfSpeech,
        definition: String,
        topic: GrammarTopic?,
        mustContainHeadword: Bool
    ) async throws -> ExampleAnswer {
        let wait = latency(definition, topic)
        if wait > .zero {
            try await Task.sleep(for: wait)
        }
        return try await inner.writeExample(
            headword: headword,
            partOfSpeech: partOfSpeech,
            definition: definition,
            topic: topic,
            mustContainHeadword: mustContainHeadword
        )
    }
}
