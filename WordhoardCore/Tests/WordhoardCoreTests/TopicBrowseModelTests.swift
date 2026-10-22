import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `TopicBrowseModel` (plan 3.3, #57): counts over active words whatever the source, unknown keys
/// nowhere, inactive topics listed only while they have examples, groups newest first.
///
/// The browse fixture: settings at the five defaults; `apple` (newest) with one sense [neutral, present
/// perfect `.auto`]; `book` with sense 0 [neutral, present perfect `.auto`, passive `.user`] and sense 1
/// [present perfect `.auto`, `en.bogus` `.auto`, articles `.auto`]; `pear` soft-deleted with [present
/// perfect].
@MainActor
@Suite("TopicBrowseModel")
struct TopicBrowseModelTests {
    let container: ModelContainer
    let store: WordStore

    static let presentPerfect: GrammarTopicID = "en.present_perfect"
    static let passiveVoice: GrammarTopicID = "en.passive_voice"
    static let articles: GrammarTopicID = "en.articles"

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private struct Fixture {
        let apple: Word
        let book: Word
        let pear: Word
    }

    /// One example of the fixture.
    private struct Spec {
        let text: String
        let key: GrammarTopicID?
        let source: FieldSource

        init(_ text: String, _ key: GrammarTopicID?, _ source: FieldSource) {
            self.text = text
            self.key = key
            self.source = source
        }
    }

    /// One array of examples per sense.
    private func addWord(_ headword: String, createdAt: Date, senses: [[Spec]]) throws -> Word {
        let word = try store.add(headword).word
        try store.transaction { _ in
            word.createdAt = createdAt
            word.autofillState = .ready
            word.senses = senses.enumerated().map { index, examples in
                let sense = Sense(partOfSpeech: .noun, definition: "\(headword) \(index)", order: index)
                sense.examples = examples.enumerated().map { order, example in
                    Example(text: example.text, source: example.source, grammarTopic: example.key, order: order)
                }
                return sense
            }
        }
        return word
    }

    private func makeFixture() throws -> Fixture {
        _ = try store.settings()
        let pear = try addWord(
            "pear", createdAt: Date(timeIntervalSince1970: 1000),
            senses: [[Spec("Pears have ripened.", Self.presentPerfect, .auto)]]
        )
        try store.delete(pear)
        let book = try addWord("book", createdAt: Date(timeIntervalSince1970: 2000), senses: [
            [
                Spec("She left her book on the train.", nil, .auto),
                Spec("I have read this book twice.", Self.presentPerfect, .auto),
                Spec("The book was written by me.", Self.passiveVoice, .user),
            ],
            [
                Spec("We have booked a table.", Self.presentPerfect, .auto),
                Spec("A book from the future.", "en.bogus", .auto),
                Spec("The book is on the shelf.", Self.articles, .auto),
            ],
        ])
        let apple = try addWord("apple", createdAt: Date(timeIntervalSince1970: 3000), senses: [
            [Spec("An apple a day.", nil, .auto), Spec("I have eaten an apple.", Self.presentPerfect, .auto)],
        ])
        return Fixture(apple: apple, book: book, pear: pear)
    }

    private func counts(_ rows: [TopicRow]) -> [String] {
        rows.map { "\($0.topic.key)=\($0.exampleCount)" }
    }

    @Test("counts cover active words and every known key whatever the source")
    func countsCoverActiveWordsAndEveryKnownKeyWhateverTheSource() throws {
        _ = try makeFixture()
        let model = TopicBrowseModel(store: store)

        model.load()

        #expect(counts(model.active) == [
            "en.present_perfect=3", "en.past_simple=0", "en.first_conditional=0", "en.second_conditional=0",
            "en.passive_voice=1",
        ])
        #expect(counts(model.other) == ["en.articles=1"])
        #expect(!(model.active + model.other).contains { $0.id == "en.bogus" })
        #expect(model.failure == nil)
    }

    @Test("inactive topics are listed only while they have examples")
    func inactiveTopicsAreListedOnlyWhileTheyHaveExamples() throws {
        let fixture = try makeFixture()
        let settings = SettingsModel(store: store)
        settings.load()
        settings.setTopicActive(Self.presentPerfect, false)
        settings.setTopicActive(Self.passiveVoice, false)
        let model = TopicBrowseModel(store: store)

        model.load()
        #expect(counts(model.active) == ["en.past_simple=0", "en.first_conditional=0", "en.second_conditional=0"])
        #expect(counts(model.other) == ["en.present_perfect=3", "en.passive_voice=1", "en.articles=1"])

        let passive = try #require(fixture.book.sortedSenses[0].sortedExamples.first { $0.source == .user })
        WordCardModel(word: fixture.book, store: store).removeExample(passive)
        model.load()
        #expect(counts(model.other) == ["en.present_perfect=3", "en.articles=1"])
        #expect(!model.active.contains { $0.id == Self.passiveVoice })
    }

    @Test("groups are newest first with only that topic's examples")
    func groupsAreNewestFirstWithOnlyThatTopicsExamples() throws {
        let fixture = try makeFixture()
        let model = TopicBrowseModel(store: store)
        model.load()

        let perfect = model.groups(for: Self.presentPerfect)
        #expect(perfect.map(\.word.headword) == ["apple", "book"])
        #expect(perfect.map { $0.examples.map(\.text) } == [
            ["I have eaten an apple."],
            ["I have read this book twice.", "We have booked a table."],
        ])
        #expect(!perfect.contains { $0.word.id == fixture.pear.id })

        let passive = model.groups(for: Self.passiveVoice)
        #expect(passive.map(\.word.headword) == ["book"])
        #expect(passive.first?.examples.map(\.source) == [.user])
        #expect(model.groups(for: "en.past_simple").isEmpty)
        #expect(model.groups(for: "en.bogus").isEmpty)
    }

    @Test("groups never contain neutral examples")
    func groupsNeverContainNeutralExamples() throws {
        _ = try makeFixture()
        let model = TopicBrowseModel(store: store)
        model.load()

        for topic in GrammarCatalog.english.topics {
            let examples = model.groups(for: topic.key).flatMap(\.examples)
            #expect(examples.allSatisfy { $0.grammarTopic == topic.key })
        }
    }

    @Test("load reflects later changes")
    func loadReflectsLaterChanges() throws {
        let fixture = try makeFixture()
        let model = TopicBrowseModel(store: store)
        model.load()
        #expect(model.active.first?.exampleCount == 3)

        let neutral = try #require(fixture.apple.sortedSenses[0].sortedExamples.first { $0.grammarTopic == nil })
        try store.transaction { _ in neutral.grammarTopic = Self.presentPerfect }
        model.load()
        #expect(model.active.first?.exampleCount == 4)
        #expect(model.groups(for: Self.presentPerfect).first?.examples.count == 2)

        try store.delete(fixture.apple)
        model.load()
        #expect(model.active.first?.exampleCount == 2)
        #expect(model.groups(for: Self.presentPerfect).map(\.word.headword) == ["book"])
    }

    @Test("an empty store gives zero counts or nothing")
    func emptyStoreGivesZeroCountsOrNothing() throws {
        let model = TopicBrowseModel(store: store)
        model.load()
        #expect(counts(model.active) == GrammarCatalog.english.defaultActiveKeys.map { "\($0)=0" })
        #expect(model.other.isEmpty)

        try store.updateSettings { $0.activeGrammarTopics = [] }
        model.load()
        #expect(model.active.isEmpty)
        #expect(model.other.isEmpty)
    }

    @Test("a load failure keeps the previous rows")
    func aLoadFailureKeepsThePreviousRows() throws {
        _ = try makeFixture()
        struct ReadError: Error {}
        let reads = FailSwitch()
        let model = TopicBrowseModel(
            catalog: .english,
            activeTopics: { try store.settings().activeGrammarTopics },
            words: {
                if reads.isFailing {
                    throw ReadError()
                }
                return try store.words()
            }
        )
        model.load()
        let active = model.active
        let other = model.other
        let groups = model.groups(for: Self.presentPerfect).map(\.word.id)

        reads.isFailing = true
        try store.updateSettings { $0.activeGrammarTopics = [] }
        model.load()

        #expect(model.failure == .loading)
        #expect(model.active == active)
        #expect(model.other == other)
        #expect(model.groups(for: Self.presentPerfect).map(\.word.id) == groups)
    }

    /// The #57 threshold: above 100 ms for 1 000 words × 3 senses × 6 examples, a store-side count
    /// becomes a follow-up. Measured and reported, not asserted, so a slow CI runner cannot fail it.
    @Test("load over a thousand words is measured")
    func loadOverAThousandWordsIsMeasured() throws {
        let topics = GrammarCatalog.english.topics.map(\.key)
        try store.transaction { context in
            for index in 0 ..< 1000 {
                let word = Word(headword: "word\(index)")
                context.insert(word)
                word.senses = (0 ..< 3).map { senseIndex in
                    let sense = Sense(partOfSpeech: .noun, definition: "sense \(senseIndex)", order: senseIndex)
                    sense.examples = (0 ..< 6).map { order in
                        let key = order == 0 ? nil : topics[(index + order) % topics.count]
                        return Example(text: "example \(order)", source: .auto, grammarTopic: key, order: order)
                    }
                    return sense
                }
            }
        }
        let model = TopicBrowseModel(store: store)

        let clock = ContinuousClock()
        let first = clock.measure {
            model.load()
        }
        let second = clock.measure {
            model.load()
        }

        let total = (model.active + model.other).map(\.exampleCount).reduce(0, +)
        #expect(total == 1000 * 3 * 5)
        print("TopicBrowseModel.load() over 1000 words x 3 senses x 6 examples: first \(first), second \(second)")
    }
}

/// Lets a test make the browse model's reads fail after a first good load.
@MainActor
private final class FailSwitch {
    var isFailing = false
}
