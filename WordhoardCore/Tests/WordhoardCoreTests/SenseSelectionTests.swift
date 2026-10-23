import Foundation
import Testing
import WordhoardCore

/// Plan 2.6 (#18), reworked in Phase 7: the model ranks WordNet's senses by everyday frequency and
/// leaves out rare ones; the card keeps the model's order. The pipeline runs over `ScriptedModelCalls`;
/// *book* at five senses per part of speech is a small synthetic bundle (noun 1…5, verb 1 *engage*,
/// verb 2 *reserve*, verb 3…5) so the answers are easy to read.
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

    @Test("the bundle carries *book* → *reserve* and *run* → *direct or control* within 20 MB")
    func theBundleCarriesRunManageAndBookReserve() async throws {
        let url = try #require(CoreInfo.resourceBundle.url(
            forResource: "oewn-2024", withExtension: "json", subdirectory: "WordNet"
        ))
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size <= 20 * 1_048_576)

        let book = try #require(await WordNetLookup.shared.entry(for: "book"))
        #expect(book.senses.contains { $0.partOfSpeech == .verb && $0.synonyms.contains("reserve") })

        let run = try #require(await WordNetLookup.shared.entry(for: "run"))
        #expect(run.senses.count > 4)
        #expect(run.candidates.contains { $0.partOfSpeech == .verb && $0.gloss.contains("direct or control") })
    }

    // MARK: - Candidates

    @Test("candidates are WordNet's senses round-robin by part of speech, capped at twelve")
    func candidatesAreRoundRobinByPartOfSpeechAndCapped() async throws {
        let book = try #require(await Self.bigBookLookup().entry(for: "book"))
        #expect(book.senses.count == 10)
        let candidates = book.candidates
        #expect(candidates.count == 10)
        #expect(candidates.map(\.partOfSpeech) == [
            .noun, .verb, .noun, .verb, .noun, .verb, .noun, .verb, .noun, .verb,
        ])
        #expect(candidates.map(\.gloss).prefix(4) == [
            "noun gloss 1", "engage for a performance", "noun gloss 2", Self.reserveGloss,
        ])

        let many = (0 ..< 4).flatMap { rank in
            [PartOfSpeech.noun, .verb, .adjective, .adverb].map {
                WordNetSense(partOfSpeech: $0, gloss: "\($0) \(rank)", synonyms: [], antonyms: [], example: nil)
            }
        }
        let capped = WordNetLookup.candidates(many.sorted { $0.partOfSpeech.rawValue < $1.partOfSpeech.rawValue })
        #expect(capped.count == WordNetLookup.maxCandidates)
        #expect(capped.prefix(4).map(\.partOfSpeech) == [.noun, .verb, .adjective, .adverb])
        #expect(capped.map(\.gloss).suffix(4) == ["noun 2", "verb 2", "adjective 2", "adverb 2"])
    }

    @Test("the selection prompt numbers every candidate from 1 and asks for everyday meanings, most common first")
    func selectionPromptListsTheCandidates() async throws {
        let book = try #require(await Self.bigBookLookup().entry(for: "book"))
        let prompt = SenseSelectionPrompt.prompt(headword: "book", candidates: book.candidates)
        #expect(prompt.contains("1. (noun) noun gloss 1"))
        #expect(prompt.contains("4. (verb) \(Self.reserveGloss)"))
        #expect(prompt.contains("10. (verb) verb gloss 5"))
        #expect(!prompt.contains("11."))
        #expect(prompt.contains("most common"))
        #expect(SenseSelectionPrompt.instructions.contains("Leave out rare"))
        #expect(!SenseSelectionPrompt.instructions.lowercased().contains("translat"))
    }

    // MARK: - Applying the answer

    @Test("the model's ranking becomes the card in its order, rare senses are not added back, or it falls back")
    func selectionKeepsTheModelsOrderOrFallsBack() async throws {
        let lookup = try Self.bigBookLookup()

        func card(_ answer: @escaping Answer) async throws -> (GeneratedCard, ScriptedModelCalls) {
            let calls = ScriptedModelCalls(script: .init(selectSenses: { _, _ in try answer() }))
            let card = try await makeGenerator(calls, lookup: lookup).generateCard(makeRequest("book"))
            return (card, calls)
        }

        let (picked, pickedCalls) = try await card { [3, 0, 7] }
        #expect(Self.glosses(picked) == [Self.reserveGloss, "noun gloss 1", "verb gloss 4"], "the model's order")
        #expect(picked.notes.isEmpty)
        #expect(pickedCalls.calls(.selectSenses).count == 1)
        #expect(pickedCalls.calls.first?.method == .selectSenses, "selection precedes every definition")
        #expect(pickedCalls.calls(.writeDefinition).count == 3, "definitions only for the selected senses")
        if case let .some(.selectSenses(headword, candidates)) = pickedCalls.calls.first {
            #expect(headword == "book")
            #expect(candidates.count == 10)
        }

        let (one, _) = try await card { [3] }
        #expect(Self.glosses(one) == [Self.reserveGloss], "one common meaning stays one sense; nothing is filled in")

        let (five, _) = try await card { [0, 1, 2, 3, 9] }
        #expect(Self.glosses(five) == ["noun gloss 1", "engage for a performance", "noun gloss 2", Self.reserveGloss])

        let (duplicates, _) = try await card { [3, 3, -1, 0] }
        #expect(Self.glosses(duplicates) == [Self.reserveGloss, "noun gloss 1"])
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

    @Test("`selection` is pure: invalid indices alone give nil, the order is kept, at most four")
    func selectionPostProcessingIsPure() {
        let senses = [PartOfSpeech.noun, .verb, .adjective, .adverb, .noun, .verb, .adjective, .adverb].enumerated()
            .map {
                WordNetSense(partOfSpeech: $1, gloss: "g\($0)", synonyms: [], antonyms: [], example: nil)
            }
        #expect(WordNetLookup.selection([10, -3], from: senses) == nil)
        #expect(WordNetLookup.selection([], from: senses) == nil)
        #expect(WordNetLookup.selection([5, 4, 7, 6, 0], from: senses)?.map(\.gloss) == ["g5", "g4", "g7", "g6"])
        #expect(WordNetLookup.selection([4], from: senses)?.map(\.gloss) == ["g4"])
    }

    // MARK: - No call

    @Test("one-sense lemmas and stoplist words make no selection call; two or more senses do")
    func selectionIsSkippedOnlyForSingleSenses() async throws {
        for headword in ["look up", "however"] {
            let calls = ScriptedModelCalls(script: .init(proposeSenses: { _ in [GeneratorFixtures.howeverSense] }))
            let card = try await makeGenerator(calls).generateCard(makeRequest(headword))
            #expect(calls.calls(.selectSenses).isEmpty, "\(headword)")
            #expect(!card.notes.contains(.senseSelectionFellBack))
            #expect(!card.senses.isEmpty)
        }
        for headword in ["book", "light", "gaslight"] {
            let calls = ScriptedModelCalls()
            let entry = try #require(await WordNetLookup.shared.entry(for: headword))
            _ = try await makeGenerator(calls).generateCard(makeRequest(headword))
            #expect(calls.calls(.selectSenses).count == (entry.senses.count > 1 ? 1 : 0), "\(headword)")
        }
    }
}
