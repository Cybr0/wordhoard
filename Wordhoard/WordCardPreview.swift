import SwiftUI
import WordhoardCore

/// A card over an in-memory store with one inserted and saved word, so the preview reads real
/// relationships: two senses, one with a WordNet badge, a translation, synonyms and a topic example.
@MainActor
private func previewCard() -> WordCardView? {
    guard let container = try? WordhoardContainer.makeInMemory() else {
        return nil
    }
    let store = WordStore(container: container)
    guard let word = try? store.add("book").word else {
        return nil
    }
    let noun = Sense(
        partOfSpeech: .noun,
        definition: "A written or printed work consisting of pages bound together.",
        order: 0,
        senseSource: .wordnet,
        translation: "книга",
        synonyms: ["volume", "tome"]
    )
    noun.examples = [
        Example(text: "She read a book on the train.", source: .auto, order: 0),
        Example(text: "I have read this book twice.", source: .auto, grammarTopic: "en.present_perfect", order: 1),
    ]
    let verb = Sense(partOfSpeech: .verb, definition: "To reserve a seat, room or table.", order: 1)
    word.senses = [noun, verb]
    word.autofillState = .ready
    try? store.save(word)
    return WordCardView(
        word: word,
        store: store,
        imageStore: nil,
        imageQueue: nil,
        autofill: AutofillService(store: store, generator: StubCardGenerator()),
        translator: StubTranslator()
    )
}

#Preview {
    NavigationStack {
        previewCard()
    }
}
