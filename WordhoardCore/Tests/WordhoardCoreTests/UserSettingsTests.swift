import Foundation
import SwiftData
import Testing
import WordhoardCore

@Test("the settings helper returns a single record")
func settingsHelperReturnsASingleRecord() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let first = try UserSettings.current(in: context)
    let second = try UserSettings.current(in: context)
    try context.save()

    #expect(first.id == second.id)
    #expect(first === second)
    #expect(try context.fetchCount(FetchDescriptor<UserSettings>()) == 1)

    let fresh = ModelContext(container)
    let reopened = try UserSettings.current(in: fresh)
    #expect(reopened.id == first.id)
    #expect(try fresh.fetchCount(FetchDescriptor<UserSettings>()) == 1)
}

@Test("settings defaults match the requirements")
func settingsDefaultsMatchTheRequirements() throws {
    let container = try WordhoardContainer.makeInMemory()
    let settings = try UserSettings.current(in: ModelContext(container))
    #expect(settings.nativeLanguage == nil)
    #expect(settings.learningLanguage == "en")
    #expect(
        settings.activeGrammarTopics == [
            "en.present_perfect", "en.past_simple", "en.first_conditional", "en.second_conditional",
            "en.passive_voice",
        ]
    )
    #expect(settings.autoGenerateImages == true)
}

@Test("a new settings record starts with the catalog's default topics")
func newSettingsRecordStartsWithTheDefaultTopics() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let settings = try UserSettings.current(in: context)
    #expect(settings.activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)
    try context.save()

    let fresh = ModelContext(container)
    #expect(try UserSettings.current(in: fresh).activeGrammarTopics == GrammarCatalog.english.defaultActiveKeys)
    #expect(try fresh.fetchCount(FetchDescriptor<UserSettings>()) == 1)
}

@Test("a new settings record is seeded from the catalog it is given")
func newSettingsRecordIsSeededFromTheGivenCatalog() throws {
    let small = try GrammarCatalog(decoding: Data(
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
    let container = try WordhoardContainer.makeInMemory()
    let settings = try UserSettings.current(in: ModelContext(container), catalog: small)
    #expect(settings.activeGrammarTopics == ["xx.beta"])
}

@Test("an existing settings record is not re-seeded, even when its topic list is empty")
func existingSettingsRecordIsNotReseeded() throws {
    for chosen in [[], ["en.articles"]] as [[GrammarTopicID]] {
        let container = try WordhoardContainer.makeInMemory()
        let context = ModelContext(container)
        let settings = try UserSettings.current(in: context)
        settings.activeGrammarTopics = chosen
        try context.save()

        let fresh = ModelContext(container)
        #expect(try UserSettings.current(in: fresh).activeGrammarTopics == chosen)
        #expect(try fresh.fetchCount(FetchDescriptor<UserSettings>()) == 1)
    }
}

@Test("active topic keys the catalog does not know are kept, not scrubbed")
func unknownActiveTopicKeysAreKept() throws {
    let container = try WordhoardContainer.makeInMemory()
    let context = ModelContext(container)
    let settings = try UserSettings.current(in: context)
    settings.activeGrammarTopics = ["en.not_a_topic", "en.articles"]
    try context.save()

    let reopened = try UserSettings.current(in: ModelContext(container))
    #expect(reopened.activeGrammarTopics == ["en.not_a_topic", "en.articles"])
    #expect(GrammarCatalog.english.topic(for: "en.not_a_topic") == nil)
    #expect(GrammarCatalog.english.topic(for: "en.articles") != nil)
}

@Test("with more than one settings record the helper always returns the one with the lowest id")
func settingsHelperPicksTheLowestIDWhenSeveralRecordsExist() throws {
    let container = try WordhoardContainer.makeInMemory()
    let contextA = ModelContext(container)
    let contextB = ModelContext(container)
    let fromA = try UserSettings.current(in: contextA)
    let fromB = try UserSettings.current(in: contextB)
    try contextA.save()
    try contextB.save()
    #expect(fromA.id != fromB.id)

    let fresh = ModelContext(container)
    #expect(try fresh.fetchCount(FetchDescriptor<UserSettings>()) == 2)
    let expected = min(fromA.id, fromB.id)
    #expect(try UserSettings.current(in: fresh).id == expected)
    #expect(try UserSettings.current(in: ModelContext(container)).id == expected)
}
