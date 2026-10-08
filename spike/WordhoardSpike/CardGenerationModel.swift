// Phase 0 spike: orchestration for the two generation modes and the on-screen state.
// Prompts and @Generable types stay in CardGeneration.swift.
//
// Split mode is lazy (issue #4):
//   1. senses call                      → card appears with senses, no examples yet
//   2. one neutral example per sense    → "time to first card"
//   3. one example per (sense, topic)   → appended as they arrive; "time to full card"
// Every example is its own short LanguageModelSession, so the context never grows.
//
// Throwaway code. Not held to the root CLAUDE.md conventions (print is fine here).

import Foundation
import FoundationModels
import Observation

// MARK: - On-screen card (shared by both modes)

struct SpikeExample: Sendable {
    let topicKey: String
    var text: String
}

struct SpikeSense: Sendable {
    var partOfSpeech: PartOfSpeech
    var definition: String
    var translation: String
    var synonyms: [String]
    var antonyms: [String]
    var examples: [SpikeExample]
}

struct SpikeCard: Sendable {
    var headword: String
    var imagePrompt: String
    var senses: [SpikeSense]

    init(senses generated: GeneratedSenses) {
        headword = generated.headword
        imagePrompt = generated.imagePrompt
        senses = generated.senses.map {
            SpikeSense(
                partOfSpeech: $0.partOfSpeech,
                definition: $0.definition,
                translation: $0.translation,
                synonyms: $0.synonyms,
                antonyms: $0.antonyms,
                examples: []
            )
        }
    }

    init(card generated: GeneratedCard) {
        headword = generated.headword
        imagePrompt = generated.imagePrompt
        senses = generated.senses.map {
            SpikeSense(
                partOfSpeech: $0.partOfSpeech,
                definition: $0.definition,
                translation: $0.translation,
                synonyms: $0.synonyms,
                antonyms: $0.antonyms,
                examples: $0.examples.map { SpikeExample(topicKey: $0.grammarTopic, text: $0.text) }
            )
        }
    }

    /// Shape of requirements.md Appendix B.
    var readableDescription: String {
        var lines: [String] = []
        lines.append("Word: \(headword)")
        for (index, sense) in senses.enumerated() {
            lines.append("")
            lines.append("Sense \(index + 1) — \(sense.partOfSpeech.rawValue)")
            lines.append("  definition:  \(sense.definition)")
            lines.append("  translation: \(sense.translation)")
            lines.append("  synonyms:    \(sense.synonyms.isEmpty ? "—" : sense.synonyms.joined(separator: ", "))")
            lines.append("  antonyms:    \(sense.antonyms.isEmpty ? "—" : sense.antonyms.joined(separator: ", "))")
            lines.append("  examples:")
            for example in sense.examples {
                let tag = "[\(example.topicKey.replacingOccurrences(of: "en.", with: ""))]"
                lines.append("    \(tag.padding(toLength: 22, withPad: " ", startingAt: 0))\(example.text)")
            }
        }
        lines.append("")
        lines.append("Image prompt: \"\(imagePrompt)\"")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Model

@MainActor
@Observable
final class CardGenerationModel {
    enum Mode: String, CaseIterable, Identifiable {
        case split = "Split calls"
        case single = "Single call"

        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case generatingCard
        case generatingSenses
        case generatingNeutralExamples(done: Int, total: Int)
        case generatingTopicExamples(done: Int, total: Int)
        case finished
        case failed
        case cancelled
    }

    var mode: Mode = .split
    /// Run example calls three at a time instead of one after another. Off by default so the
    /// first device measurement is the predictable serial one; flip it to see if concurrent
    /// sessions help or just contend for the model.
    var parallelExamples = false

    private(set) var phase: Phase = .idle
    private(set) var card: SpikeCard?
    /// Raw JSON of every call in this run, in order, with per-call timing.
    private(set) var rawLog = ""
    private(set) var errorText: String?
    private(set) var sensesElapsed: Duration?
    /// Senses + one neutral example per sense are on screen.
    private(set) var firstCardElapsed: Duration?
    /// Every (sense, topic) example is on screen.
    private(set) var fullCardElapsed: Duration?
    private(set) var callCount = 0

    private var task: Task<Void, Never>?

    var isGenerating: Bool { task != nil }

    var statusText: String {
        switch phase {
        case .idle:
            return ""
        case .generatingCard:
            return "Generating the whole card in one call…"
        case .generatingSenses:
            return "Call 1: senses…"
        case let .generatingNeutralExamples(done, total):
            return "Neutral examples \(done)/\(total)…"
        case let .generatingTopicExamples(done, total):
            return "Topic examples \(done)/\(total)…"
        case .finished:
            return "Done, \(callCount) call\(callCount == 1 ? "" : "s")"
        case .failed:
            return "Failed after \(callCount) call\(callCount == 1 ? "" : "s")"
        case .cancelled:
            return "Cancelled"
        }
    }

    var timingText: String {
        var parts: [String] = []
        if let sensesElapsed { parts.append("Senses: \(sensesElapsed.spikeFormatted)") }
        if let firstCardElapsed { parts.append("First card: \(firstCardElapsed.spikeFormatted)") }
        if let fullCardElapsed { parts.append("Full card: \(fullCardElapsed.spikeFormatted)") }
        return parts.joined(separator: " · ")
    }

    func generate(word: String) {
        cancel()
        phase = mode == .split ? .generatingSenses : .generatingCard
        card = nil
        rawLog = ""
        errorText = nil
        sensesElapsed = nil
        firstCardElapsed = nil
        fullCardElapsed = nil
        callCount = 0

        task = Task {
            do {
                switch mode {
                case .split:
                    try await runSplit(word: word)
                case .single:
                    try await runSingle(word: word)
                }
                phase = .finished
            } catch is CancellationError {
                // A newer run owns the screen now; leave its state alone.
                return
            } catch let error as LanguageModelSession.GenerationError {
                errorText = "GenerationError: \(error.errorDescription ?? String(describing: error))"
                print("GenerationError: \(error)")
                phase = .failed
            } catch {
                errorText = "Error: \(error.localizedDescription)"
                print("Error: \(error)")
                phase = .failed
            }
            guard !Task.isCancelled else { return }
            task = nil
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        phase = .cancelled
    }

    // MARK: Single call

    private func runSingle(word: String) async throws {
        let result = try await generateCard(for: word)
        try Task.checkCancellation()
        appendLog(label: "single-call card", result: result)
        card = SpikeCard(card: result.content)
        firstCardElapsed = result.elapsed
        fullCardElapsed = result.elapsed
        print("time to first card = time to full card: \(result.elapsed.spikeFormatted) (1 call)")
    }

    // MARK: Split calls

    private func runSplit(word: String) async throws {
        let clock = ContinuousClock()
        let start = clock.now

        let sensesResult = try await generateSenses(for: word)
        try Task.checkCancellation()
        appendLog(label: "senses", result: sensesResult)
        card = SpikeCard(senses: sensesResult.content)
        sensesElapsed = clock.now - start

        let senses = sensesResult.content.senses
        let neutralJobs = senses.indices.map { ExampleJob(senseIndex: $0, sense: senses[$0], topic: nil) }
        phase = .generatingNeutralExamples(done: 0, total: neutralJobs.count)
        try await runExamples(word: word, jobs: neutralJobs) { done, total in
            .generatingNeutralExamples(done: done, total: total)
        }
        try Task.checkCancellation()
        firstCardElapsed = clock.now - start
        print("time to first card: \((clock.now - start).spikeFormatted) (\(callCount) calls)")

        let topicJobs = senses.indices.flatMap { index in
            GrammarTopic.active.map { ExampleJob(senseIndex: index, sense: senses[index], topic: $0) }
        }
        phase = .generatingTopicExamples(done: 0, total: topicJobs.count)
        try await runExamples(word: word, jobs: topicJobs) { done, total in
            .generatingTopicExamples(done: done, total: total)
        }
        try Task.checkCancellation()
        fullCardElapsed = clock.now - start
        print("time to full card: \((clock.now - start).spikeFormatted) (\(callCount) calls)")
    }

    private struct ExampleJob: Sendable {
        let senseIndex: Int
        let sense: GeneratedSenseCore
        let topic: GrammarTopic?

        var topicKey: String { topic?.key ?? GrammarTopic.neutral.key }
        var label: String { "example: sense \(senseIndex + 1) (\(sense.partOfSpeech.rawValue)) / \(topicKey)" }
    }

    private struct ExampleOutcome: Sendable {
        let job: ExampleJob
        let result: Result<ModelCallResult<GeneratedExampleText>, any Error>
    }

    /// Runs the example calls, each in its own session, and appends each result to the card
    /// as it arrives. Serial by default; `parallelExamples` allows three in flight.
    private func runExamples(
        word: String,
        jobs: [ExampleJob],
        phaseFor: (_ done: Int, _ total: Int) -> Phase
    ) async throws {
        let limit = parallelExamples ? 3 : 1
        var done = 0

        try await withThrowingTaskGroup(of: ExampleOutcome.self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<limit {
                guard let job = pending.next() else { break }
                group.addTask { await Self.runExample(word: word, job: job) }
            }
            for try await outcome in group {
                try Task.checkCancellation()
                apply(outcome)
                done += 1
                phase = phaseFor(done, jobs.count)
                if let job = pending.next() {
                    group.addTask { await Self.runExample(word: word, job: job) }
                }
            }
        }
    }

    /// Nonisolated so a task-group child can run it off the main actor.
    private nonisolated static func runExample(word: String, job: ExampleJob) async -> ExampleOutcome {
        do {
            let result = try await generateExample(word: word, sense: job.sense, topic: job.topic)
            return ExampleOutcome(job: job, result: .success(result))
        } catch {
            return ExampleOutcome(job: job, result: .failure(error))
        }
    }

    private func apply(_ outcome: ExampleOutcome) {
        let text: String
        switch outcome.result {
        case let .success(result):
            appendLog(label: outcome.job.label, result: result)
            let trimmed = result.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, outcome.job.topic != nil {
                // Topic examples are optional: the model may return "" when the sense does not fit
                // the grammar (e.g. passive of an intransitive sense). No slot on the card for it.
                rawLog += "--- \(outcome.job.label) skipped: empty example, sense does not fit this grammar ---\n\n"
                print("\(outcome.job.label) skipped: empty example")
                return
            }
            text = trimmed.isEmpty ? "⚠︎ empty (neutral example is mandatory)" : trimmed
        case let .failure(error):
            callCount += 1
            rawLog += "--- \(outcome.job.label) FAILED ---\n\(error)\n\n"
            print("\(outcome.job.label) failed: \(error)")
            text = "⚠︎ failed: \(error.localizedDescription)"
        }
        card?.senses[outcome.job.senseIndex].examples.append(
            SpikeExample(topicKey: outcome.job.topicKey, text: text)
        )
    }

    private func appendLog<Content>(label: String, result: ModelCallResult<Content>) {
        callCount += 1
        rawLog += "--- \(label) (\(result.elapsed.spikeFormatted)) ---\n\(result.rawJSON)\n\n"
    }
}
