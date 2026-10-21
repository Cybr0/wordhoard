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
    #expect(settings.activeGrammarTopics == [])
    #expect(settings.autoGenerateImages == true)
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
