import Foundation
import Testing
import WordhoardCore

/// Plan 2.6 (#18): the model picks ≤ 4 senses from WordNet's list. The pipeline runs over
/// `ScriptedModelCalls`; *book* at five senses per part of speech is a synthetic bundle shaped like the
/// regenerated one (noun 1…5, verb 1 *engage*, verb 2 *reserve*, verb 3…5), because the shipped bundle
/// still holds two per part of speech and so gives *book* exactly four senses and no call.
@Suite("Sense selection")
struct SenseSelectionTests {
    private typealias Answer = @Sendable () throws -> [Int]
    private static let reserveGloss = "arrange for and reserve (something for someone else) in advance"

    /// `book` with 5 nouns and 5 verbs; synsets 0…4 are the nouns, 5…9 the verbs.
    private static func bigBookLookup() throws -> WordNetLookup {
        let nouns = (1 ... 5).map { "[\"noun gloss \($0)\"]" }
        let verbs = [
            "[\"engage for a performance\"]",
            "[\"\(reserveGloss)\",[\"book\",\"reserve\",\"hold\"]]",
            "[\"verb gloss 3\"]", "[\"verb gloss 4\"]", "[\"verb gloss 5\"]",
        ]
        let json = """
        {"edition":"test","synsets":[\((nouns + verbs).joined(separator: ","))],
         "lemmas":{"book":{"n":[0,1,2,3,4],"v":[5,6,7,8,9]},"tome":{"n":[0]}}}
        """
        return try WordNetLookup(bundle: temporaryWordNetBundle(files: [
            "oewn-2024.json": json,
            "function-words.txt": "# Discourse adverbs and connectives\nhowever\n",
        ]))
    }

    private static func glosses(_ card: GeneratedCard) -> [String] {
        card.senses.compactMap(\.gloss)
    }

    // MARK: - Bundle

    @Test(
        "the bundle carries *book* → *reserve* within 20 MB; *run* → *direct or control* needs the regenerated bundle"
    )
    func theBiggerBundleCarriesRunManageAndBookReserve() async throws {
        let url = try #require(CoreInfo.resourceBundle.url(
            forResource: "oewn-2024", withExtension: "json", subdirectory: "WordNet"
        ))
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= 20 * 1_048_576)

        let book = try #require(await WordNetLookup.shared.entry(for: "book"))
        #expect(book.senses.contains { $0.partOfSpeech == .verb && $0.synonyms.contains("reserve") })

        let run = try #require(await WordNetLookup.shared.entry(for: "run"))
        withKnownIssue("the 5-per-part-of-speech bundle is not generated yet; the owner regenerates it (#18)") {
            #expect(run.senses.count > 4)
            #expect(run.senses.contains { $0.partOfSpeech == .verb && $0.gloss.contains("direct or control") })
        }
    }

    // MARK: - Candidates

    @Test("candidates are WordNet's senses round-robin by part of speech, capped at ten")
    func candidatesAreRoundRobinByPartOfSpeechAndCapped() async throws {
        let book = try #require(await Self.bigBookLookup().entry(for: "book"))
        #expect(book.senses.count == 10)
        let candidates = book.candidates
        #expect(candidates.count == 10)
        #expect(candidates.map(\.partOfSpeech) == [
            .noun,
            .verb,
            .noun,
            .verb,
            .noun,
            .verb,
            .noun,
            .verb,
            .noun,
            .verb,
        ])
        #expect(candidates.map(\.gloss).prefix(4) == [
            "noun gloss 1", "engage for a performance", "noun gloss 2", Self.reserveGloss,
        ])

        let light = try #require(await WordNetLookup.shared.entry(for: "light"))
        #expect(light.candidates.map(\.partOfSpeech) == [.noun, .verb, .adjective, .adverb, .noun, .verb, .adjective])

        let many = (0 ..< 4).flatMap { rank in
            [PartOfSpeech.noun, .verb, .adjective, .adverb].map {
                WordNetSense(partOfSpeech: $0, gloss: "\($0) \(rank)", synonyms: [], antonyms: [], example: nil)
            }
        }
        let capped = WordNetLookup.candidates(many.sorted { $0.partOfSpeech.rawValue < $1.partOfSpeech.rawValue })
        #expect(capped.count == WordNetLookup.maxCandidates)
        #expect(capped.prefix(4).map(\.partOfSpeech) == [.noun, .verb, .adjective, .adverb])
        #expect(capped.map(\.gloss).suffix(2) == ["noun 2", "verb 2"])
    }

    @Test("the selection prompt numbers every candidate from 1 with its part of speech and gloss")
    func selectionPromptListsTheCandidates() async throws {
        let book = try #require(await Self.bigBookLookup().entry(for: "book"))
        let prompt = SenseSelectionPrompt.prompt(headword: "book", candidates: book.candidates)
        #expect(prompt.contains("1. (noun) noun gloss 1"))
        #expect(prompt.contains("4. (verb) \(Self.reserveGloss)"))
        #expect(prompt.contains("10. (verb) verb gloss 5"))
        #expect(!prompt.contains("11."))
        #expect(SenseSelectionPrompt.instructions.contains("Include every part of speech that has a common sense"))
        #expect(!SenseSelectionPrompt.instructions.lowercased().contains("translat"))
    }

    // MARK: - Applying the answer

    @Test("the model's picks become the senses, regrouped by part of speech, with every part covered, or fall back")
    func selectionIsAppliedWithPosCoverageAndFallback() async throws {
        let lookup = try Self.bigBookLookup()

        func card(_ answer: @escaping Answer) async throws -> (GeneratedCard, ScriptedModelCalls) {
            let calls = ScriptedModelCalls(script: .init(selectSenses: { _, _ in try answer() }))
            let card = try await makeGenerator(calls, lookup: lookup).generateCard(makeRequest("book", native: nil))
            return (card, calls)
        }

        let (picked, pickedCalls) = try await card { [7, 0, 2] }
        #expect(Self.glosses(picked) == ["noun gloss 1", "noun gloss 2", "engage for a performance", "verb gloss 4"])
        #expect(picked.notes.isEmpty)
        #expect(pickedCalls.calls(.selectSenses).count == 1)
        #expect(pickedCalls.calls.first?.method == .selectSenses, "selection precedes every definition")
        #expect(pickedCalls.calls(.writeDefinition).count == 4, "definitions only for the selected senses")
        if case let .some(.selectSenses(headword, candidates)) = pickedCalls.calls.first {
            #expect(headword == "book")
            #expect(candidates.count == 10)
        }

        let (twoNouns, _) = try await card { [0, 2] }
        #expect(
            Self.glosses(twoNouns) == ["noun gloss 1", "noun gloss 2", "engage for a performance", Self.reserveGloss],
            "two nouns → a verb is added for coverage, then *reserve* fills the last slot"
        )
        #expect(twoNouns.notes.isEmpty)

        let (fourNouns, _) = try await card { [0, 2, 4, 6] }
        #expect(
            Self.glosses(fourNouns) == ["noun gloss 1", "noun gloss 2", "noun gloss 3", "engage for a performance"],
            "at four picks the last spare noun makes room for the verb"
        )

        let (five, _) = try await card { [0, 1, 2, 3, 9] }
        #expect(Self.glosses(five) == ["noun gloss 1", "noun gloss 2", "engage for a performance", Self.reserveGloss])

        let (duplicates, _) = try await card { [3, 3, -1, 0] }
        #expect(Self.glosses(duplicates) == [
            "noun gloss 1",
            "noun gloss 2",
            "engage for a performance",
            Self.reserveGloss,
        ])
        #expect(duplicates.notes.isEmpty, "partly invalid indices are dropped silently")

        let fallback = ["noun gloss 1", "noun gloss 2", "engage for a performance", Self.reserveGloss]
        let unusable: [Answer] = [
            { [42] },
            { [] },
            { throw ModelCallError.refused },
            { throw ModelCallError.failed("decoding") },
        ]
        for answer in unusable {
            let (fellBack, calls) = try await card(answer)
            #expect(Self.glosses(fellBack) == fallback)
            #expect(fellBack.notes == [.senseSelectionFellBack])
            #expect(calls.calls(.writeDefinition).count == 4)
        }
    }

    @Test("`selection` is pure: out-of-range indices alone give nil, coverage and fill never exceed four")
    func selectionPostProcessingIsPure() {
        let senses = [PartOfSpeech.noun, .verb, .adjective, .adverb, .noun, .verb, .adjective, .adverb].enumerated()
            .map {
                WordNetSense(partOfSpeech: $1, gloss: "g\($0)", synonyms: [], antonyms: [], example: nil)
            }
        #expect(WordNetLookup.selection([10, -3], from: senses) == nil)
        #expect(WordNetLookup.selection([], from: senses) == nil)
        let covered = WordNetLookup.selection([4, 5, 6, 7], from: senses)
        #expect(covered?.map(\.gloss) == ["g4", "g5", "g6", "g7"])
        let fromOne = WordNetLookup.selection([4], from: senses)
        #expect(fromOne?.map(\.gloss) == ["g4", "g1", "g2", "g3"], "rank 1 of each missing part, regrouped")
        #expect(fromOne?.map(\.partOfSpeech) == [.noun, .verb, .adjective, .adverb])

        let nouns = (1 ... 5).map {
            WordNetSense(partOfSpeech: .noun, gloss: "noun \($0)", synonyms: [], antonyms: [], example: nil)
        }
        #expect(
            WordNetLookup.selection([4], from: nouns)?.map(\.gloss) == ["noun 1", "noun 2", "noun 5"],
            "a short pick fills from the 2-per-part-of-speech set only, never with noun 3"
        )
    }

    // MARK: - No call

    @Test("lemmas with four senses or fewer and stoplist words make no selection call")
    func selectionIsSkippedForSmallEntries() async throws {
        for headword in ["look up", "gaslight", "book", "however"] {
            let calls = ScriptedModelCalls(script: .init(proposeSenses: { _ in [GeneratorFixtures.howeverSense] }))
            let card = try await makeGenerator(calls).generateCard(makeRequest(headword, native: nil))
            #expect(calls.calls(.selectSenses).isEmpty, "\(headword)")
            #expect(!card.notes.contains(.senseSelectionFellBack))
            #expect(!card.senses.isEmpty)
        }
        let calls = ScriptedModelCalls()
        let light = try await makeGenerator(calls).generateCard(makeRequest("light", native: nil))
        #expect(calls.calls(.selectSenses).count == 1, "the shipped bundle lists seven senses for *light*")
        #expect(light.senses.map(\.partOfSpeech) == [.noun, .verb, .adjective, .adverb])
    }
}
