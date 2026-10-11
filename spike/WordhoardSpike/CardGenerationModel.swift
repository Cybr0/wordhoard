// Phase 0 spike: orchestration for the two generation modes and the on-screen state.
// Prompts and @Generable types stay in CardGeneration.swift.
//
// Split mode is lazy (issue #4):
//   1. senses call                      → card appears with senses, no examples yet
//   2. one yes/no call per sense        → invented or paraphrased senses are dropped (toggleable)
//   3. one neutral example per sense    → "time to first card" (includes the verification calls)
//   4. one example per (sense, topic)   → appended as they arrive; "time to full card"
// Every call is its own short LanguageModelSession, so the context never grows.
//
// WordNet + model mode (issue #11) replaces steps 1–2 with a bundle lookup:
//   1. WordNetLookup gives up to 2 senses per part of speech → no model call, no verification
//   2. one writing call per sense            → learner definition (no translation from the model)
//   3. Translation framework, en→ru          → the definition and every synonym; none if the
//                                              language pack is not installed (never the model)
//   4. one neutral example per sense         → "time to first card"
//   5. one example per (sense, topic)        → "time to full card"
// When the word is on the function-word stoplist (however, despite, …) or WordNet has
// no entry for it, the split flow above runs instead and the log says so.
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

/// Where a sense's inventory (part of speech, meaning, synonyms, antonyms) came from.
enum SenseSource: String, Sendable {
    case model
    case wordNet = "wordnet"
}

struct SpikeSense: Sendable {
    var source: SenseSource
    var partOfSpeech: PartOfSpeech
    /// The WordNet gloss the learner definition was written from; `nil` for model senses.
    var gloss: String?
    var definition: String
    /// Model senses: the model's Russian (marked `[model]` on the card). WordNet senses: the
    /// Translation framework's Russian for `definition`, or empty when there is none.
    var translation: String
    var synonyms: [String]
    /// WordNet senses only: synonym → its Translation framework Russian, shown as `volume → том`.
    var synonymTranslations: [String: String]
    var antonyms: [String]
    var examples: [SpikeExample]

    init(_ core: GeneratedSenseCore) {
        source = .model
        partOfSpeech = core.partOfSpeech
        gloss = nil
        definition = core.definition
        translation = core.translation
        synonyms = core.synonyms
        synonymTranslations = [:]
        antonyms = core.antonyms
        examples = []
    }

    init(_ generated: GeneratedSense) {
        source = .model
        partOfSpeech = generated.partOfSpeech
        gloss = nil
        definition = generated.definition
        translation = generated.translation
        synonyms = generated.synonyms
        synonymTranslations = [:]
        antonyms = generated.antonyms
        examples = generated.examples.map { SpikeExample(topicKey: $0.grammarTopic, text: $0.text) }
    }

    /// A WordNet sense before or after the model has written for it. Until `writing` arrives
    /// the gloss stands in as the definition so the card can be shown immediately; the
    /// translations stay pending ("…") until the Translation framework step has run.
    init(wordNet sense: WordNetSense, writing: SenseWriting?) {
        source = .wordNet
        partOfSpeech = PartOfSpeech(sense.partOfSpeech)
        gloss = sense.gloss
        definition = writing?.learnerDefinition ?? sense.gloss
        translation = "…"
        synonyms = sense.synonyms
        synonymTranslations = [:]
        antonyms = sense.antonyms
        examples = []
    }
}

struct SpikeCard: Sendable {
    var headword: String
    /// Only the model paths produce one; WordNet mode has no image prompt (yet).
    var imagePrompt: String?
    var senses: [SpikeSense]

    init(senses generated: GeneratedSenses) {
        headword = generated.headword
        imagePrompt = generated.imagePrompt
        senses = generated.senses.map(SpikeSense.init)
    }

    init(card generated: GeneratedCard) {
        headword = generated.headword
        imagePrompt = generated.imagePrompt
        senses = generated.senses.map(SpikeSense.init)
    }

    init(headword: String, wordNet senses: [WordNetSense]) {
        self.headword = headword
        imagePrompt = nil
        self.senses = senses.map { SpikeSense(wordNet: $0, writing: nil) }
    }

    /// Shape of requirements.md Appendix B.
    var readableDescription: String {
        var lines: [String] = []
        lines.append("Word: \(headword)")
        for (index, sense) in senses.enumerated() {
            lines.append("")
            lines.append("Sense \(index + 1) — \(sense.partOfSpeech.rawValue) [\(sense.source.rawValue)]")
            if let gloss = sense.gloss {
                lines.append("  gloss:       \(gloss)")
            }
            lines.append("  definition:  \(sense.definition)")
            let translationTag = sense.source == .model ? " [model]" : ""
            lines.append("  translation: \(sense.translation.isEmpty ? "—" : sense.translation)\(translationTag)")
            let synonyms = sense.synonyms.map { synonym in
                sense.synonymTranslations[synonym].map { "\(synonym) → \($0)" } ?? synonym
            }
            lines.append("  synonyms:    \(synonyms.isEmpty ? "—" : synonyms.joined(separator: ", "))")
            lines.append("  antonyms:    \(sense.antonyms.isEmpty ? "—" : sense.antonyms.joined(separator: ", "))")
            lines.append("  examples:")
            for example in sense.examples {
                let tag = "[\(example.topicKey.replacingOccurrences(of: "en.", with: ""))]"
                lines.append("    \(tag.padding(toLength: 22, withPad: " ", startingAt: 0))\(example.text)")
            }
        }
        lines.append("")
        if let imagePrompt {
            lines.append("Image prompt: \"\(imagePrompt)\"")
        } else {
            lines.append("Image prompt: — (not generated in WordNet mode)")
        }
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
        case wordNet = "WordNet + model"

        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case generatingCard
        case lookingUp
        case generatingSenses
        case verifyingSenses(done: Int, total: Int)
        case writingSenses(done: Int, total: Int)
        case translating(count: Int)
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
    /// After the senses call, ask the model one yes/no question per sense and drop the senses it
    /// rejects. On by default; switch it off to measure what it costs in time and what it buys.
    var verifySenses = true

    private(set) var phase: Phase = .idle
    private(set) var card: SpikeCard?
    /// What verification did to the sense list, when it changed anything. Set to a warning when
    /// every sense was rejected and the first one was kept unverified rather than showing nothing.
    private(set) var verificationNote: String?
    /// WordNet mode: what the lookup found, or why the model took over (function word, not found).
    private(set) var wordNetNote: String?
    /// WordNet mode: why there are no translations (language pack not installed), when so.
    private(set) var translationNote: String?
    /// Raw JSON of every call in this run, in order, with per-call timing.
    private(set) var rawLog = ""
    private(set) var errorText: String?
    /// WordNet mode: the bundle lookup alone (includes the first-time bundle load, if any).
    private(set) var lookupElapsed: Duration?
    /// Split mode: the senses call. WordNet mode: lookup plus the writing calls, i.e. when the
    /// senses are on screen with their learner definitions.
    private(set) var sensesElapsed: Duration?
    /// WordNet mode: the Translation framework calls alone (definitions and synonyms, en→ru).
    private(set) var translationElapsed: Duration?
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
        case .lookingUp:
            return "Looking up WordNet…"
        case .generatingSenses:
            return "Call 1: senses…"
        case let .verifyingSenses(done, total):
            return "Verifying senses \(done)/\(total)…"
        case let .writingSenses(done, total):
            return "Writing senses \(done)/\(total)…"
        case let .translating(count):
            return "Translating \(count) string\(count == 1 ? "" : "s") en→ru…"
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
        if let lookupElapsed { parts.append("Lookup: \(lookupElapsed.spikeFormatted)") }
        if let sensesElapsed { parts.append("Senses: \(sensesElapsed.spikeFormatted)") }
        if let translationElapsed { parts.append("Translation: \(translationElapsed.spikeFormatted)") }
        if let firstCardElapsed { parts.append("First card: \(firstCardElapsed.spikeFormatted)") }
        if let fullCardElapsed { parts.append("Full card: \(fullCardElapsed.spikeFormatted)") }
        return parts.joined(separator: " · ")
    }

    func generate(word: String) {
        cancel()
        switch mode {
        case .split: phase = .generatingSenses
        case .single: phase = .generatingCard
        case .wordNet: phase = .lookingUp
        }
        card = nil
        verificationNote = nil
        wordNetNote = nil
        translationNote = nil
        rawLog = ""
        errorText = nil
        lookupElapsed = nil
        sensesElapsed = nil
        translationElapsed = nil
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
                case .wordNet:
                    try await runWordNet(word: word)
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

        var senses = sensesResult.content.senses
        if verifySenses {
            senses = try await verify(word: word, senses: senses)
            try Task.checkCancellation()
            card?.senses = senses.map(SpikeSense.init)
        }

        try await runAllExamples(word: word, senses: senses.map(SpikeSense.init), since: start)
    }

    // MARK: WordNet + model

    private func runWordNet(word: String) async throws {
        let clock = ContinuousClock()
        let start = clock.now

        // Closed-class words never reach the bundle (issue #11, decision 3).
        let isFunctionWord = await WordNetLookup.shared.isFunctionWord(word)
        try Task.checkCancellation()
        if isFunctionWord {
            lookupElapsed = clock.now - start
            try await fallBackToModel(word: word, note: "WordNet: \"\(word)\" is a function word → model-only senses call")
            return
        }

        let entry = await WordNetLookup.shared.entry(for: word)
        try Task.checkCancellation()
        lookupElapsed = clock.now - start

        guard let entry, !entry.top.isEmpty else {
            try await fallBackToModel(word: word, note: "WordNet: \"\(word)\" not found → model-only senses call")
            return
        }

        let counts = entry.senseCounts.map { "\($0.count) \($0.partOfSpeech.name)" }.joined(separator: ", ")
        let kept = entry.top.enumerated().map { index, sense in
            "  \(index + 1). \(sense.partOfSpeech.name): \(sense.gloss)"
        }.joined(separator: "\n")
        let note = "WordNet: \"\(word)\" → \(entry.bundledSenseCount) sense\(entry.bundledSenseCount == 1 ? "" : "s") in bundle (\(counts)), kept \(entry.top.count)"
        wordNetNote = note
        rawLog += "--- \(note) (\(lookupElapsed?.spikeFormatted ?? "?")) ---\n\(kept)\n\n"
        print("\(note)\n\(kept)")

        card = SpikeCard(headword: word, wordNet: entry.top)

        // One writing call per sense, one after another (few and cheap). A failed call keeps the
        // sense with the raw gloss as its definition rather than dropping a sense WordNet vouches for.
        phase = .writingSenses(done: 0, total: entry.top.count)
        for (index, sense) in entry.top.enumerated() {
            let label = "write: sense \(index + 1) (\(sense.partOfSpeech.name)) \"\(sense.gloss)\""
            let outcome = await Self.runWriting(word: word, sense: sense)
            try Task.checkCancellation()
            switch outcome {
            case let .success(result):
                appendLog(label: label, result: result)
                card?.senses[index] = SpikeSense(wordNet: sense, writing: result.content)
            case let .failure(error):
                callCount += 1
                rawLog += "--- \(label) FAILED, gloss kept as definition ---\n\(error)\n\n"
                print("\(label) failed, gloss kept: \(error)")
            }
            phase = .writingSenses(done: index + 1, total: entry.top.count)
        }
        sensesElapsed = clock.now - start

        try await translateCard()

        guard let senses = card?.senses else { return }
        try await runAllExamples(word: word, senses: senses, since: start)
    }

    /// Translation framework, en→ru: one batch per sense (its definition and synonyms). Without the
    /// language pack the card stays untranslated and the screen and log say so; the model is never
    /// asked to translate in this mode.
    private func translateCard() async throws {
        guard let senses = card?.senses else { return }
        let batches = senses.map { [$0.definition] + $0.synonyms }
        phase = .translating(count: batches.reduce(0) { $0 + $1.count })

        let outcome = await SpikeTranslator.translate(batches: batches)
        try Task.checkCancellation()
        switch outcome {
        case let .unavailable(note):
            translationNote = note
            rawLog += "--- \(note) ---\n\n"
            print(note)
            for index in senses.indices {
                card?.senses[index].translation = ""
            }
        case let .translated(translations, elapsed, log):
            translationElapsed = elapsed
            rawLog += log
            for (index, sense) in senses.enumerated() {
                card?.senses[index].translation = translations[sense.definition] ?? ""
                card?.senses[index].synonymTranslations = Dictionary(
                    uniqueKeysWithValues: sense.synonyms.compactMap { synonym in
                        translations[synonym].map { (synonym, $0) }
                    }
                )
            }
            print("translation: \(translations.count) strings in \(elapsed.spikeFormatted)")
        }
    }

    /// The model-only (split) flow for a word WordNet cannot serve, with the reason on screen and in the log.
    private func fallBackToModel(word: String, note: String) async throws {
        wordNetNote = note
        rawLog += "--- \(note) (\(lookupElapsed?.spikeFormatted ?? "?")) ---\n\n"
        print(note)
        phase = .generatingSenses
        try await runSplit(word: word)
    }

    /// Nonisolated so the call runs off the main actor, like the example calls.
    private nonisolated static func runWriting(
        word: String,
        sense: WordNetSense
    ) async -> Result<ModelCallResult<SenseWriting>, any Error> {
        do {
            return try .success(await writeSense(word: word, sense: sense))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Examples for every sense (shared by split and WordNet modes)

    /// Neutral example per sense (then "time to first card"), then one example per
    /// (sense, topic) ("time to full card"). `senses` are the card's senses in order.
    private func runAllExamples(word: String, senses: [SpikeSense], since start: ContinuousClock.Instant) async throws {
        let clock = ContinuousClock()
        let neutralJobs = senses.indices.map {
            ExampleJob(senseIndex: $0, partOfSpeech: senses[$0].partOfSpeech, definition: senses[$0].definition, topic: nil)
        }
        phase = .generatingNeutralExamples(done: 0, total: neutralJobs.count)
        try await runExamples(word: word, jobs: neutralJobs) { done, total in
            .generatingNeutralExamples(done: done, total: total)
        }
        try Task.checkCancellation()
        firstCardElapsed = clock.now - start
        print("time to first card: \((clock.now - start).spikeFormatted) (\(callCount) calls)")

        let topicJobs = senses.indices.flatMap { index in
            GrammarTopic.active.map {
                ExampleJob(senseIndex: index, partOfSpeech: senses[index].partOfSpeech, definition: senses[index].definition, topic: $0)
            }
        }
        phase = .generatingTopicExamples(done: 0, total: topicJobs.count)
        try await runExamples(word: word, jobs: topicJobs) { done, total in
            .generatingTopicExamples(done: done, total: total)
        }
        try Task.checkCancellation()
        fullCardElapsed = clock.now - start
        print("time to full card: \((clock.now - start).spikeFormatted) (\(callCount) calls)")
    }

    // MARK: Verification

    /// One yes/no call per sense, one after another (they are cheap and few). Returns the senses
    /// to keep, in their original order. A verification call that *fails* keeps its sense, so a
    /// flaky model never empties the card; only an explicit "no" drops one. If every sense is
    /// rejected the first one is kept and `verificationNote` says so.
    private func verify(word: String, senses: [GeneratedSenseCore]) async throws -> [GeneratedSenseCore] {
        phase = .verifyingSenses(done: 0, total: senses.count)
        var kept: [GeneratedSenseCore] = []
        var rejected: [Int] = []

        for (index, sense) in senses.enumerated() {
            let label = "verify: sense \(index + 1) (\(sense.partOfSpeech.rawValue)) \"\(sense.definition)\""
            let outcome = await Self.runVerification(word: word, sense: sense)
            try Task.checkCancellation()
            switch outcome {
            case let .success(result):
                let verdict = result.content.isCommonlyUsed ? "yes" : "no"
                appendLog(label: "\(label) → \(verdict)", result: result)
                print("\(label) → \(verdict)")
                if result.content.isCommonlyUsed {
                    kept.append(sense)
                } else {
                    rejected.append(index + 1)
                }
            case let .failure(error):
                callCount += 1
                rawLog += "--- \(label) FAILED, sense kept ---\n\(error)\n\n"
                print("\(label) failed, sense kept: \(error)")
                kept.append(sense)
            }
            phase = .verifyingSenses(done: index + 1, total: senses.count)
        }

        if kept.isEmpty, let first = senses.first {
            verificationNote = "⚠︎ Verification rejected all \(senses.count) sense\(senses.count == 1 ? "" : "s"); showing sense 1 unverified."
            kept = [first]
        } else if !rejected.isEmpty {
            verificationNote = "Verification dropped sense\(rejected.count == 1 ? "" : "s") \(rejected.map(String.init).joined(separator: ", ")) of \(senses.count)."
        }
        if let verificationNote { print(verificationNote) }
        return kept
    }

    /// Nonisolated so the call runs off the main actor, like the example calls.
    private nonisolated static func runVerification(
        word: String,
        sense: GeneratedSenseCore
    ) async -> Result<ModelCallResult<SenseVerdict>, any Error> {
        do {
            return try .success(await verifySense(word: word, sense: sense))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Examples

    private struct ExampleJob: Sendable {
        let senseIndex: Int
        let partOfSpeech: PartOfSpeech
        /// The model's definition (split mode) or its learner definition of the WordNet gloss.
        let definition: String
        let topic: GrammarTopic?

        var topicKey: String { topic?.key ?? GrammarTopic.neutral.key }
        var label: String { "example: sense \(senseIndex + 1) (\(partOfSpeech.rawValue)) / \(topicKey)" }
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
            let result = try await generateExample(
                word: word,
                partOfSpeech: job.partOfSpeech,
                definition: job.definition,
                topic: job.topic
            )
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
