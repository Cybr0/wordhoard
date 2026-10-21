import Foundation
import SwiftData
import Testing
import WordhoardCore

/// The "rich hoard" of issue #36 with fixed ids and dates, so it serves both the round-trip tests and the
/// golden fixture: the 1.2 `book` word plus pronunciation, note, a WordNet sense with gloss, translation,
/// synonyms, antonyms and field provenance, a present-perfect example and one with an unknown topic key,
/// a second word with a hand `.other` sense and no examples, one tag on both words, non-default settings
/// and an image (which is not exported).
enum TransferFixture {
    static let exportedAt = Date(timeIntervalSince1970: 1_750_000_000)
    static let appVersion = "0.1.0 (1)"

    static let bookID = uuid(1)
    static let appleID = uuid(2)
    static let nounSenseID = uuid(10)
    static let verbSenseID = uuid(11)
    static let appleSenseID = uuid(12)
    static let readingTagID = uuid(100)

    static let bookCreatedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
    static let bookUpdatedAt = Date(timeIntervalSince1970: 1_700_000_100.5)
    static let appleCreatedAt = Date(timeIntervalSince1970: 1_700_000_200)

    /// `00000000-0000-0000-0000-000000000042` for 42: readable in the golden text.
    static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    /// Inserts the hoard through a throwaway context and saves, like `insertBookFixture`.
    static func insert(into container: ModelContainer) throws {
        let context = ModelContext(container)
        let reading = WordhoardCore.Tag(name: "reading")
        reading.id = readingTagID
        insertBook(into: context, tag: reading)
        insertApple(into: context, tag: reading)

        let settings = try UserSettings.current(in: context)
        settings.nativeLanguage = "ru"
        settings.activeGrammarTopics = ["en.present_perfect", "en.second_conditional"]
        settings.autoGenerateImages = false
        try context.save()
    }

    private static func insertBook(into context: ModelContext, tag: WordhoardCore.Tag) {
        let book = Word(headword: "book")
        book.id = bookID
        book.pronunciation = "buk"
        book.note = "from the spike"
        book.createdAt = bookCreatedAt
        book.updatedAt = bookUpdatedAt
        context.insert(book)
        book.tags = [tag]
        book.image = ImageAsset(fileName: "book.heic", source: .generated)

        let noun = Sense(
            partOfSpeech: .noun,
            definition: "a written work",
            order: 0,
            senseSource: .wordnet,
            gloss: "a written work or composition that has been published",
            translation: "книга",
            synonyms: ["volume", "tome"],
            antonyms: [],
            fieldSources: ["definition": .user, "synonyms": .auto]
        )
        noun.id = nounSenseID
        let verb = Sense(
            partOfSpeech: .verb,
            definition: "to reserve",
            order: 1,
            synonyms: ["reserve"],
            antonyms: ["cancel"]
        )
        verb.id = verbSenseID
        book.senses = [noun, verb]

        let nounExamples = [
            Example(text: "She has read a book.", source: .auto, grammarTopic: "en.present_perfect", order: 0),
            Example(text: "The book is on the table.", source: .auto, grammarTopic: "en.no_such_topic", order: 1),
        ]
        nounExamples[0].id = uuid(20)
        nounExamples[1].id = uuid(21)
        noun.examples = nounExamples
        let verbExamples = [
            Example(text: "I booked a table for two.", source: .auto, order: 0),
            Example(text: "Book early.", source: .user, order: 1),
        ]
        verbExamples[0].id = uuid(22)
        verbExamples[1].id = uuid(23)
        verb.examples = verbExamples
    }

    private static func insertApple(into context: ModelContext, tag: WordhoardCore.Tag) {
        let apple = Word(headword: "apple")
        apple.id = appleID
        apple.createdAt = appleCreatedAt
        apple.updatedAt = appleCreatedAt
        context.insert(apple)
        apple.tags = [tag]
        let fruit = Sense(partOfSpeech: .other, definition: "a fruit", order: 0)
        fruit.id = appleSenseID
        apple.senses = [fruit]
    }
}

/// Row counts of every table an import can touch.
struct RowCounts: Equatable {
    var words: Int
    var senses: Int
    var examples: Int
    var tags: Int
    var settings: Int

    @MainActor
    init(in container: ModelContainer) throws {
        let context = ModelContext(container)
        words = try context.fetchCount(FetchDescriptor<Word>())
        senses = try context.fetchCount(FetchDescriptor<Sense>())
        examples = try context.fetchCount(FetchDescriptor<Example>())
        tags = try context.fetchCount(FetchDescriptor<WordhoardCore.Tag>())
        settings = try context.fetchCount(FetchDescriptor<UserSettings>())
    }
}

/// The export's text. Fails the test on anything but UTF-8.
func utf8(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    try #require(String(bytes: data, encoding: .utf8), sourceLocation: sourceLocation)
}

/// `lhs` and `rhs` agree to the millisecond, the precision of the file.
func sameMillisecond(_ lhs: Date, _ rhs: Date) -> Bool {
    abs(lhs.timeIntervalSince(rhs)) < 0.001
}

/// Replaces one exact fragment of a pretty-printed export, e.g. `"schemaVersion" : 1`. Fails the test if
/// the fragment is absent, so a hand-edited case never silently tests the unedited file.
func replacing(
    _ fragment: String,
    in json: String,
    with replacement: String,
    sourceLocation: SourceLocation = #_sourceLocation
) -> String {
    #expect(json.contains(fragment), "fragment \(fragment) not in the export", sourceLocation: sourceLocation)
    return json.replacingOccurrences(of: fragment, with: replacement)
}
