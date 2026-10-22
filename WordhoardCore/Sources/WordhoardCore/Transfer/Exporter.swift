import Foundation

/// Writes the user's hoard as an `ExportDocument` (requirements S3).
///
/// **Isolation: `@MainActor`**, like the `WordStore` it reads. Reads only `store.words()` (already
/// active-only) and `store.settings()`, and the words' `tags`; it never fetches the `Tag` or `Sense`
/// tables directly, so a tag that hangs only on a deleted word is not exported.
@MainActor
public enum Exporter {
    /// The whole hoard as JSON. `exportedAt` and `appVersion` are written verbatim so a test can pin the
    /// bytes; the app passes `.now` and `CFBundleShortVersionString (CFBundleVersion)`.
    public static func export(from store: WordStore, exportedAt: Date, appVersion: String) throws -> Data {
        try document(from: store, exportedAt: exportedAt, appVersion: appVersion).encode()
    }

    /// The hoard as a document: words `createdAt` ascending then `id`, tags by `name` then `id`,
    /// senses and examples in `order`, `tagIDs` sorted.
    ///
    /// `createdAt` is compared at the file's millisecond precision, so two words created within the
    /// same millisecond are ordered by `id` on both sides of a restore and the re-export is identical.
    public static func document(from store: WordStore, exportedAt: Date, appVersion: String) throws -> ExportDocument {
        let settings = try store.settings()
        let words = try store.words().sorted {
            (ExportDocument.roundedToMillisecond($0.createdAt), $0.id.uuidString)
                < (ExportDocument.roundedToMillisecond($1.createdAt), $1.id.uuidString)
        }

        var tagsByID: [UUID: Tag] = [:]
        for tag in words.flatMap(\.tags) {
            tagsByID[tag.id] = tag
        }
        let tags = tagsByID.values
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
            .map { ExportTag(id: $0.id, name: $0.name) }

        return ExportDocument(
            exportedAt: exportedAt,
            appVersion: appVersion,
            settings: ExportSettings(
                nativeLanguage: settings.nativeLanguage,
                learningLanguage: settings.learningLanguage,
                activeGrammarTopics: settings.activeGrammarTopics,
                autoGenerateImages: settings.autoGenerateImages
            ),
            tags: tags,
            words: words.map(exportWord)
        )
    }

    /// `Wordhoard-YYYY-MM-DD.json` for the local date. A file name, not a user-facing string.
    public static func fileName(for date: Date = .now, timeZone: TimeZone = .current) -> String {
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return "Wordhoard-\(day).json"
    }

    private static func exportWord(_ word: Word) -> ExportWord {
        ExportWord(
            id: word.id,
            learningLanguage: word.learningLanguage,
            headword: word.headword,
            pronunciation: word.pronunciation,
            note: word.note,
            createdAt: word.createdAt,
            updatedAt: word.updatedAt,
            tagIDs: word.tags.map(\.id).sorted { $0.uuidString < $1.uuidString },
            senses: word.sortedSenses.map(exportSense)
        )
    }

    private static func exportSense(_ sense: Sense) -> ExportSense {
        ExportSense(
            id: sense.id,
            order: sense.order,
            partOfSpeech: sense.partOfSpeech,
            senseSource: sense.senseSource,
            gloss: sense.gloss,
            definition: sense.definition,
            translation: sense.translation,
            translationIsFallback: sense.translationIsFallback,
            synonyms: sense.synonyms,
            antonyms: sense.antonyms,
            fieldSources: sense.fieldSources,
            examples: sense.sortedExamples.map { example in
                ExportExample(
                    id: example.id,
                    order: example.order,
                    text: example.text,
                    grammarTopic: example.grammarTopic,
                    source: example.source
                )
            }
        )
    }
}
