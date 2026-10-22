import Foundation
import SwiftData
import Testing
import WordhoardCore

/// Export and import through the Settings rows, and what an import does not touch: pictures, the
/// picture queue and the onboarding flag (qa, PR #63; plans 4.4, 5.2, 5.3).
@MainActor
@Suite("Settings export and import")
struct SettingsTransferQATests {
    private static let exportedAt = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("export then import through the settings model round-trips the hoard, and a second import is a no-op")
    func settingsExportImportRoundTrips() throws {
        let sourceContainer = try WordhoardContainer.makeInMemory()
        let source = WordStore(container: sourceContainer)
        try TransferFixture.insert(into: sourceContainer)
        let file = try SettingsModel(store: source).exportData(appVersion: "1.0.0 (1)")

        let target = try WordStore(container: WordhoardContainer.makeInMemory())
        let settings = SettingsModel(store: target)
        settings.load()
        let summary = try #require(settings.importWords(file))
        #expect(summary.wordsCreated == 2)
        #expect(settings.failure == nil)
        #expect(settings.nativeLanguage == "ru")
        #expect(settings.activeTopics == ["en.present_perfect", "en.second_conditional"])
        #expect(!settings.autoGenerateImages)

        let original = try Exporter.export(from: source, exportedAt: Self.exportedAt, appVersion: "1")
        let restored = try Exporter.export(from: target, exportedAt: Self.exportedAt, appVersion: "1")
        #expect(restored == original)

        let again = try #require(settings.importWords(file))
        #expect(again.wordsCreated == 0)
        #expect(again.wordsUpdated == 0)
        #expect(!again.settingsChanged)
    }

    @Test("an import never changes the onboarding flag, and later settings changes keep it")
    func importAndSettingsChangesKeepTheOnboardingFlag() async throws {
        let store = try WordStore(container: WordhoardContainer.makeInMemory())
        let onboarding = OnboardingModel(store: store, languages: FixedLanguageSource(tags: nil), systemLanguage: "en")
        await onboarding.load()
        #expect(onboarding.complete())

        let settings = SettingsModel(store: store)
        settings.setNativeLanguage("es")
        settings.setNativeLanguage(nil)
        settings.setAutoGenerateImages(false)
        settings.setTopicActive("en.past_simple", true)
        settings.resetTopicsToDefault()
        // A file exported from a store that was never onboarded.
        #expect(settings.importWords(GoldenExport.data)?.wordsCreated == 2)
        #expect(try store.settings().hasCompletedOnboarding)

        // And the other way: an import into a fresh install does not mark it onboarded.
        let fresh = try WordStore(container: WordhoardContainer.makeInMemory())
        let file = try SettingsModel(store: store).exportData(appVersion: "1.0.0 (1)")
        SettingsModel(store: fresh).importWords(file)
        #expect(try fresh.settings().hasCompletedOnboarding == false)
    }

    @Test("imported words get no picture status and no picture job")
    func importedWordsQueueNoPicture() async throws {
        let fixture = try ImageQueueFixture()
        #expect(SettingsModel(store: fixture.store).importWords(GoldenExport.data)?.wordsCreated == 2)

        try fixture.queue.resumePending()
        await fixture.queue.drain()
        let words = try fixture.store.words()
        #expect(words.count == 2)
        #expect(words.allSatisfy { $0.imageStatus == nil && $0.image == nil })
        #expect(fixture.writer.calls.isEmpty)
        #expect(try fixture.assetCount() == 0)
        #expect(fixture.directory.allFiles.isEmpty)
    }

    @Test("importing a store's own export keeps the picture a word already has")
    func importingOverAWordKeepsItsPicture() throws {
        let fixture = try ImageQueueFixture()
        let word = try fixture.store.add("apple").word
        #expect(try fixture.cardModel(word).setImage(data: makePNG(width: 20, height: 20), source: .library))
        let photo = try #require(word.image?.fileName)
        let settings = SettingsModel(store: fixture.store)
        let file = try settings.exportData(appVersion: "1.0.0 (1)")
        try fixture.store.updateSettings { $0.nativeLanguage = "ru" }

        #expect(settings.importWords(file) != nil)
        let stored = try fixture.storedWord(word)
        #expect(stored.image?.fileName == photo)
        #expect(stored.image?.source == .library)
        #expect(stored.imageStatus == nil)
        #expect(try fixture.assetCount() == 1)
        #expect(fixture.directory.allFiles == [photo, ImageStore.thumbnailFileName(for: photo)])
    }
}
