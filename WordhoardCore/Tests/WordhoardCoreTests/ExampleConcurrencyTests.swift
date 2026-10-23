import Foundation
import Synchronization
import Testing
import WordhoardCore

/// Plan 2.8 (#20): example calls run in a window of `maxConcurrentExampleCalls`, the first card returns
/// before any topic call, cancellation closes the window.
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
                    calls: calls, lookup: .shared, wiktionary: WiktionaryLookup(entries: [:]),
                    maxConcurrentExampleCalls: $0, maxTopicExampleSenses: .max
                )
            } ?? FoundationModelsCardGenerator(
                calls: calls, lookup: .shared, wiktionary: WiktionaryLookup(entries: [:]), maxTopicExampleSenses: .max
            )
            let request = makeRequest("book", topics: Self.threeTopics)
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
        // The very first slot waits at the gate until every other slot has been yielded.
        let calls = GatedModelCalls(inner: ScriptedModelCalls(script: Self.taggedScript)) { definition, topic in
            definition.contains("a written work") && topic?.key == "en.present_perfect"
        }
        let generator = FoundationModelsCardGenerator(
            calls: calls,
            lookup: .shared,
            wiktionary: WiktionaryLookup(entries: [:]),
            maxTopicExampleSenses: .max
        )
        let request = makeRequest("book", topics: Self.threeTopics)
        let card = try await generator.generateCard(request)
        let received = Mutex<[GeneratedTopicExample]>([])
        let consumer = Task {
            for try await example in generator.generateTopicExamples(for: card, request: request) {
                received.withLock { $0.append(example) }
            }
        }
        await calls.gate.untilWaiting(1)
        try await waitUntil { received.withLock(\.count) == 11 }
        calls.gate.open()
        try await consumer.value
        let examples = received.withLock { $0 }

        let requested = card.senses.indices.flatMap { index in Self.threeTopics.map { "\(index)/\($0.key)" } }
        let yielded = examples.map { "\($0.senseIndex)/\($0.example.grammarTopic ?? "")" }
        #expect(yielded.last == requested.first, "every later slot was yielded before the first")
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
        let request = makeRequest("book", topics: Self.threeTopics)
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
        // The first topic slot answers; every later one waits at the gate, which never opens.
        let calls = GatedModelCalls(inner: ScriptedModelCalls()) { definition, topic in
            guard let topic else { return false }
            return !(definition.contains("a written work") && topic.key == "en.present_perfect")
        }
        let generator = FoundationModelsCardGenerator(
            calls: calls,
            lookup: .shared,
            wiktionary: WiktionaryLookup(entries: [:]),
            maxTopicExampleSenses: .max
        )
        let request = makeRequest("book", topics: Self.threeTopics)
        let card = try await generator.generateCard(request)
        let beforeStream = calls.inner.calls(.writeExample).count
        let window = FoundationModelsCardGenerator.defaultMaxConcurrentExampleCalls

        let received = Mutex(0)
        let consumer = Task {
            for try await _ in generator.generateTopicExamples(for: card, request: request) {
                received.withLock { $0 += 1 }
            }
        }
        // The first example is in, and the window is full again with waiting slots.
        await calls.gate.untilWaiting(window)
        try await waitUntil { received.withLock { $0 } == 1 }
        consumer.cancel()
        try await consumer.value
        try await waitUntil { calls.gate.waiting == 0 }

        #expect(received.withLock { $0 } == 1)
        #expect(calls.inner.calls(.writeExample).count == beforeStream + 1, "no gated slot got through")
        #expect(calls.gate.arrivals == window, "no call started after the cancel")
        #expect(1 + calls.gate.arrivals < 12, "the stream did not run to the end")
    }
}
