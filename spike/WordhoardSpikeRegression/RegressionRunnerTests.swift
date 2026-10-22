// Phase 0 spike, issue #14: the on-device regression runner. Since plan task 2.2b (issue #38) it
// drives the *product's* generator, `FoundationModelsCardGenerator` from WordhoardCore, so it
// measures the prompts the app ships (ADR 0001 point 6); the spike's own CardGenerationModel is no
// longer involved.
//
// One test walks every word of docs/regression-words.md (copied into this bundle at build time,
// parsed here — the list is never duplicated in code) through `generateCard` (first card) and the
// full topic-example stream (full card), in-process on the phone, and records everything the issue
// asks for: senses, examples, path taken, refusals, timings, errors. Mechanical checks are asserted per
// word and reported; none of them aborts the run. The judged checks are left to the reader: the
// report ends with the judged table, pre-filled with the actual senses and an empty verdict column.
//
// Output: a Markdown report and a JSON twin, attached to the test (XCTAttachment) and printed
// between `=== REPORT BEGIN ===` / `=== REPORT END ===` (and `=== JSON BEGIN ===` / `=== JSON END ===`)
// so they can be pulled from the xcodebuild log without opening the .xcresult.
//
// Preconditions that fail the run loudly instead of passing with an empty report: no words, model
// unavailable, WordNet bundle missing, en→ru Translation pack not installed.
//
// Smoke runs: `TEST_RUNNER_REGRESSION_WORDS="book,however" xcodebuild test …` restricts the list
// (xcodebuild strips the TEST_RUNNER_ prefix). `TEST_RUNNER_GIT_COMMIT=$(git rev-parse --short HEAD)`
// puts the commit into the report header.
//
// Throwaway code. Not held to the root CLAUDE.md conventions (XCTest and print are fine here).

import FoundationModels
import Translation
import UIKit
import WordhoardCore
import XCTest

// MARK: - Word list

struct RegressionWord: Sendable {
    let number: Int
    let word: String
    let why: String
    let check: String
}

enum RegressionWordList {
    /// Parses the `| n | word | why | what to check |` rows of docs/regression-words.md.
    static func parse(markdown: String) -> [RegressionWord] {
        var words: [RegressionWord] = []
        for line in markdown.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }
            let cells = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, let number = Int(cells[0]), !cells[1].isEmpty else { continue }
            words.append(RegressionWord(
                number: number,
                word: cells[1],
                why: cells.count > 2 ? cells[2] : "",
                check: cells.count > 3 ? cells[3] : ""
            ))
        }
        return words
    }
}

// MARK: - Per-word record (the JSON twin's shape)

struct SenseRecord: Codable, Sendable {
    let partOfSpeech: String
    let source: String
    let gloss: String?
    let definition: String
    let translation: String
    let synonyms: [String]
    let antonyms: [String]
    let examples: [ExampleRecord]
}

struct ExampleRecord: Codable, Sendable {
    let topic: String
    let text: String
}

struct CheckRecord: Codable, Sendable {
    let name: String
    /// `nil` when the check does not apply to this word (e.g. no card by design).
    let passed: Bool?
    let detail: String
    let flagged: Bool
}

struct WordRecord: Codable, Sendable {
    let number: Int
    let word: String
    let headwordTranslation: String
    let path: String
    let wordNetNote: String?
    let verificationNote: String?
    let translationNote: String?
    let error: String?
    let refusals: [String]
    let failures: [String]
    let callCount: Int
    let lookupSeconds: Double?
    let sensesSeconds: Double?
    let translationSeconds: Double?
    let translationCalls: Int
    let translationStrings: Int
    let firstCardSeconds: Double?
    let fullCardSeconds: Double?
    let wallSeconds: Double
    let senses: [SenseRecord]
    let checks: [CheckRecord]
}

/// A refused or failed model call the generator recorded as a `GenerationNote` (A6). The note does not
/// say whether the guardrail refused or the call failed, so every note counts as a refusal here.
struct CallFailure: Sendable {
    let label: String
    let isRefusal: Bool

    init?(_ note: GenerationNote) {
        switch note {
        case let .definitionRefused(senseIndex):
            label = "write: sense \(senseIndex + 1) refused or failed, gloss kept"
            isRefusal = true
        case let .exampleRefused(senseIndex, topic):
            label = "example: sense \(senseIndex + 1) / \(topic ?? "en.neutral") refused, failed or does not fit"
            isRefusal = true
        case let .exampleDropped(senseIndex, topic):
            label = "example: sense \(senseIndex + 1) / \(topic ?? "en.neutral") dropped, no headword after a retry"
            isRefusal = false
        case .senseSelectionFellBack:
            label = "select senses: refused, failed or unusable, 2-per-part-of-speech fallback"
            isRefusal = false
        case .translationUnavailable:
            return nil
        }
    }
}

struct RunReport: Codable, Sendable {
    let date: String
    let device: String
    let system: String
    let commit: String?
    let pipeline: String
    let topics: [String]
    let maxSensesPerPartOfSpeech: Int
    let maxSensesTotal: Int
    let words: [WordRecord]
}

// MARK: - Mechanical checks

enum MechanicalChecks {
    static let names = [
        "generated without error",
        "1 ≤ senses ≤ 4, no duplicate definitions",
        "translation: non-empty, Cyrillic, no 3× token",
        "every example contains the headword",
        "present_perfect pattern",
        "second_conditional pattern",
        "passive_voice pattern",
        "full card ≤ 30 s",
    ]

    /// Irregular past participles / past forms the stem match and the grammar checks accept.
    static let irregularForms: Set<String> = [
        "been", "gone", "done", "seen", "read", "led", "lit", "run", "ran", "set", "given", "gave", "taken", "took",
        "made", "had", "said", "got", "gotten", "put", "left", "found", "kept", "felt", "told", "thought",
        "brought", "bought", "caught", "taught", "built", "sent", "spent", "lost", "met", "paid", "heard",
        "held", "cut", "hit", "let", "shut", "hurt", "won", "sat", "stood", "understood", "begun", "become",
        "came", "come", "drunk", "sung", "swum", "written", "broken", "broke", "spoken", "chosen", "forgotten",
        "known", "grown", "thrown", "shown", "flown", "drawn", "worn", "torn", "born", "sworn", "shaken",
        "woken", "hidden", "ridden", "driven", "risen", "fallen", "eaten", "beaten", "bitten", "forbidden",
        "struck", "stuck", "sold", "fed", "bled", "fled", "slept", "swept", "wept", "dreamt", "learnt",
        "burnt", "spelt", "meant", "lent", "bent", "dealt", "shot", "bred", "sped", "laid", "slid", "split",
        "spread", "quit", "bet", "cost", "bid", "wed", "overcome", "undertaken", "withdrawn", "misled", "lain",
    ]

    /// Lowercased tokens with punctuation stripped; apostrophes kept so "'d" survives.
    static func tokens(_ sentence: String) -> [String] {
        sentence.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    static func isParticipleLike(_ token: String) -> Bool {
        let bare = token.replacingOccurrences(of: "'", with: "")
        return bare.hasSuffix("ed") || bare.hasSuffix("en") || irregularForms.contains(bare)
    }

    /// Simple stem match: every word of the headword must appear in the sentence as a token that
    /// starts with its stem (the word minus a final "e" when long enough), or as a listed irregular form.
    static func containsHeadword(_ headword: String, in sentence: String) -> Bool {
        let sentenceTokens = tokens(sentence)
        for part in headword.lowercased().split(separator: " ").map(String.init) {
            var stem = part
            if stem.count >= 4, stem.hasSuffix("e") { stem.removeLast() }
            let irregular = irregularForms(for: part)
            let found = sentenceTokens.contains { token in
                token.hasPrefix(stem) || irregular.contains(token)
            }
            if !found { return false }
        }
        return true
    }

    /// Hand-listed irregular inflections for the regression words that have them.
    static func irregularForms(for word: String) -> Set<String> {
        switch word {
        case "run": ["ran"]
        case "give": ["gave", "given"]
        case "lead": ["led"]
        case "light": ["lit"]
        case "break": ["broke", "broken"]
        case "read": ["read"]
        case "set": ["set"]
        default: []
        }
    }

    /// have/has followed within 3 tokens by -ed/-en or an irregular participle.
    static func looksLikePresentPerfect(_ sentence: String) -> Bool {
        let tokens = tokens(sentence)
        for (index, token) in tokens.enumerated() {
            let bare = token.replacingOccurrences(of: "n't", with: "")
            let isAuxiliary = ["have", "has", "'ve", "'s"].contains(bare) || token.hasSuffix("'ve") || token.hasSuffix("'s")
            guard isAuxiliary else { continue }
            for offset in 1...3 where index + offset < tokens.count {
                if isParticipleLike(tokens[index + offset]) { return true }
            }
        }
        return false
    }

    /// Contains "if" and would/could/might (or a 'd contraction).
    static func looksLikeSecondConditional(_ sentence: String) -> Bool {
        let tokens = tokens(sentence)
        let hasIf = tokens.contains("if")
        let hasModal = tokens.contains { token in
            let bare = token.replacingOccurrences(of: "n't", with: "")
            return ["would", "could", "might"].contains(bare) || token.hasSuffix("'d")
        }
        return hasIf && hasModal
    }

    /// was/were/been/being/is/are followed within 2 tokens by -ed/-en or an irregular participle.
    static func looksLikePassive(_ sentence: String) -> Bool {
        let tokens = tokens(sentence)
        for (index, token) in tokens.enumerated() {
            let bare = token.replacingOccurrences(of: "n't", with: "")
            guard ["was", "were", "been", "being", "is", "are"].contains(bare) else { continue }
            for offset in 1...2 where index + offset < tokens.count {
                if isParticipleLike(tokens[index + offset]) { return true }
            }
        }
        return false
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// A token that appears three or more times ("ночальница, ночальница, ночальница").
    static func repeatedToken(in text: String) -> String? {
        var counts: [String: Int] = [:]
        for token in tokens(text) where token.count > 1 {
            counts[token, default: 0] += 1
        }
        return counts.first { $0.value >= 3 }?.key
    }
}

// MARK: - The test

@MainActor
final class RegressionRunnerTests: XCTestCase {
    private static let nativeLanguage = "ru"
    private static let source = Locale.Language(identifier: "en")
    private static let target = Locale.Language(identifier: nativeLanguage)
    private static let topicKeys = ["en.present_perfect", "en.second_conditional", "en.passive_voice"]
    private static let fullCardBudget: Double = 30

    func testRegressionWordList() async throws {
        // --- Preconditions: every one of these fails loudly rather than passing with an empty report.
        guard let listURL = Bundle(for: Self.self).url(forResource: "regression-words", withExtension: "md") else {
            XCTFail("regression-words.md is not in the test bundle; check the resources build phase")
            return
        }
        let markdown = try String(contentsOf: listURL, encoding: .utf8)
        var words = RegressionWordList.parse(markdown: markdown)
        if let override = ProcessInfo.processInfo.environment["REGRESSION_WORDS"], !override.isEmpty {
            let wanted = override.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let known = Dictionary(uniqueKeysWithValues: words.map { ($0.word.lowercased(), $0) })
            words = wanted.enumerated().map { index, word in
                known[word] ?? RegressionWord(number: 100 + index, word: word, why: "ad hoc (REGRESSION_WORDS)", check: "")
            }
            print("regression: REGRESSION_WORDS override → \(words.map(\.word))")
        }
        guard !words.isEmpty else {
            XCTFail("zero words parsed from regression-words.md — the table format changed or the file is empty")
            return
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case let .unavailable(reason):
            XCTFail("language model unavailable: \(String(describing: reason)) — run on an iPhone with Apple Intelligence enabled")
            return
        }

        guard CoreInfo.resourceBundle.url(forResource: "WordNet/oewn-2024", withExtension: "json") != nil else {
            XCTFail("WordNet bundle oewn-2024.json is missing from WordhoardCore's resources")
            return
        }
        guard await WordNetLookup.shared.entry(for: "book") != nil else {
            XCTFail("WordNet bundle did not load or has no entry for \"book\"")
            return
        }

        let translationStatus = await LanguageAvailability().status(from: Self.source, to: Self.target)
        guard translationStatus == .installed else {
            XCTFail("en→ru Translation language pack is not installed (status: \(translationStatus)); download English and Russian in the Translate app")
            return
        }

        let catalog = GrammarCatalog.english
        let topics = Self.topicKeys.compactMap { catalog.topic(for: $0) }
        guard topics.count == Self.topicKeys.count else {
            XCTFail("the grammar catalog lacks one of \(Self.topicKeys)")
            return
        }

        // --- The run: the product generator with its real collaborators.
        let device = UIDevice.current
        let commit = ProcessInfo.processInfo.environment["GIT_COMMIT"]
        var records: [WordRecord] = []
        let clock = ContinuousClock()
        let generator = FoundationModelsCardGenerator()

        for entry in words {
            print("regression: ▶ \(entry.number). \(entry.word)")
            let request = CardRequest(headword: entry.word, nativeLanguage: Self.nativeLanguage, topics: topics)
            let start = clock.now
            var card: GeneratedCard?
            var errorText: String?
            var firstCard: Duration?
            var fullCard: Duration?
            var topicExamples: [GeneratedTopicExample] = []
            do {
                card = try await generator.generateCard(request)
                firstCard = clock.now - start
                if let produced = card, !produced.senses.isEmpty {
                    for try await example in generator.generateTopicExamples(for: produced, request: request) {
                        topicExamples.append(example)
                    }
                    fullCard = clock.now - start
                }
            } catch {
                errorText = String(describing: error)
                print("regression: \(entry.word) failed: \(error)")
            }
            let wall = clock.now - start
            let record = Self.record(
                for: entry, card: card, topicExamples: topicExamples, error: errorText,
                topicCount: topics.count, firstCard: firstCard, fullCard: fullCard, wall: wall
            )
            records.append(record)
            let verdicts = record.checks.map { check in
                switch check.passed {
                case .some(true): check.flagged ? "pass*" : "pass"
                case .some(false): "FAIL"
                case .none: "n/a"
                }
            }
            print("regression: ◀ \(entry.word) · \(record.path) · \(record.senses.count) senses · full \(record.fullCardSeconds.map { String(format: "%.1f s", $0) } ?? "—") · \(verdicts.joined(separator: " "))")
        }

        let report = RunReport(
            date: ISO8601DateFormatter().string(from: Date()),
            device: "\(device.model) \(Self.hardwareIdentifier())",
            system: "\(device.systemName) \(device.systemVersion)",
            commit: commit,
            pipeline: "WordhoardCore.FoundationModelsCardGenerator (stoplist → WordNet → definition call per sense → Translation en→ru, one batch → neutral example per sense → topic examples; model-only fallback with verifier)",
            topics: topics.map(\.key),
            maxSensesPerPartOfSpeech: WordNetLookup.maxSensesPerPartOfSpeech,
            maxSensesTotal: WordNetLookup.maxSensesTotal,
            words: records
        )

        let markdownReport = ReportWriter.markdown(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        let jsonReport = String(decoding: jsonData, as: UTF8.self)

        let markdownAttachment = XCTAttachment(string: markdownReport)
        markdownAttachment.name = "regression-report.md"
        markdownAttachment.lifetime = .keepAlways
        add(markdownAttachment)
        let jsonAttachment = XCTAttachment(data: jsonData, uniformTypeIdentifier: "public.json")
        jsonAttachment.name = "regression-report.json"
        jsonAttachment.lifetime = .keepAlways
        add(jsonAttachment)

        // Also on disk in the app container, in case the log is truncated.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documents {
            try? markdownReport.write(to: documents.appendingPathComponent("regression-report.md"), atomically: true, encoding: .utf8)
            try? jsonData.write(to: documents.appendingPathComponent("regression-report.json"))
        }

        print("=== REPORT BEGIN ===")
        print(markdownReport)
        print("=== REPORT END ===")
        print("=== JSON BEGIN ===")
        print(jsonReport)
        print("=== JSON END ===")

        // The run itself passes as long as it ran; individual check failures are in the report.
        // The one assertion that must hold for the report to mean anything:
        XCTAssertEqual(records.count, words.count, "every word must produce a record")
    }

    /// "iPhone16,2" and the like; `UIDevice.name` is just "iPhone" without an entitlement.
    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Recording

    // swiftlint:disable:next function_parameter_count
    private static func record(
        for entry: RegressionWord,
        card: GeneratedCard?,
        topicExamples: [GeneratedTopicExample],
        error: String?,
        topicCount: Int,
        firstCard: Duration?,
        fullCard: Duration?,
        wall: Duration
    ) -> WordRecord {
        let senses: [SenseRecord] = (card?.senses ?? []).enumerated().map { index, sense in
            var examples: [ExampleRecord] = []
            if let neutral = sense.neutralExample {
                examples.append(ExampleRecord(topic: "en.neutral", text: neutral.text))
            }
            for example in topicExamples where example.senseIndex == index {
                examples.append(ExampleRecord(topic: example.example.grammarTopic ?? "en.neutral", text: example.example.text))
            }
            return SenseRecord(
                partOfSpeech: sense.partOfSpeech.rawValue,
                source: sense.senseSource.rawValue,
                gloss: sense.gloss,
                definition: sense.definition,
                translation: sense.translation ?? "",
                synonyms: sense.synonyms,
                antonyms: sense.antonyms,
                examples: examples
            )
        }
        let path = card?.path.rawValue ?? "error"
        let notes = card?.notes ?? []
        let callFailures = notes.compactMap(CallFailure.init)
        let translationNote = notes.compactMap { note -> String? in
            if case let .translationUnavailable(language) = note {
                return "Translation: en→\(language) language pack not installed or batch failed → no translation"
            }
            return nil
        }.first
        let translated = card.map { !$0.senses.isEmpty && translationNote == nil } ?? false
        // The generator does not expose a call count; this is the number of model calls its pipeline
        // makes for what it returned (the verify calls of a model-only word are counted as one per kept sense).
        let callCount: Int
        switch card?.path {
        case .wordnet: callCount = 2 * senses.count + topicExamples.count + senses.count * topicCount - topicExamples.count
        case .stoplist, .modelOnly: callCount = 1 + 2 * senses.count + senses.count * topicCount
        case .notFound: callCount = 1
        case nil: callCount = 0
        }
        let fullCardSeconds = fullCard?.seconds ?? (card?.path == .notFound ? wall.seconds : nil)

        let checks = checks(
            word: entry.word,
            path: card?.path,
            error: error,
            callFailures: callFailures,
            senses: senses,
            fullCardSeconds: fullCardSeconds,
            wallSeconds: wall.seconds
        )

        return WordRecord(
            number: entry.number,
            word: entry.word,
            headwordTranslation: "",
            path: path,
            wordNetNote: card.map { "path \($0.path.rawValue), \($0.senses.count) sense(s)" },
            verificationNote: card?.path == .notFound ? "Not found. Add senses manually. (WordNet has no usable entry and the verifier rejected every model sense.)" : nil,
            translationNote: translationNote,
            error: error,
            refusals: callFailures.filter(\.isRefusal).map(\.label),
            failures: callFailures.filter { !$0.isRefusal }.map(\.label),
            callCount: callCount,
            lookupSeconds: nil,
            sensesSeconds: nil,
            translationSeconds: nil,
            translationCalls: translated ? 1 : 0,
            translationStrings: translated ? senses.count : 0,
            firstCardSeconds: firstCard?.seconds,
            fullCardSeconds: fullCardSeconds,
            wallSeconds: wall.seconds,
            senses: senses,
            checks: checks
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func checks(
        word: String,
        path: GenerationPath?,
        error: String?,
        callFailures: [CallFailure],
        senses: [SenseRecord],
        fullCardSeconds: Double?,
        wallSeconds: Double
    ) -> [CheckRecord] {
        var checks: [CheckRecord] = []
        let names = MechanicalChecks.names
        let notFound = path == .notFound

        // 1. generated without error. A refused/failed definition call (gloss kept) is a flagged pass; a
        //    skipped neutral example is a failure. Topic-example refusals are not visible to the runner (the
        //    generator yields nothing and logs them); they show up as "no example for this topic".
        let exampleFailures = callFailures.filter { $0.label.hasPrefix("example") }
        let otherFailures = callFailures.filter { !$0.label.hasPrefix("example") }
        if let error {
            checks.append(CheckRecord(name: names[0], passed: false, detail: error, flagged: false))
        } else if !exampleFailures.isEmpty {
            checks.append(CheckRecord(name: names[0], passed: false, detail: "\(exampleFailures.count) example call(s) failed: \(exampleFailures.map(\.label).joined(separator: "; "))", flagged: false))
        } else if !otherFailures.isEmpty {
            let refusals = otherFailures.filter(\.isRefusal).count
            checks.append(CheckRecord(name: names[0], passed: true, detail: "\(otherFailures.count) call(s) failed with fallback (\(refusals) refusal(s)): \(otherFailures.map(\.label).joined(separator: "; "))", flagged: true))
        } else {
            checks.append(CheckRecord(name: names[0], passed: true, detail: "", flagged: false))
        }

        // 2. sense count and duplicates.
        if notFound {
            checks.append(CheckRecord(name: names[1], passed: nil, detail: "no card: not found", flagged: false))
        } else {
            let definitions = senses.map { $0.definition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let duplicates = Set(definitions).count != definitions.count
            let countOK = (1...4).contains(senses.count)
            var detail = "\(senses.count) sense(s)"
            if duplicates { detail += ", duplicate definitions" }
            checks.append(CheckRecord(name: names[1], passed: countOK && !duplicates, detail: detail, flagged: false))
        }

        // 3. translation.
        if notFound || senses.isEmpty {
            checks.append(CheckRecord(name: names[2], passed: nil, detail: "no senses", flagged: false))
        } else {
            // No headword translation since ADR 0001 / A9: only the per-sense translations are checked.
            var problems: [String] = []
            for (index, sense) in senses.enumerated() {
                let translation = sense.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                if translation.isEmpty || translation == "…" {
                    problems.append("sense \(index + 1): empty")
                } else if !MechanicalChecks.containsCyrillic(translation) {
                    problems.append("sense \(index + 1): no Cyrillic (\(translation))")
                } else if let repeated = MechanicalChecks.repeatedToken(in: translation) {
                    problems.append("sense \(index + 1): \"\(repeated)\" repeated 3×")
                }
            }
            checks.append(CheckRecord(name: names[2], passed: problems.isEmpty, detail: problems.joined(separator: "; "), flagged: false))
        }

        // 4. headword in every example.
        let allExamples = senses.enumerated().flatMap { index, sense in sense.examples.map { (index, $0) } }
        if notFound || allExamples.isEmpty {
            checks.append(CheckRecord(name: names[3], passed: nil, detail: "no examples", flagged: false))
        } else {
            let misses = allExamples.filter { !MechanicalChecks.containsHeadword(word, in: $0.1.text) }
            let detail = misses.map { "sense \($0.0 + 1) [\($0.1.topic.replacingOccurrences(of: "en.", with: ""))]: \($0.1.text)" }.joined(separator: "; ")
            checks.append(CheckRecord(name: names[3], passed: misses.isEmpty, detail: detail, flagged: false))
        }

        // 5–7. grammar patterns, per topic over the examples that were produced for that topic.
        let patterns: [(String, String, (String) -> Bool)] = [
            (names[4], "en.present_perfect", MechanicalChecks.looksLikePresentPerfect),
            (names[5], "en.second_conditional", MechanicalChecks.looksLikeSecondConditional),
            (names[6], "en.passive_voice", MechanicalChecks.looksLikePassive),
        ]
        for (name, topic, test) in patterns {
            let examples = allExamples.filter { $0.1.topic == topic }
            if notFound || examples.isEmpty {
                checks.append(CheckRecord(name: name, passed: nil, detail: notFound ? "no card" : "no example for this topic (skipped by the model)", flagged: false))
            } else {
                let misses = examples.filter { !test($0.1.text) }
                let detail = misses.map { "sense \($0.0 + 1): \($0.1.text)" }.joined(separator: "; ")
                checks.append(CheckRecord(name: name, passed: misses.isEmpty, detail: detail, flagged: false))
            }
        }

        // 8. timing.
        if let fullCardSeconds {
            checks.append(CheckRecord(name: names[7], passed: fullCardSeconds <= fullCardBudget, detail: String(format: "%.1f s", fullCardSeconds), flagged: false))
        } else {
            checks.append(CheckRecord(name: names[7], passed: false, detail: String(format: "no full card after %.1f s", wallSeconds), flagged: false))
        }

        return checks
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

// MARK: - Markdown report

enum ReportWriter {
    /// Words with an expected result in issue #14's judged table, in its order.
    static let judged: [(word: String, expected: String)] = [
        ("book", "noun *book*; verb *reserve* with a definition about reserving, not rehearsing"),
        ("run", "verb *move fast*; verb *manage/operate*; noun optional"),
        ("light", "noun; adjective; verb"),
        ("look up", "verb *search for information* (one sense is correct)"),
        ("give up", "verb *stop trying / surrender* as one phrasal entry"),
        ("by the book", "one `phrase` sense, idiomatic (rules), via fallback"),
        ("however", "model-only via stoplist; exactly one adverb sense *but/nevertheless*"),
        ("despite", "model-only via stoplist; one preposition/phrase sense *in spite of*"),
        ("lead", "≥ 1 noun (metal or leadership) and ≥ 1 verb"),
        ("gaslight", "noun *lamp* shown; verb absent → acceptable, flagged \"WordNet gap\""),
        ("asdfgh", "\"not found\" state; no invented sense displayed"),
        ("Tashkent", "\"not found\" or proper-noun refusal; no invented sense"),
    ]

    static func markdown(_ report: RunReport) -> String {
        var out: [String] = []
        out.append("# Regression run — \(report.date)")
        out.append("")
        out.append("- Device: \(report.device), \(report.system)")
        out.append("- Commit: \(report.commit ?? "(not passed; set TEST_RUNNER_GIT_COMMIT)")")
        out.append("- Pipeline: \(report.pipeline)")
        out.append("- Topics: \(report.topics.joined(separator: ", ")) · cap: \(report.maxSensesPerPartOfSpeech) senses per part of speech, \(report.maxSensesTotal) in all")
        out.append("- Words: \(report.words.count)")
        out.append("")

        // Mechanical summary.
        var total = 0
        var passed = 0
        var perCheck: [String: (passed: Int, total: Int, flagged: Int)] = [:]
        for word in report.words {
            for check in word.checks {
                guard let ok = check.passed else { continue }
                total += 1
                if ok { passed += 1 }
                var entry = perCheck[check.name] ?? (0, 0, 0)
                entry.total += 1
                if ok { entry.passed += 1 }
                if check.flagged { entry.flagged += 1 }
                perCheck[check.name] = entry
            }
        }
        let rate = total == 0 ? 0 : Double(passed) / Double(total) * 100
        out.append("## Mechanical checks: \(passed)/\(total) (\(String(format: "%.1f", rate)) %)")
        out.append("")
        out.append("| check | passed | of | flagged |")
        out.append("|---|---|---|---|")
        for name in MechanicalChecks.names {
            let entry = perCheck[name] ?? (0, 0, 0)
            out.append("| \(name) | \(entry.passed) | \(entry.total) | \(entry.flagged) |")
        }
        out.append("")

        // Timing.
        let fulls = report.words.compactMap(\.fullCardSeconds).sorted()
        let firsts = report.words.compactMap(\.firstCardSeconds).sorted()
        func median(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "—" }
            let mid = values.count / 2
            let value = values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
            return String(format: "%.1f s", value)
        }
        out.append("## Timing")
        out.append("")
        out.append("- First card: median \(median(firsts)), max \(firsts.last.map { String(format: "%.1f s", $0) } ?? "—")")
        out.append("- Full card: median \(median(fulls)), max \(fulls.last.map { String(format: "%.1f s", $0) } ?? "—"), over 30 s: \(fulls.filter { $0 > 30 }.count)")
        out.append("- Total wall time: \(String(format: "%.0f s", report.words.map(\.wallSeconds).reduce(0, +)))")
        out.append("")

        // Overview table.
        out.append("## Overview")
        out.append("")
        out.append("| # | word | path | senses | first s | full s | checks | failed checks |")
        out.append("|---|---|---|---|---|---|---|---|")
        for word in report.words {
            let applicable = word.checks.filter { $0.passed != nil }
            let ok = applicable.filter { $0.passed == true }.count
            let failed = word.checks.filter { $0.passed == false }.map(\.name).joined(separator: "; ")
            let senseSummary = word.senses.map(\.partOfSpeech).joined(separator: ", ")
            out.append("| \(word.number) | \(word.word) | \(word.path) | \(word.senses.count) (\(senseSummary)) | \(seconds(word.firstCardSeconds)) | \(seconds(word.fullCardSeconds)) | \(ok)/\(applicable.count) | \(failed) |")
        }
        out.append("")

        // Judged table skeleton.
        out.append("## Judged checks (fill the verdict column)")
        out.append("")
        out.append("| word | expected | actual senses | verdict |")
        out.append("|---|---|---|---|")
        for (word, expected) in judged {
            if let record = report.words.first(where: { $0.word.lowercased() == word.lowercased() }) {
                let actual: String
                if record.path == GenerationPath.notFound.rawValue {
                    actual = "not found (\(record.verificationNote ?? ""))"
                } else if record.senses.isEmpty {
                    actual = "no senses (\(record.error ?? record.path))"
                } else {
                    actual = record.senses.enumerated().map { index, sense in
                        "\(index + 1). \(sense.partOfSpeech) [\(sense.source)] \(sense.definition) — \(sense.translation)"
                    }.joined(separator: "<br>")
                }
                let headword = record.headwordTranslation.isEmpty ? "" : " (\(record.headwordTranslation))"
                out.append("| \(word)\(headword) | \(expected) | \(record.path): \(actual) | |")
            } else {
                out.append("| \(word) | \(expected) | (not in this run) | |")
            }
        }
        out.append("")
        out.append("Translation sanity (real Russian for the sense, not just Cyrillic): ")
        out.append("")

        // Per word.
        out.append("## Words")
        for word in report.words {
            out.append("")
            out.append("### \(word.number). \(word.word)\(word.headwordTranslation.isEmpty ? "" : " — \(word.headwordTranslation)")")
            out.append("")
            out.append("- Path: `\(word.path)`" + (word.wordNetNote.map { " — \($0)" } ?? ""))
            if let note = word.verificationNote { out.append("- Verifier: \(note)") }
            if let note = word.translationNote { out.append("- Translation: \(note)") }
            if let error = word.error { out.append("- **Error:** \(error)") }
            if !word.refusals.isEmpty { out.append("- **Refusals:** \(word.refusals.joined(separator: " · "))") }
            if !word.failures.isEmpty { out.append("- **Failed calls:** \(word.failures.joined(separator: " · "))") }
            out.append("- Calls: \(word.callCount) · lookup \(seconds(word.lookupSeconds)) · senses \(seconds(word.sensesSeconds)) · translation \(seconds(word.translationSeconds)) (\(word.translationCalls) call\(word.translationCalls == 1 ? "" : "s"), \(word.translationStrings) strings) · first card \(seconds(word.firstCardSeconds)) · full card \(seconds(word.fullCardSeconds)) · wall \(seconds(word.wallSeconds))")
            for (index, sense) in word.senses.enumerated() {
                out.append("- Sense \(index + 1) — \(sense.partOfSpeech) [\(sense.source)]")
                if let gloss = sense.gloss { out.append("  - gloss: \(gloss)") }
                out.append("  - definition: \(sense.definition)")
                out.append("  - translation: \(sense.translation.isEmpty ? "—" : sense.translation)")
                out.append("  - synonyms: \(sense.synonyms.isEmpty ? "—" : sense.synonyms.joined(separator: ", "))")
                out.append("  - antonyms: \(sense.antonyms.isEmpty ? "—" : sense.antonyms.joined(separator: ", "))")
                for example in sense.examples {
                    out.append("  - [\(example.topic.replacingOccurrences(of: "en.", with: ""))] \(example.text)")
                }
            }
            out.append("- Checks:")
            for check in word.checks {
                let mark: String = switch check.passed {
                case .some(true): check.flagged ? "pass (flagged)" : "pass"
                case .some(false): "**FAIL**"
                case .none: "n/a"
                }
                out.append("  - \(check.name): \(mark)" + (check.detail.isEmpty ? "" : " — \(check.detail)"))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
}
