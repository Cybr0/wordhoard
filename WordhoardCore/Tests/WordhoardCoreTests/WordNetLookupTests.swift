import Foundation
import Testing
import WordhoardCore

/// The bundled Open English WordNet resources and `WordNetLookup` (issue #38, part a). The real
/// bundle is used as is; it loads once per process.
@Suite("WordNet lookup")
struct WordNetLookupTests {
    private static let reserveGloss = "arrange for and reserve (something for someone else) in advance"
    private static let engageGloss = "engage for a performance"

    private func sense(_ partOfSpeech: PartOfSpeech, _ gloss: String) -> WordNetSense {
        WordNetSense(partOfSpeech: partOfSpeech, gloss: gloss, synonyms: [], antonyms: [], example: nil)
    }

    /// A throwaway directory usable as a `Bundle`, with a `WordNet/` subdirectory holding `files`.
    private func temporaryBundle(files: [String: String]) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordNetLookupTests-\(UUID().uuidString)", isDirectory: true)
        let wordNet = directory.appendingPathComponent("WordNet", isDirectory: true)
        try FileManager.default.createDirectory(at: wordNet, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: wordNet.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return try #require(Bundle(url: directory))
    }

    @Test("the bundle, the stoplist and the CC BY 4.0 license ship with the package")
    func wordNetResourcesAreBundledWithTheirLicense() throws {
        let bundle = CoreInfo.resourceBundle
        let json = try #require(bundle.url(forResource: "WordNet/oewn-2024", withExtension: "json"))
        #expect(bundle.url(forResource: "WordNet/function-words", withExtension: "txt") != nil)
        let license = try #require(bundle.url(forResource: "WordNet/OEWN-LICENSE", withExtension: "txt"))
        #expect(try Data(contentsOf: json).count == 15_492_477)
        #expect(try String(contentsOf: license, encoding: .utf8).contains("Creative Commons"))
    }

    @Test("`book` selects two nouns and two verbs, the second verb being *reserve*")
    func bookSelectsTwoNounsAndTwoVerbsIncludingReserve() async throws {
        let entry = try #require(await WordNetLookup.shared.entry(for: "Book "))

        let nouns = entry.senses.filter { $0.partOfSpeech == .noun }
        let verbs = entry.senses.filter { $0.partOfSpeech == .verb }
        #expect(nouns.count >= 2)
        #expect(verbs.count >= 2)
        #expect(
            entry.senses.map(\.partOfSpeech) == Array(repeating: .noun, count: nouns.count)
                + Array(repeating: .verb, count: verbs.count),
            "nouns before verbs"
        )

        #expect(entry.selected.map(\.partOfSpeech) == [.noun, .noun, .verb, .verb])
        #expect(entry.selected[2].gloss == Self.engageGloss)
        #expect(entry.selected[3].gloss == Self.reserveGloss)
        #expect(entry.selected[3].synonyms.contains("reserve"))
        #expect(nouns.allSatisfy { !$0.synonyms.contains("book") })
        #expect(entry.selected.contains { $0.example != nil }, "the bundle keeps one example per synset")
    }

    @Test("`light` selects one sense of each part of speech before any second sense")
    func lightSelectsOneSenseOfEachPartOfSpeech() async throws {
        let entry = try #require(await WordNetLookup.shared.entry(for: "light"))
        #expect(entry.senses.count > 4)
        #expect(entry.selected.map(\.partOfSpeech) == [.noun, .verb, .adjective, .adverb])
    }

    @Test("misses answer nil, multi-word lemmas resolve, and the stoplist is case- and space-insensitive")
    func lookupMissesStoplistAndMultiWordLemmas() async throws {
        let lookup = WordNetLookup.shared
        #expect(await lookup.entry(for: "asdfgh") == nil)
        #expect(await lookup.entry(for: "by the book") == nil)
        #expect(await lookup.entry(for: "") == nil)
        #expect(await lookup.entry(for: "look up")?.senses.count == 1)
        #expect(await lookup.entry(for: "look_up")?.senses.count == 1, "underscores read as spaces")
        let gaslight = try #require(await lookup.entry(for: "gaslight"))
        #expect(gaslight.senses.allSatisfy { $0.partOfSpeech == .noun })

        #expect(await lookup.isFunctionWord("however"))
        #expect(await lookup.isFunctionWord("Despite"))
        #expect(await lookup.isFunctionWord(" the "))
        #expect(await !lookup.isFunctionWord("book"))
        #expect(await !lookup.isFunctionWord(""))
    }

    @Test("the stoplist's section headers give the word class; a lemma before the first header has none")
    func stoplistSectionsGiveTheWordClass() async throws {
        let lookup = WordNetLookup.shared
        #expect(await lookup.functionWordClass("despite") == .preposition)
        #expect(await lookup.functionWordClass("in spite of") == .preposition)
        #expect(await lookup.functionWordClass("however") == .adverb)
        #expect(await lookup.functionWordClass("the") == .determiner)
        #expect(await lookup.functionWordClass("They") == .pronoun)
        #expect(await lookup.functionWordClass("and") == .conjunction)
        #expect(await lookup.functionWordClass("could") == .auxiliary)
        #expect(await lookup.functionWordClass("book") == nil)
        #expect(await lookup.functionWordClass("") == nil)

        // The shipped file lists nothing before its first header; a hand-made one may.
        let early = try WordNetLookup(bundle: temporaryBundle(files: [
            "function-words.txt": """
            # prose comment mentioning Prepositions in passing
            lo

            # Conjunctions
            and
            #   pronouns
            me
            """,
        ]))
        #expect(await early.isFunctionWord("lo"))
        #expect(await early.functionWordClass("lo") == nil, "listed before the first section header")
        #expect(await early.functionWordClass("and") == .conjunction)
        #expect(
            await early.functionWordClass("me") == .pronoun,
            "headers match case-insensitively, leading spaces ignored"
        )
        #expect(await early.functionWordClass("prepositions") == nil, "a header is not a lemma")
        #expect(await !early.isFunctionWord("conjunctions"))
    }

    @Test("`select` keeps two per part of speech and four in all, rank 1 of every part first")
    func selectKeepsTwoPerPartOfSpeechAndFourInAll() {
        let noun1 = sense(.noun, "n1"), noun2 = sense(.noun, "n2"), noun3 = sense(.noun, "n3")
        let verb1 = sense(.verb, "v1"), verb2 = sense(.verb, "v2"), verb3 = sense(.verb, "v3")
        let adjective1 = sense(.adjective, "a1"), adverb1 = sense(.adverb, "r1")

        #expect(WordNetLookup.select([noun1, noun2, noun3, verb1, verb2, verb3]) == [noun1, noun2, verb1, verb2])
        #expect(WordNetLookup.select([noun1, noun2, noun3, verb1, adjective1, adverb1])
            == [noun1, verb1, adjective1, adverb1])
        #expect(WordNetLookup.select([noun1, noun2, noun3, sense(.noun, "n4"), sense(.noun, "n5")]) == [noun1, noun2])
        #expect(WordNetLookup.select([verb1, noun1]) == [noun1, verb1], "regrouped nouns first")
        #expect(WordNetLookup.select([]) == [])
        #expect(WordNetLookup.maxSensesPerPartOfSpeech == 2)
        #expect(WordNetLookup.maxSensesTotal == 4)
    }

    @Test("a missing bundle answers nil and false without crashing")
    func aMissingBundleAnswersNilNotACrash() async throws {
        let lookup = try WordNetLookup(bundle: temporaryBundle(files: [:]))
        await lookup.warmUp()
        #expect(await lookup.entry(for: "book") == nil)
        #expect(await !lookup.isFunctionWord("the"))
    }

    @Test("an undecodable bundle answers nil while the stoplist next to it still works")
    func anUndecodableBundleAnswersNilAndTheStoplistStillWorks() async throws {
        let lookup = try WordNetLookup(bundle: temporaryBundle(files: [
            "oewn-2024.json": "{\"edition\": 1, \"synsets\": \"no\"}",
            "function-words.txt": "# comment\nthe # trailing comment\n\nYet\n",
        ]))
        #expect(await lookup.entry(for: "book") == nil)
        #expect(await lookup.entry(for: "the") == nil)
        #expect(await lookup.isFunctionWord("the"))
        #expect(await lookup.isFunctionWord("yet"))
        #expect(await !lookup.isFunctionWord("comment"))
    }

    @Test("a tiny bundle decodes every sense-reference and synset form")
    func aTinyBundleDecodesEveryForm() async throws {
        let json = """
        {"edition":"test",
         "synsets":[["only gloss"],["with members",["alpha","beta"]],["with example",[],["Beta runs."]]],
         "lemmas":{"beta":{"n":[0,[1,["gamma"]]],"v":[2]}}}
        """
        let lookup = try WordNetLookup(bundle: temporaryBundle(files: ["oewn-2024.json": json]))
        let entry = try #require(await lookup.entry(for: "BETA"))
        #expect(entry.senses == [
            WordNetSense(partOfSpeech: .noun, gloss: "only gloss", synonyms: [], antonyms: [], example: nil),
            WordNetSense(
                partOfSpeech: .noun,
                gloss: "with members",
                synonyms: ["alpha"],
                antonyms: ["gamma"],
                example: nil
            ),
            WordNetSense(partOfSpeech: .verb, gloss: "with example", synonyms: [], antonyms: [], example: "Beta runs."),
        ])
        #expect(entry.selected == entry.senses)
        #expect(await lookup.entry(for: "alpha") == nil, "members are not lemmas")
    }
}
