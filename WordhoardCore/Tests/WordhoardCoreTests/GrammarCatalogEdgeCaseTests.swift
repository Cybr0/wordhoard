import Foundation
import SwiftData
import Testing
import WordhoardCore

// MARK: - Lookup

@Test("a key that differs from a catalog key only by whitespace, case or punctuation looks up to nil")
func nearMissKeysLookUpToNil() {
    let catalog = GrammarCatalog.english
    let nearMisses = [
        "en.present_perfect ", " en.present_perfect", "en.present_perfect\n", "en.present_perfect\t",
        "en.Present_Perfect", "en.present-perfect", "en.present_perfect.", "en..present_perfect",
        "en .present_perfect", "en.present perfect", "en.present_perfect_", "e\u{200B}n.present_perfect",
    ]
    for key in nearMisses {
        #expect(catalog.topic(for: key) == nil, "\(key.debugDescription)")
    }
    #expect(catalog.topic(for: "en.present_perfect") != nil)
}

@Test("the shared catalog is read concurrently from several tasks without corruption")
func sharedCatalogIsSafeToReadConcurrently() async {
    struct Snapshot: Equatable {
        let topicCount: Int
        let defaultCount: Int
        let articlesName: String?
    }
    let snapshots = await withTaskGroup(of: Snapshot.self) { group in
        for _ in 0 ..< 16 {
            group.addTask {
                let catalog = GrammarCatalog.english
                return Snapshot(
                    topicCount: catalog.topics.count,
                    defaultCount: catalog.defaultActiveKeys.count,
                    articlesName: catalog.topic(for: "en.articles")?.name
                )
            }
        }
        var results: [Snapshot] = []
        for await snapshot in group {
            results.append(snapshot)
        }
        return results
    }
    #expect(snapshots.count == 16)
    #expect(snapshots.allSatisfy { $0 == Snapshot(topicCount: 32, defaultCount: 5, articlesName: "Articles") })
}

// MARK: - Loading

@Test("loading with a file-name-like, padded or upper-cased language code throws resourceNotFound, not a trap")
func loadingWithAnOddLanguageCodeThrowsResourceNotFound() {
    // `""` and `"./en"` resolve to `en.json` at the bundle level; the loader must still reject them.
    for language in ["en.json", "GrammarCatalog/en", "../en", "./en", " en", "EN", "en ", ""] {
        #expect(throws: GrammarCatalogError.resourceNotFound(language: language), "\(language.debugDescription)") {
            try GrammarCatalog.load(language: language)
        }
    }
}

@Test("a catalog with a multi-line topic name fails to load")
func catalogWithMultiLineNameFailsToLoad() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "language": "xx",
        "defaultActive": [],
        "groups": [["name": "Group", "topics": [["key": "xx.alpha", "name": "Al\npha", "description": "d"]]]],
    ] as [String: Any])
    #expect(throws: GrammarCatalogError.invalidName(key: "xx.alpha")) { try GrammarCatalog(decoding: data) }
}

@Test("a catalog whose defaultActive is missing does not decode")
func catalogWithoutDefaultActiveFailsToDecode() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "language": "xx",
        "groups": [["name": "Group", "topics": [["key": "xx.alpha", "name": "Alpha", "description": "d"]]]],
    ] as [String: Any])
    #expect(throws: DecodingError.self) { try GrammarCatalog(decoding: data) }
}

// MARK: - Settings seeding

private func makeSmallCatalog() throws -> GrammarCatalog {
    try GrammarCatalog(decoding: Data(
        """
        {
          "language": "xx",
          "defaultActive": ["xx.beta"],
          "groups": [{ "name": "G", "topics": [
            { "key": "xx.alpha", "name": "Alpha", "description": "a" },
            { "key": "xx.beta", "name": "Beta", "description": "b" }
          ] }]
        }
        """.utf8
    ))
}

@Test("an existing record keeps its full default list when a later call passes a different catalog")
func existingRecordIsNotReseededFromADifferentCatalog() throws {
    let small = try makeSmallCatalog()
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let created = try UserSettings.current(in: context)
    #expect(created.activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)

    // Same context, before save: the record already exists, so the new catalog must be ignored.
    let again = try UserSettings.current(in: context, catalog: small)
    #expect(again === created)
    #expect(again.activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)
    try context.save()

    // Fresh context after save: still the original list, still one record.
    let fresh = ModelContext(container)
    let reopened = try UserSettings.current(in: fresh, catalog: small)
    #expect(reopened.activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)
    #expect(try fresh.fetchCount(FetchDescriptor<UserSettings>()) == 1)
}

@Test("a record seeded by an older catalog keeps its list when the shipped catalog's defaults change")
func recordSeededByAnOlderCatalogKeepsItsListAfterTheDefaultsChange() throws {
    let older = try makeSmallCatalog()
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    _ = try UserSettings.current(in: context, catalog: older)
    try context.save()

    let reopened = try UserSettings.current(in: ModelContext(container))
    #expect(reopened.activeGrammarTopics == ["xx.beta"])
    #expect(GrammarCatalog.english.topic(for: "xx.beta") == nil)
}

@Test("a catalog with no defaults seeds an empty list and the empty list survives reopening")
func catalogWithNoDefaultsSeedsAnEmptyList() throws {
    let noDefaults = try GrammarCatalog(decoding: Data(
        """
        {
          "language": "xx",
          "defaultActive": [],
          "groups": [{ "name": "G", "topics": [{ "key": "xx.alpha", "name": "Alpha", "description": "a" }] }]
        }
        """.utf8
    ))
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    #expect(try UserSettings.current(in: context, catalog: noDefaults).activeGrammarTopics.isEmpty)
    try context.save()
    #expect(try UserSettings.current(in: ModelContext(container)).activeGrammarTopics.isEmpty)
}

// MARK: - Example keys are not validated at the store

@Test("an example keeps a grammar topic key the catalog does not know")
func exampleKeepsAnUnknownGrammarTopicKey() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let word = Word(headword: "book")
    context.insert(word)
    let sense = Sense(partOfSpeech: .noun, definition: "a written work", order: 0)
    word.senses = [sense]
    sense.examples = [
        Example(text: "A future-version topic.", source: .auto, grammarTopic: "en.not_yet_a_topic", order: 0),
        Example(text: "A foreign topic.", source: .user, grammarTopic: "de.perfekt", order: 1),
        Example(text: "A neutral example.", source: .user, grammarTopic: nil, order: 2),
    ]
    try context.save()

    let examples = try ModelContext(container).fetch(FetchDescriptor<Example>(sortBy: [SortDescriptor(\.order)]))
    #expect(examples.map(\.grammarTopic) == ["en.not_yet_a_topic", "de.perfekt", nil])
    #expect(examples.compactMap(\.grammarTopic).allSatisfy { GrammarCatalog.english.topic(for: $0) == nil })
}
