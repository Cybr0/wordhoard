import Foundation
import SwiftData

/// The merge rules of an import, applied in file order inside one `WordStore.transaction` (issue #36).
///
/// "Key" is `Word.normalize(headword)`. Every comparison is made before assigning, so an unchanged
/// value writes nothing and counts nothing. Word matching, in this order: (a) an active local word with
/// the same id is updated; (b) a soft-deleted local word with the same id is revived, unless another
/// active word owns the key; (c) no local word with the id but an active local word with the key: merge
/// into it, keeping the local id (C4); (d) otherwise insert with the file's id. Incoming wins for every
/// field of a matched word and its tag set; a rename onto another active word's key skips the whole word.
/// Senses and examples match by id within their parent only; local ones absent from the file are kept.
/// Tags match by id, then by name. Settings are replaced.
@MainActor
struct ImportMerge {
    private let context: ModelContext
    private let document: ExportDocument
    private var summary = ImportSummary()

    private var wordsByID: [UUID: Word] = [:]
    /// The oldest active word per key, kept current as words are inserted, revived and renamed.
    private var activeByKey: [String: Word] = [:]
    private var senseIDs: Set<UUID>
    private var exampleIDs: Set<UUID>
    /// File tag id → the local tag it resolved to.
    private var tagsByFileID: [UUID: Tag] = [:]

    init(document: ExportDocument, context: ModelContext) throws {
        self.document = document
        self.context = context
        let words = try context.fetch(FetchDescriptor<Word>(
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        ))
        for word in words {
            wordsByID[word.id] = word
            if word.deletedAt == nil, activeByKey[word.normalized] == nil {
                activeByKey[word.normalized] = word
            }
        }
        senseIDs = try Set(context.fetch(FetchDescriptor<Sense>()).map(\.id))
        exampleIDs = try Set(context.fetch(FetchDescriptor<Example>()).map(\.id))
    }

    mutating func run() throws -> ImportSummary {
        try mergeSettings()
        try mergeTags()
        for word in document.words {
            mergeWord(word)
        }
        return summary
    }

    // MARK: - Settings and tags

    private mutating func mergeSettings() throws {
        let settings = try UserSettings.current(in: context)
        let incoming = document.settings
        let changes = [
            assign(settings, \.nativeLanguage, incoming.nativeLanguage),
            assign(settings, \.learningLanguage, incoming.learningLanguage),
            assign(settings, \.activeGrammarTopics, incoming.activeGrammarTopics),
            assign(settings, \.autoGenerateImages, incoming.autoGenerateImages),
        ]
        summary.settingsChanged = changes.contains(true)
    }

    private mutating func mergeTags() throws {
        let local = try context.fetch(FetchDescriptor<Tag>())
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byName = Dictionary(local.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for fileTag in document.tags {
            let name = Importer.trimmed(fileTag.name)
            guard !name.isEmpty else {
                continue
            }
            if let tag = byID[fileTag.id] {
                if tag.name != name {
                    tag.name = name
                    byName[name] = tag
                    summary.tagsUpdated += 1
                }
                tagsByFileID[fileTag.id] = tag
            } else if let tag = byName[name] {
                tagsByFileID[fileTag.id] = tag
            } else {
                let tag = Tag(name: name)
                tag.id = fileTag.id
                context.insert(tag)
                byID[tag.id] = tag
                byName[name] = tag
                tagsByFileID[fileTag.id] = tag
                summary.tagsCreated += 1
            }
        }
    }

    // MARK: - Words

    private mutating func mergeWord(_ file: ExportWord) {
        let headword = Importer.trimmed(file.headword)
        guard !headword.isEmpty else {
            summary.wordsSkipped += 1
            return
        }
        let key = Word.normalize(headword)
        guard let match = target(for: file, headword: headword, key: key) else {
            summary.wordsSkipped += 1
            return
        }
        let (word, created) = match
        let fieldsChanged = applyFields(file, headword: headword, key: key, to: word)
        let tagsChanged = applyTags(file.tagIDs, to: word)
        let sensesChanged = mergeSenses(file.senses, into: word)
        if created {
            summary.wordsCreated += 1
        } else if fieldsChanged || tagsChanged || sensesChanged {
            summary.wordsUpdated += 1
        }
    }

    /// Rules (a)–(d); `nil` when the word must be skipped because its key belongs to another active word.
    private mutating func target(for file: ExportWord, headword: String, key: String) -> (Word, created: Bool)? {
        let owner = activeByKey[key]
        if let local = wordsByID[file.id] {
            if local.deletedAt == nil {
                if let owner, owner !== local {
                    return nil
                }
                return (local, created: false)
            }
            if let owner {
                return (owner, created: false)
            }
            local.deletedAt = nil
            activeByKey[key] = local
            return (local, created: true)
        }
        if let owner {
            return (owner, created: false)
        }
        let word = Word(headword: headword)
        word.id = file.id
        context.insert(word)
        wordsByID[word.id] = word
        activeByKey[key] = word
        return (word, created: true)
    }

    private mutating func applyFields(_ file: ExportWord, headword: String, key: String, to word: Word) -> Bool {
        let previousKey = word.normalized
        let changes = [
            assign(word, \.headword, headword),
            assign(word, \.normalized, key),
            assign(word, \.learningLanguage, file.learningLanguage),
            assign(word, \.pronunciation, file.pronunciation),
            assign(word, \.note, file.note),
            assignDate(word, \.createdAt, file.createdAt),
            assignDate(word, \.updatedAt, file.updatedAt),
        ]
        if previousKey != key {
            if activeByKey[previousKey] === word {
                activeByKey.removeValue(forKey: previousKey)
            }
            activeByKey[key] = word
        }
        return changes.contains(true)
    }

    /// Replaces the tag set with the resolved `tagIDs`; ids absent from the file's `tags` are ignored.
    private func applyTags(_ tagIDs: [UUID], to word: Word) -> Bool {
        var seen = Set<UUID>()
        let resolved = tagIDs.compactMap { tagsByFileID[$0] }.filter { seen.insert($0.id).inserted }
        guard Set(word.tags.map(\.id)) != seen else {
            return false
        }
        word.tags = resolved
        return true
    }

    // MARK: - Senses and examples

    private mutating func mergeSenses(_ senses: [ExportSense], into word: Word) -> Bool {
        var changed = false
        let local = Dictionary(word.senses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for file in senses {
            if let sense = local[file.id] {
                let fieldsChanged = applySenseFields(file, to: sense)
                let examplesChanged = mergeExamples(file.examples, into: sense)
                if fieldsChanged || examplesChanged {
                    summary.sensesUpdated += 1
                    changed = true
                }
            } else {
                let sense = Sense(
                    partOfSpeech: file.partOfSpeech,
                    definition: file.definition,
                    order: file.order,
                    senseSource: file.senseSource,
                    gloss: file.gloss,
                    translation: file.translation,
                    synonyms: file.synonyms,
                    antonyms: file.antonyms,
                    fieldSources: file.fieldSources
                )
                sense.id = senseIDs.contains(file.id) ? UUID() : file.id
                senseIDs.insert(sense.id)
                context.insert(sense)
                word.senses.append(sense)
                _ = mergeExamples(file.examples, into: sense)
                summary.sensesCreated += 1
                changed = true
            }
        }
        return changed
    }

    private func applySenseFields(_ file: ExportSense, to sense: Sense) -> Bool {
        let changes = [
            assign(sense, \.order, file.order),
            assign(sense, \.partOfSpeech, file.partOfSpeech),
            assign(sense, \.senseSource, file.senseSource),
            assign(sense, \.gloss, file.gloss),
            assign(sense, \.definition, file.definition),
            assign(sense, \.translation, file.translation),
            assign(sense, \.synonyms, file.synonyms),
            assign(sense, \.antonyms, file.antonyms),
            assign(sense, \.fieldSources, file.fieldSources),
        ]
        return changes.contains(true)
    }

    private mutating func mergeExamples(_ examples: [ExportExample], into sense: Sense) -> Bool {
        var changed = false
        let local = Dictionary(sense.examples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for file in examples {
            if let example = local[file.id] {
                let changes = [
                    assign(example, \.order, file.order),
                    assign(example, \.text, file.text),
                    assign(example, \.grammarTopic, file.grammarTopic),
                    assign(example, \.source, file.source),
                ]
                if changes.contains(true) {
                    summary.examplesUpdated += 1
                    changed = true
                }
            } else {
                let example = Example(
                    text: file.text,
                    source: file.source,
                    grammarTopic: file.grammarTopic,
                    order: file.order
                )
                example.id = exampleIDs.contains(file.id) ? UUID() : file.id
                exampleIDs.insert(example.id)
                context.insert(example)
                sense.examples.append(example)
                summary.examplesCreated += 1
                changed = true
            }
        }
        return changed
    }

    // MARK: - Compare before assign

    private func assign<Root: AnyObject, Value: Equatable>(
        _ root: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) -> Bool {
        guard root[keyPath: keyPath] != value else {
            return false
        }
        root[keyPath: keyPath] = value
        return true
    }

    /// Dates are compared to 1 ms, the precision of the file, so a store value that round-tripped through
    /// an export is not rewritten.
    private func assignDate<Root: AnyObject>(
        _ root: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Date>,
        _ value: Date
    ) -> Bool {
        guard abs(root[keyPath: keyPath].timeIntervalSince(value)) >= 0.001 else {
            return false
        }
        root[keyPath: keyPath] = value
        return true
    }
}
