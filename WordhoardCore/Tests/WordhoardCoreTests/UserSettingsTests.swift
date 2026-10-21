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
