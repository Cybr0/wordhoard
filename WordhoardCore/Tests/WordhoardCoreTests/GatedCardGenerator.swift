import Foundation
import Synchronization
import Testing
import WordhoardCore

/// A latch a test opens; callers suspend on `wait()` until then. Cancellation resumes a waiter by
/// throwing. No sleeps: everything is continuation-driven.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var arrivals = 0
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        /// Removes and returns the watchers whose count has been reached.
        mutating func dueWatchers() -> [CheckedContinuation<Void, Never>] {
            let due = watchers.filter { $0.count <= waiters.count }.map(\.continuation)
            watchers.removeAll { $0.count <= waiters.count }
            return due
        }
    }

    private let state = Mutex(State())

    /// How many callers have reached the gate so far, open or not.
    var arrivals: Int {
        state.withLock(\.arrivals)
    }

    /// Callers suspended right now.
    var waiting: Int {
        state.withLock { $0.waiters.count }
    }

    /// Suspends until at least `count` callers are suspended at the gate at once.
    func untilWaiting(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.waiters.count >= count {
                    return true
                }
                state.watchers.append((count, continuation))
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [:] }
            return state.waiters
        }
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// Shuts the gate again, so the next caller waits; nobody already through is affected.
    func close() {
        state.withLock { $0.isOpen = false }
    }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (resumeNow, due) = state.withLock { state in
                    state.arrivals += 1
                    if state.isOpen || Task.isCancelled {
                        return (true, [CheckedContinuation<Void, Never>]())
                    }
                    state.waiters[id] = continuation
                    return (false, state.dueWatchers())
                }
                for watcher in due {
                    watcher.resume()
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// A `CardGenerator` that holds `generateCard` at `cardGate` and the topic stream at `topicGate` until a
/// test opens them, delegating to a `StubCardGenerator` afterwards; also counts overlapping
/// `generateCard` calls so a test can prove the queue is serial.
final class GatedCardGenerator: CardGenerator {
    let inner: StubCardGenerator
    let cardGate = Gate()
    let topicGate = Gate()

    private struct Counters {
        var inFlight = 0
        var maxInFlight = 0
        var completed: [String] = []
    }

    private let counters = Mutex(Counters())

    init(inner: StubCardGenerator = StubCardGenerator(), cardsOpen: Bool = false, topicsOpen: Bool = true) {
        self.inner = inner
        if cardsOpen {
            cardGate.open()
        }
        if topicsOpen {
            topicGate.open()
        }
    }

    /// The most `generateCard` calls that were ever in flight at once.
    var maxInFlight: Int {
        counters.withLock(\.maxInFlight)
    }

    /// Headwords whose `generateCard` returned, in completion order.
    var completed: [String] {
        counters.withLock(\.completed)
    }

    func availability() async -> CardGeneratorAvailability {
        await inner.availability()
    }

    func generateCard(_ request: CardRequest) async throws -> GeneratedCard {
        counters.withLock { counters in
            counters.inFlight += 1
            counters.maxInFlight = max(counters.maxInFlight, counters.inFlight)
        }
        defer {
            counters.withLock { $0.inFlight -= 1 }
        }
        try await cardGate.wait()
        let card = try await inner.generateCard(request)
        counters.withLock { $0.completed.append(request.headword) }
        return card
    }

    func generateTopicExamples(
        for card: GeneratedCard,
        request: CardRequest
    ) -> AsyncThrowingStream<GeneratedTopicExample, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await topicGate.wait()
                    for try await example in inner.generateTopicExamples(for: card, request: request) {
                        continuation.yield(example)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Suspends until `condition` holds, yielding to the main actor between checks, or records an issue
/// after `attempts` yields. No sleeps: the service's work happens on the main actor, so each yield lets
/// it progress one step.
@MainActor
func waitUntil(
    _ attempts: Int = 10000,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () throws -> Bool
) async throws {
    for _ in 0 ..< attempts {
        if try condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("condition not met after \(attempts) yields", sourceLocation: sourceLocation)
}

/// A `ModelCalls` that forwards to a `ScriptedModelCalls`, except that every `writeExample` call
/// `isGated` picks first waits at `gate` (a cancelled waiter throws `CancellationError`, as the real
/// call would). Gated calls reach `inner`, and so its recorded calls, only once let through; the gate's
/// `arrivals` counts every gated call that was attempted.
struct GatedModelCalls: ModelCalls {
    let inner: ScriptedModelCalls
    let gate = Gate()
    let isGated: @Sendable (_ definition: String, _ topic: GrammarTopic?) -> Bool

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
        if isGated(definition, topic) {
            try await gate.wait()
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
