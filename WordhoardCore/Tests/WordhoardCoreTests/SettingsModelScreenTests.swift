import Foundation
import SwiftData
import Testing
import WordhoardCore

/// `SettingsModel` beyond topics (plan 5.3, #45): native language, the images toggle, export / import,
/// and the About screen's license text.
@MainActor
@Suite("SettingsModel screen")
struct SettingsModelScreenTests {
    let container: ModelContainer
    let store: WordStore
    let model: SettingsModel

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
        model = SettingsModel(store: store)
    }

    private func stored() throws -> UserSettings {
        try #require(try ModelContext(container).fetch(FetchDescriptor<UserSettings>()).first)
    }

    @Test("the auto-images toggle persists and defaults to on")
    func autoImagesTogglePersists() throws {
        model.load()
        #expect(model.autoGenerateImages)
        model.setAutoGenerateImages(false)
        #expect(try stored().autoGenerateImages == false)
        #expect(!model.autoGenerateImages)
    }

    @Test("importing through the settings model publishes the summary or the failure")
    func settingsImportPublishesSummaryOrFailure() throws {
        #expect(model.importWords(GoldenExport.data)?.wordsCreated == 2)
        #expect(model.importSummary?.wordsCreated == 2)
        #expect(model.failure == nil)
        #expect(try store.words().count == 2)

        model.importSummary = nil
        #expect(model.importWords(Data("{".utf8)) == nil)
        #expect(model.failure == .importing("This file isn't a Wordhoard export."))
        #expect(model.importSummary == nil)
    }

    @Test("an import that changes the settings is reflected after it")
    func importReloadsTheSettings() throws {
        model.load()
        let exported = try model.exportData(appVersion: "1.0.0 (1)")
        try store.updateSettings { $0.autoGenerateImages = false }
        model.load()
        try store.updateSettings { $0.autoGenerateImages = true }
        #expect(!model.autoGenerateImages, "not re-read until something loads")
        model.importWords(exported)
        #expect(model.autoGenerateImages)
    }

    @Test("the WordNet license text is in the bundle")
    func wordNetLicenseTextIsInTheBundle() throws {
        let text = try #require(CoreInfo.wordNetLicenseText())
        #expect(text.hasPrefix("Open English WordNet, 2024 edition"))
        #expect(CoreInfo.wordNetLicenseText(in: Bundle(for: BundleMarker.self)) == nil)
    }
}

/// A class in the test bundle, whose bundle has no WordNet resources.
private final class BundleMarker {}
