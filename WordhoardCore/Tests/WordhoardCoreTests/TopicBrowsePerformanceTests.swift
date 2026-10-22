import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The #61 thresholds (plan 3.4): `load()` ≤ 100 ms at 1 000 words, one topic's groups ≤ 100 ms at 200
/// words, on the 3.3 fixture shape (3 senses × 6 examples per word, five of six tagged).
@MainActor
@Suite("TopicBrowseModel performance")
struct TopicBrowsePerformanceTests {
    let store: WordStore

    init() throws {
        store = try WordStore(container: WordhoardContainer.makeInMemory())
    }

    private func insertWords(_ count: Int) throws {
        let topics = GrammarCatalog.english.topics.map(\.key)
        try store.transaction { context in
            for index in 0 ..< count {
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
    }

    @Test("loading the topics over a thousand words takes at most 100 ms")
    func loadAtAThousandWordsIsFast() throws {
        try insertWords(1000)
        let model = TopicBrowseModel(store: store)
        model.load()
        let elapsed: Duration = ContinuousClock().measure {
            model.load()
        }
        let total = (model.active + model.other).map(\.exampleCount).reduce(0, +)
        #expect(total == 15000)
        let limit = Duration.milliseconds(100)
        #expect(elapsed <= limit, "load() took \(elapsed)")
    }

    @Test("one topic's groups over two hundred words take at most 100 ms")
    func groupsAtTwoHundredWordsAreFast() throws {
        try insertWords(200)
        let model = TopicBrowseModel(store: store)
        model.load()
        var groups: [TopicWordGroup] = []
        let elapsed: Duration = ContinuousClock().measure {
            groups = model.groups(for: "en.present_perfect")
        }
        #expect(!groups.isEmpty)
        print("TopicBrowseModel.groups(for:) over 200 words: \(elapsed)")
        let limit = Duration.milliseconds(100)
        #expect(elapsed <= limit, "groups(for:) took \(elapsed)")
    }

    @Test("one topic's groups over a thousand words are measured")
    func groupsAtAThousandWordsAreMeasured() throws {
        try insertWords(1000)
        let model = TopicBrowseModel(store: store)
        var count = 0
        let elapsed: Duration = ContinuousClock().measure {
            count = model.groups(for: "en.present_perfect").count
        }
        #expect(count > 0)
        print("TopicBrowseModel.groups(for:) over 1000 words: \(elapsed), \(count) words")
    }
}
