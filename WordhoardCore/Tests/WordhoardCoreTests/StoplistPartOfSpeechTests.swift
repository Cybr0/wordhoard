import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Plan 2.7 (issue #19): prepositions and conjunctions in the model's vocabulary, the stoplist's
/// section class as a prompt hint, and the stored sense surviving export and import.
private enum StoplistFixtures {
    static let despiteSense = ProposedSense(
        partOfSpeech: .preposition, definition: "in spite of", synonyms: ["notwithstanding"]
    )
    static let althoughSense = ProposedSense(
        partOfSpeech: .conjunction, definition: "in spite of the fact that", synonyms: ["though"]
    )
}

@MainActor
@Suite("Stoplist parts of speech")
struct StoplistPartOfSpeechTests {
    @Test("the model's part-of-speech enum has eight cases and maps onto every core part of speech")
    func modelPartOfSpeechMapsOntoEveryCorePartOfSpeech() {
        #expect(ModelPartOfSpeech.allCases.count == 8)
        #expect(ModelPartOfSpeech.noun.partOfSpeech == .noun)
        #expect(ModelPartOfSpeech.verb.partOfSpeech == .verb)
        #expect(ModelPartOfSpeech.adjective.partOfSpeech == .adjective)
        #expect(ModelPartOfSpeech.adverb.partOfSpeech == .adverb)
        #expect(ModelPartOfSpeech.preposition.partOfSpeech == .preposition)
        #expect(ModelPartOfSpeech.conjunction.partOfSpeech == .conjunction)
        #expect(ModelPartOfSpeech.phrase.partOfSpeech == .phrase)
        #expect(ModelPartOfSpeech.other.partOfSpeech == .other)
        #expect(Set(ModelPartOfSpeech.allCases.map(\.partOfSpeech)) == Set(PartOfSpeech.allCases), "total and onto")
        #expect(ModelPartOfSpeech(rawValue: "determiner") == nil)
        #expect(ModelPartOfSpeech(rawValue: "pronoun") == nil)
    }

    @Test("a stoplist word's section reaches the senses and verifier prompts as a hint; other words carry none")
    func stoplistWordsCarryTheirClassIntoThePrompts() async throws {
        let calls = ScriptedModelCalls(script: .init(proposeSenses: { headword in
            headword == "despite" ? [StoplistFixtures.despiteSense] : GeneratorFixtures.nonsenseSenses
        }))
        let generator = makeGenerator(calls)

        let despite = try await generator.generateCard(makeRequest("despite"))
        #expect(despite.path == .stoplist)
        #expect(calls.calls.prefix(2) == [
            .proposeSenses(headword: "despite", wordClass: .preposition),
            .verify(headword: "despite", sense: StoplistFixtures.despiteSense, wordClass: .preposition),
        ])
        let sensesPrompt = SensesPrompt.prompt(headword: "despite", wordClass: .preposition)
        #expect(sensesPrompt.contains("This word is usually a preposition."))
        #expect(sensesPrompt.hasPrefix("Write the dictionary entry for the English word: \"despite\"\n"))
        let verifierPrompt = VerifierPrompt.prompt(
            headword: "despite", partOfSpeech: .preposition, definition: "in spite of", wordClass: .preposition
        )
        #expect(verifierPrompt.contains("commonly used as a preposition meaning \"in spite of\"?"))
        #expect(verifierPrompt.hasSuffix("Answer yes or no. This word is usually a preposition."))

        let idiom = try await generator.generateCard(makeRequest("by the book"))
        #expect(idiom.path == .modelOnly)
        #expect(calls.calls(.proposeSenses).last == .proposeSenses(headword: "by the book", wordClass: nil))
        #expect(!SensesPrompt.prompt(headword: "by the book", wordClass: nil).contains("usually"))
        for call in calls.calls(.verify).dropFirst() {
            guard case let .verify(headword, sense, wordClass) = call else { continue }
            #expect(wordClass == nil)
            let prompt = VerifierPrompt.prompt(
                headword: headword, partOfSpeech: sense.partOfSpeech, definition: sense.definition, wordClass: wordClass
            )
            #expect(!prompt.contains("usually"))
        }

        #expect(WordClassHint.line(for: .auxiliary) == "This word is usually an auxiliary or modal verb.")
        #expect(WordClassHint.line(for: .adverb) == "This word is usually an adverb.")
        #expect(WordClassHint.line(for: nil) == nil)
    }

    @Test("a proposed preposition or conjunction sense is stored as such and survives export and import")
    func prepositionAndConjunctionSensesRoundTrip() async throws {
        let calls = ScriptedModelCalls(script: .init(proposeSenses: { headword in
            headword == "despite" ? [StoplistFixtures.despiteSense] : [StoplistFixtures.althoughSense]
        }))
        let generator = makeGenerator(calls)
        let despite = try await generator.generateCard(makeRequest("despite"))
        let although = try await generator.generateCard(makeRequest("although"))
        #expect(despite.senses.map(\.partOfSpeech) == [.preposition])
        #expect(despite.senses.first?.senseSource == .model)
        #expect(although.senses.map(\.partOfSpeech) == [.conjunction])
        #expect(calls.calls(.verify).count == 2)

        let container = try WordhoardContainer.makeInMemory()
        let store = WordStore(container: container)
        for card in [despite, although] {
            let word = try store.add(card.headword).word
            _ = CardMerger.apply(card, to: word)
            try store.save(word)
        }
        #expect(try store.words().flatMap(\.senses).map(\.partOfSpeech).sorted { $0.rawValue < $1.rawValue }
            == [.conjunction, .preposition])

        let file = try Exporter.export(
            from: store, exportedAt: TransferFixture.exportedAt, appVersion: TransferFixture.appVersion
        )
        let text = try #require(String(data: file, encoding: .utf8))
        #expect(text.contains("\"partOfSpeech\" : \"preposition\""))
        #expect(text.contains("\"partOfSpeech\" : \"conjunction\""))

        let fresh = try WordStore(container: WordhoardContainer.makeInMemory())
        _ = try Importer.import(file, into: fresh)
        let imported = try fresh.words()
        #expect(imported.count == 2)
        let importedDespite = try #require(imported.first { $0.headword == "despite" })
        #expect(importedDespite.sortedSenses.map(\.partOfSpeech) == [.preposition])
        #expect(importedDespite.sortedSenses.first?.definition == "in spite of")
        let importedAlthough = try #require(imported.first { $0.headword == "although" })
        #expect(importedAlthough.sortedSenses.map(\.partOfSpeech) == [.conjunction])
        #expect(try Exporter.export(
            from: fresh, exportedAt: TransferFixture.exportedAt, appVersion: TransferFixture.appVersion
        ) == file)
    }
}
