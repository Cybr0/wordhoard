import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Shared helpers for the `CardMerger` suites.
let presentPerfectKey: GrammarTopicID = "en.present_perfect"

/// `book` filled from the fixture through the merger and saved; the word and its two senses.
@MainActor
struct FilledBook {
    let word: Word
    let noun: Sense
    let verb: Sense

    init(store: WordStore) throws {
        word = try store.add("book").word
        _ = CardMerger.apply(StubFixtures.book, to: word)
        try store.save(word)
        let senses = word.sortedSenses
        noun = try #require(senses.first)
        verb = try #require(senses.last)
    }
}

/// The `book` fixture with its noun sense's fields replaced.
func bookWithNoun(
    definition: String = StubFixtures.book.senses[0].definition,
    translation: String? = StubFixtures.book.senses[0].translation,
    synonyms: [String] = StubFixtures.book.senses[0].synonyms,
    antonyms: [String] = StubFixtures.book.senses[0].antonyms
) -> GeneratedCard {
    var card = StubFixtures.book
    card.senses[0].definition = definition
    card.senses[0].translation = translation
    card.senses[0].synonyms = synonyms
    card.senses[0].antonyms = antonyms
    return card
}

func modelAdverb(_ definition: String) -> GeneratedSense {
    GeneratedSense(
        partOfSpeech: .adverb,
        senseSource: .model,
        gloss: nil,
        definition: definition,
        translation: nil,
        synonyms: [],
        antonyms: [],
        neutralExample: GeneratedExample(text: "\(definition).", grammarTopic: nil)
    )
}

@MainActor
func expectNoAutoMarks(_ word: Word, sourceLocation: SourceLocation = #_sourceLocation) {
    for sense in word.senses {
        #expect(
            sense.fieldSources.values.allSatisfy { $0 == .user },
            "the merger never writes a provenance mark",
            sourceLocation: sourceLocation
        )
    }
}

/// The word with `id`, read through a fresh context.
@MainActor
func storedWord(_ id: UUID, in container: ModelContainer) throws -> Word {
    try #require(try ModelContext(container).fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.id == id })).first)
}

/// A value copy of everything the merger may touch, for before/after comparisons.
struct MergeSnapshot: Equatable {
    struct ExampleRow: Equatable {
        var id: UUID
        var text: String
        var topic: GrammarTopicID?
        var source: FieldSource
        var order: Int
    }

    struct SenseRow: Equatable {
        var id: UUID
        var partOfSpeech: PartOfSpeech
        var senseSource: SenseSource?
        var gloss: String?
        var definition: String
        var translation: String?
        var synonyms: [String]
        var antonyms: [String]
        var fieldSources: [String: FieldSource]
        var order: Int
        var examples: [ExampleRow]
    }

    var senses: [SenseRow]

    @MainActor
    init(_ word: Word) {
        senses = word.sortedSenses.map { sense in
            SenseRow(
                id: sense.id,
                partOfSpeech: sense.partOfSpeech,
                senseSource: sense.senseSource,
                gloss: sense.gloss,
                definition: sense.definition,
                translation: sense.translation,
                synonyms: sense.synonyms,
                antonyms: sense.antonyms,
                fieldSources: sense.fieldSources,
                order: sense.order,
                examples: sense.sortedExamples.map {
                    ExampleRow(id: $0.id, text: $0.text, topic: $0.grammarTopic, source: $0.source, order: $0.order)
                }
            )
        }
    }
}
