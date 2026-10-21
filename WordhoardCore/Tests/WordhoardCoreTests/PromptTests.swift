import Foundation
import Testing
import WordhoardCore

/// The prompt builders in `Services/Prompts/` (issue #38, part b): the text the model sees carries
/// the sense it is for, the topic it is asked about, and nothing about translation.
@Suite("Prompts")
struct PromptTests {
    private static let presentPerfect = GrammarCatalog.english.topic(for: "en.present_perfect")!

    @Test("the example prompt names the topic and its description, or asks for everyday language")
    func examplePromptNamesTheTopic() {
        let topical = ExamplePrompt.prompt(
            headword: "book", partOfSpeech: .verb, definition: "to reserve", topic: Self.presentPerfect
        )
        #expect(topical.contains("\"book\""))
        #expect(topical.contains("as a verb"))
        #expect(topical.contains("\"to reserve\""))
        #expect(topical.contains(Self.presentPerfect.name))
        #expect(topical.contains(Self.presentPerfect.description))
        #expect(topical.contains("return an empty string"))

        let neutral = ExamplePrompt.prompt(headword: "book", partOfSpeech: .noun, definition: "a text", topic: nil)
        #expect(neutral.hasSuffix(". Use everyday language with no special grammar."))
        #expect(!neutral.contains("empty string"))
        #expect(ExamplePrompt.instructions.contains("never write the word \"empty\""))
    }

    @Test("the definition prompt carries gloss, synonyms and the WordNet example, each only when present")
    func definitionPromptCarriesTheSense() {
        let full = DefinitionPrompt.prompt(headword: "book", sense: WordNetSense(
            partOfSpeech: .verb, gloss: "engage for a performance", synonyms: ["hire"], antonyms: [],
            example: "Her agent had booked her for several concerts in Tokyo"
        ))
        #expect(full.split(separator: "\n").count == 6)
        #expect(full.contains("Part of speech: verb"))
        #expect(full.contains("Dictionary gloss: engage for a performance"))
        #expect(full.contains("Synonyms: hire"))
        #expect(full.contains("(for understanding only, do not reuse it): Her agent"))
        #expect(full.hasSuffix("Write the learner definition of \"book\" as a verb in this sense."))

        let bare = DefinitionPrompt.prompt(headword: "gaslight", sense: WordNetSense(
            partOfSpeech: .noun, gloss: "a lamp", synonyms: [], antonyms: [], example: nil
        ))
        #expect(bare.split(separator: "\n").count == 4)
        #expect(!bare.contains("Synonyms:"))
        #expect(!bare.contains("Example"))
    }

    @Test("the verifier prompt phrases the part of speech like a dictionary would")
    func verifierPromptPhrasesThePartOfSpeech() {
        func prompt(_ partOfSpeech: PartOfSpeech) -> String {
            VerifierPrompt.prompt(headword: "despite", partOfSpeech: partOfSpeech, definition: "in spite of")
        }
        #expect(prompt(.noun).contains("used as a noun meaning \"in spite of\"? Answer yes or no."))
        #expect(prompt(.adverb).contains("used as an adverb meaning"))
        #expect(prompt(.phrase).contains("as an idiom or fixed phrase"))
        #expect(prompt(.preposition).contains("as a preposition, conjunction, determiner or pronoun"))
        #expect(prompt(.other) == prompt(.conjunction))
        #expect(SensesPrompt
            .prompt(headword: "however") == "Write the dictionary entry for the English word: \"however\"")
    }

    @Test("no prompt mentions a native language, a translation or an image")
    func promptsCarryNoTranslation() {
        let texts = [
            SensesPrompt.instructions, VerifierPrompt.instructions, DefinitionPrompt.instructions,
            ExamplePrompt.instructions,
        ]
        for text in texts {
            let lowered = text.lowercased()
            #expect(!lowered.contains("russian"))
            #expect(!lowered.contains("translat"))
            #expect(!lowered.contains("native language"))
            #expect(!lowered.contains("image"))
        }
        #expect(SensesPrompt.instructions.contains("1. other — \"throughout the whole time that something lasts\""))
        #expect(GenerationDefaults.temperature == 0.3)
    }
}
