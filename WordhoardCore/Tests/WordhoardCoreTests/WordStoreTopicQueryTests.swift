import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `WordStore.exampleCounts(for:)` and `examples(forTopic:)` (plan 3.4, #61): any source, active words
/// only, orphans never.
@MainActor
@Suite("WordStore topic queries")
struct WordStoreTopicQueryTests {
    let container: ModelContainer
    let store: WordStore

    static let presentPerfect: GrammarTopicID = "en.present_perfect"
    static let passiveVoice: GrammarTopicID = "en.passive_voice"
    static let articles: GrammarTopicID = "en.articles"

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    /// `book`: neutral, present perfect `.auto`, present perfect `.user`, `en.bogus`, passive `.user`.
    /// `pear` (soft-deleted): present perfect. Orphans: an example with no sense, and an example on a
    /// sense with no word, both present perfect.
    private func makeFixture() throws {
        let book = try store.add("book").word
        let pear = try store.add("pear").word
        try store.transaction { context in
            let sense = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
            sense.examples = [
                Example(text: "neutral", source: .auto, order: 0),
                Example(text: "auto pp", source: .auto, grammarTopic: Self.presentPerfect, order: 1),
                Example(text: "user pp", source: .user, grammarTopic: Self.presentPerfect, order: 2),
                Example(text: "bogus", source: .auto, grammarTopic: "en.bogus", order: 3),
                Example(text: "user passive", source: .user, grammarTopic: Self.passiveVoice, order: 4),
            ]
            book.senses = [sense]
            let pearSense = Sense(partOfSpeech: .noun, definition: "a fruit", order: 0)
            pearSense.examples = [Example(text: "deleted pp", source: .auto, grammarTopic: Self.presentPerfect)]
            pear.senses = [pearSense]
            context.insert(Example(text: "orphan pp", source: .auto, grammarTopic: Self.presentPerfect))
            let wordless = Sense(partOfSpeech: .noun, definition: "no word", order: 0)
            context.insert(wordless)
            wordless.examples = [Example(text: "wordless pp", source: .auto, grammarTopic: Self.presentPerfect)]
        }
        try store.delete(pear)
    }

    @Test("counts cover every source on active words and skip deleted words and orphans")
    func countsCoverActiveWordsOnly() throws {
        try makeFixture()
        let counts = try store.exampleCounts(for: [Self.presentPerfect, Self.passiveVoice, Self.articles, "en.bogus"])
        #expect(counts == [Self.presentPerfect: 2, Self.passiveVoice: 1, Self.articles: 0, "en.bogus": 1])
    }

    @Test("a key that was not requested is absent from the counts")
    func unrequestedKeysAreAbsent() throws {
        try makeFixture()
        let counts = try store.exampleCounts(for: [Self.articles])
        #expect(counts == [Self.articles: 0])
        #expect(try store.exampleCounts(for: []).isEmpty)
    }

    @Test("a topic's examples include user examples and never neutral, deleted or orphan ones")
    func topicExamplesAreTheCountedOnes() throws {
        try makeFixture()
        let texts = try store.examples(forTopic: Self.presentPerfect).map(\.text).sorted()
        #expect(texts == ["auto pp", "user pp"])
        #expect(try store.examples(forTopic: Self.articles).isEmpty)
    }
}
