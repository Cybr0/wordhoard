import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Plan 2.10 (#22, A9): the model proposes a per-sense equivalent, the Translation framework confirms
/// it by back-translation or the definition's translation stands in, flagged. `ScriptedModelCalls` +
/// `StubTranslator` (which maps `x` → `table[x] ?? "ru:x"` in either direction).
@Suite("Translation proposals")
struct TranslationProposalTests {
    private static let reserveGloss = GeneratorFixtures.reserveGloss

    /// *book*: nouns → книга, *reserve* → бронировать, *engage* → ангажировать.
    private static let bookProposals = ScriptedModelCalls.Script(proposeTranslation: { _, sense, _ in
        if sense.partOfSpeech == .noun {
            return "книга"
        }
        return sense.gloss == reserveGloss ? "бронировать" : "ангажировать"
    })

    // MARK: - Pipeline

    @Test("proposals confirmed by back-translation become the translation, in one batch")
    func acceptedProposalsBecomeTheTranslation() async throws {
        let calls = ScriptedModelCalls(script: Self.bookProposals)
        let translator = StubTranslator(table: ["книга": "book", "бронировать": "reserve", "ангажировать": "to book"])
        let card = try await makeGenerator(calls, translator: translator).generateCard(makeRequest("book"))

        #expect(card.senses.map(\.translation) == ["книга", "книга", "ангажировать", "бронировать"])
        #expect(card.senses.allSatisfy { !$0.translationIsFallback })
        #expect(card.senses[3].synonyms.contains("reserve"), "*reserve* is accepted as a WordNet synonym")
        #expect(card.notes.isEmpty)
        #expect(translator.batches.count == 1, "back-translation only")
        #expect(translator.batches.first?.texts == ["книга", "ангажировать", "бронировать"])
        #expect(translator.batches.first?.source == "ru")
        #expect(translator.batches.first?.target == "en")

        let proposals = calls.calls(.proposeTranslation)
        #expect(proposals.count == 4, "one proposal call per sense")
        for (index, call) in proposals.enumerated() {
            guard case let .proposeTranslation(headword, sense, language) = call else { continue }
            #expect(headword == "book")
            #expect(language == "ru")
            #expect(sense.definition == card.senses[index].definition)
            #expect(sense.neutralExample != nil, "the proposal runs after the neutral example")
        }
        #expect(calls.calls.last?.method == .proposeTranslation, "translation is the last step of the first card")
    }

    @Test("a rejected or refused proposal falls back to the translated definition, flagged, in a second batch")
    func rejectedProposalsFallBackToTheTranslatedDefinition() async throws {
        let calls = ScriptedModelCalls(script: .init(proposeTranslation: { _, _, _ in "посмотреть вверх" }))
        let translator = StubTranslator(table: ["посмотреть вверх": "to look upward"])
        let card = try await makeGenerator(calls, translator: translator).generateCard(makeRequest("look up"))

        let sense = try #require(card.senses.first)
        #expect(card.senses.count == 1)
        #expect(sense.translation == "ru:\(sense.definition)")
        #expect(sense.translationIsFallback)
        #expect(card.notes == [.translationFallback(senseIndex: 0, rejectedProposal: "посмотреть вверх")])
        #expect(translator.batches.count == 2)
        #expect(translator.batches.map(\.texts) == [["посмотреть вверх"], [sense.definition]])
        #expect(translator.batches.last?.source == "en")
        #expect(translator.batches.last?.target == "ru")

        let refusing = ScriptedModelCalls(script: .init(proposeTranslation: { _, sense, _ in
            if sense.gloss == Self.reserveGloss {
                throw ModelCallError.refused
            }
            return "ru:book"
        }))
        let refusedTranslator = StubTranslator()
        let refused = try await makeGenerator(refusing, translator: refusedTranslator).generateCard(makeRequest("book"))
        #expect(refused.senses[3].translation == "ru:\(refused.senses[3].definition)")
        #expect(refused.senses[3].translationIsFallback)
        #expect(refused.senses[0 ..< 3].allSatisfy { $0.translation == "ru:book" && !$0.translationIsFallback })
        #expect(refused.notes == [.translationFallback(senseIndex: 3, rejectedProposal: nil)])
        #expect(refusedTranslator.batches.count == 2, "two batches per word, not per sense")
        #expect(refusedTranslator.batches.last?.texts == [refused.senses[3].definition])
    }

    @Test("several rejected senses share the one definition batch")
    func rejectedSensesShareOneBatch() async throws {
        let calls = ScriptedModelCalls(script: .init(proposeTranslation: { _, _, _ in "нечто" }))
        let translator = StubTranslator(table: ["нечто": "something"])
        let card = try await makeGenerator(calls, translator: translator).generateCard(makeRequest("book"))
        #expect(card.senses.map(\.translationIsFallback) == [true, true, true, true])
        #expect(card.notes.count == 4)
        #expect(translator.batches.count == 2)
        #expect(translator.batches.last?.texts == card.senses.map(\.definition))
    }

    @Test("no native language or no installed pack → no proposal call, no translation, model text never shown")
    func translationIsSkippedWithoutALanguageOrAPack() async throws {
        let calls = ScriptedModelCalls()
        let silent = StubTranslator()
        let none = try await makeGenerator(calls, translator: silent).generateCard(makeRequest("book", native: nil))
        #expect(calls.calls(.proposeTranslation).isEmpty)
        #expect(silent.batches.isEmpty)
        #expect(none.senses.allSatisfy { $0.translation == nil })

        let noPackCalls = ScriptedModelCalls()
        let notDownloaded = StubTranslator(availability: .supported)
        let noPack = try await makeGenerator(noPackCalls, translator: notDownloaded).generateCard(makeRequest("book"))
        #expect(noPackCalls.calls(.proposeTranslation).isEmpty)
        #expect(notDownloaded.batches.isEmpty)
        #expect(noPack.senses.allSatisfy { $0.translation == nil && !$0.translationIsFallback })
        #expect(noPack.notes == [.translationUnavailable(language: "ru")])
    }

    @Test("the back-translation check is by lemma: inflections and synonyms count, a longer word does not")
    func backTranslationMatchingIsByLemma() {
        #expect(HeadwordMatcher.containsLemma(of: "book", in: "book"))
        #expect(HeadwordMatcher.containsLemma(of: "book", in: "to book"))
        #expect(HeadwordMatcher.containsLemma(of: "book", in: "books"))
        #expect(HeadwordMatcher.containsLemma(of: "reserve", in: "reserved"))
        #expect(HeadwordMatcher.containsLemma(of: "run", in: "running"))
        #expect(HeadwordMatcher.containsLemma(of: "run", in: "ran"))
        #expect(HeadwordMatcher.containsLemma(of: "look up", in: "to look up"))
        #expect(!HeadwordMatcher.containsLemma(of: "look up", in: "to look upward"))
        #expect(!HeadwordMatcher.containsLemma(of: "book", in: "bookkeeper"))
        #expect(!HeadwordMatcher.containsLemma(of: "book", in: ""))
    }

    @Test("the proposal prompt names the language and the one sense, and asks for 1 to 3 words")
    func proposalPromptNamesTheLanguageAndTheSense() {
        let sense = GeneratedSense(
            partOfSpeech: .verb, senseSource: .wordnet, gloss: Self.reserveGloss,
            definition: "to arrange to have a seat or room", translation: nil,
            synonyms: ["reserve", "hold"], antonyms: ["cancel"],
            neutralExample: GeneratedExample(text: "We booked a table.", grammarTopic: nil)
        )
        let prompt = TranslationPrompt.prompt(headword: "book", sense: sense, nativeLanguage: "ru")
        #expect(prompt.contains("Definition of this sense: to arrange to have a seat or room"))
        #expect(prompt.contains("Dictionary gloss: \(Self.reserveGloss)"))
        #expect(prompt.contains("Synonyms: reserve, hold"))
        #expect(prompt.contains("Example: We booked a table."))
        #expect(prompt.hasSuffix("Give the Russian equivalent of \"book\" as a verb in this sense, 1 to 3 words."))
        #expect(!prompt.contains("cancel"), "antonyms are not part of the proposal")
        #expect(TranslationPrompt.languageName("de") == "German")
        #expect(TranslationPrompt.languageName("pt-BR") == "Portuguese")
        #expect(TranslationPrompt.instructions.contains("1 to 3 words"))
    }

    // MARK: - Schema and transfer

    @Test("the fallback flag defaults to false, is stored on disk, exported only when true and imported")
    @MainActor
    func translationFallbackFlagIsStoredAndExported() throws {
        #expect(Sense(partOfSpeech: .noun).translationIsFallback == false)

        let directory = FileManager.default.temporaryDirectory.appending(path: "wordhoard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Wordhoard.store")
        do {
            let context = try ModelContext(WordhoardContainer.makeOnDisk(url: url))
            let word = Word(headword: "look up")
            word.senses = [
                Sense(
                    partOfSpeech: .verb,
                    definition: "to search",
                    order: 0,
                    translation: "искать",
                    translationIsFallback: true
                ),
                Sense(partOfSpeech: .noun, definition: "a glance", order: 1, translation: "взгляд"),
            ]
            context.insert(word)
            try context.save()
        }
        let reopened = try WordhoardContainer.makeOnDisk(url: url)
        let stored = try ModelContext(reopened).fetch(FetchDescriptor<Sense>(sortBy: [SortDescriptor(\.order)]))
        #expect(stored.map(\.translationIsFallback) == [true, false])

        let store = WordStore(container: reopened)
        let data = try Exporter.export(from: store, exportedAt: .now, appVersion: "test")
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.components(separatedBy: "\"translationIsFallback\" : true").count == 2, "written once, when true")
        #expect(!text.contains("\"translationIsFallback\" : false"))

        let target = try WordStore(container: WordhoardContainer.makeInMemory())
        _ = try Importer.import(data, into: target)
        let imported = try #require(target.words().first).sortedSenses
        #expect(imported.map(\.translationIsFallback) == [true, false])

        // An unknown key is ignored, so renaming the key leaves a file without it.
        let withoutKey = try ExportDocument.decode(Data(text.replacingOccurrences(
            of: "\"translationIsFallback\"", with: "\"renamedKey\""
        ).utf8))
        #expect(withoutKey.words.first?.senses.map(\.translationIsFallback) == [false, false])
    }

    // MARK: - Merge and edit

    @Test("the fallback flag follows the translation field: merged with it, kept with a user edit, cleared by one")
    @MainActor
    func theFallbackFlagFollowsTheTranslationField() throws {
        let store = try WordStore(container: WordhoardContainer.makeInMemory())
        var card = StubFixtures.book
        card.senses[1].translation = "ru:to reserve a seat"
        card.senses[1].translationIsFallback = true
        let word = try store.add("book").word
        CardMerger.apply(card, to: word)
        let verb = try #require(word.sortedSenses.last)
        #expect(verb.translationIsFallback)
        #expect(word.sortedSenses.first?.translationIsFallback == false)

        var accepted = card
        accepted.senses[1].translation = "бронировать"
        accepted.senses[1].translationIsFallback = false
        CardMerger.apply(accepted, to: word)
        #expect(verb.translation == "бронировать")
        #expect(!verb.translationIsFallback, "an accepted translation replaces an .auto fallback and clears the flag")

        CardMerger.apply(card, to: word)
        #expect(verb.translationIsFallback)
        var noTranslation = card
        noTranslation.senses[1].translation = nil
        noTranslation.senses[1].translationIsFallback = false
        CardMerger.apply(noTranslation, to: word)
        #expect(verb.translation == "ru:to reserve a seat", "no generated translation empties nothing")
        #expect(verb.translationIsFallback)

        try store.save(word)
        let model = WordCardModel(word: word, store: store)
        model.setTranslation("заказать", for: verb)
        #expect(verb.translation == "заказать")
        #expect(!verb.translationIsFallback)
        #expect(verb.fieldSource(for: .translation) == .user)

        CardMerger.apply(card, to: word)
        #expect(verb.translation == "заказать", "a .user translation is never replaced")
        #expect(!verb.translationIsFallback, "and its flag is not set by a merge")
    }
}
