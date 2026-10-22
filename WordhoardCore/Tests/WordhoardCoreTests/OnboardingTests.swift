import Foundation
import SwiftData
import Testing
import WordhoardCore

/// A fixed answer for the language list, or `nil` for "could not be asked".
struct FixedLanguageSource: SupportedLanguageSource {
    let tags: Set<String>?

    func supportedLanguageTags() async -> Set<String>? {
        tags
    }
}

/// Onboarding (plan 5.2, #44): the flag, the catalog, the preselection and the model.
@MainActor
@Suite("Onboarding")
struct OnboardingTests {
    let container: ModelContainer
    let store: WordStore

    init() throws {
        container = try WordhoardContainer.makeInMemory()
        store = WordStore(container: container)
    }

    private func storedSettings() throws -> UserSettings {
        try #require(try ModelContext(container).fetch(FetchDescriptor<UserSettings>()).first)
    }

    @Test("a new settings record is not onboarded")
    func aNewSettingsRecordIsNotOnboarded() throws {
        #expect(try store.settings().hasCompletedOnboarding == false)
    }

    @Test("completing onboarding persists")
    func completingOnboardingPersists() throws {
        try store.updateSettings { $0.hasCompletedOnboarding = true }
        #expect(try storedSettings().hasCompletedOnboarding)
    }

    @Test("the onboarding flag and a picture status survive an on-disk reopen")
    func newPropertiesSurviveAnOnDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordhoard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Wordhoard.store")
        do {
            let first = try WordStore(container: WordhoardContainer.makeOnDisk(url: url))
            try first.updateSettings { $0.hasCompletedOnboarding = true }
            let word = try first.add("apple").word
            try first.setImageStatus(.skipped, for: word)
        }
        let second = try WordStore(container: WordhoardContainer.makeOnDisk(url: url))
        #expect(try second.settings().hasCompletedOnboarding)
        #expect(try second.words().first?.imageStatus == .skipped)
    }

    @Test("the fallback list follows S1 order")
    func fallbackListFollowsS1Order() {
        let tags = NativeLanguageCatalog.ordered(supported: nil).map(\.tag)
        #expect(Array(tags.prefix(16)) == [
            "ru", "es", "zh-Hans", "hi", "ar", "pt-BR", "fr", "de", "ja", "ko", "tr", "it", "vi", "id", "pl", "uk",
        ])
        #expect(Array(tags.dropFirst(16)) == ["zh-Hant", "nl", "th"])
        #expect(!tags.contains { $0.hasPrefix("en") })
    }

    @Test("a supported set filters the list and appends unknown tags")
    func supportedSetFiltersAndAppendsUnknownTags() {
        let tags = NativeLanguageCatalog.ordered(supported: ["es", "ru", "nl", "xx", "en"]).map(\.tag)
        #expect(tags == ["ru", "es", "nl", "xx"])
        let extras = NativeLanguageCatalog.ordered(supported: ["ru", "sv", "da"]).map(\.tag)
        #expect(extras == ["ru", "da", "sv"], "Danish before Swedish")
    }

    @Test("an empty supported set means unknown")
    func anEmptySupportedSetMeansUnknown() {
        #expect(NativeLanguageCatalog.ordered(supported: []) == NativeLanguageCatalog.ordered(supported: nil))
    }

    @Test("preselection matches the tag, then the language code")
    func preselectionMatchesTagThenLanguageCode() {
        let all = NativeLanguageCatalog.ordered(supported: nil)
        let cases: [(String, String?)] = [
            ("ru-RU", "ru"), ("zh-Hans-CN", "zh-Hans"), ("zh-TW", "zh-Hant"), ("zh-Hant-HK", "zh-Hant"),
            ("pt-PT", "pt-BR"), ("pt-BR", "pt-BR"), ("es-419", "es"), ("uz", nil), ("kk-KZ", nil), ("en-GB", nil),
        ]
        for (system, expected) in cases {
            #expect(NativeLanguageCatalog.preselection(systemLanguage: system, in: all) == expected, "\(system)")
        }
        let spanishOnly = [NativeLanguage(tag: "es")]
        #expect(NativeLanguageCatalog.preselection(systemLanguage: "ru", in: spanishOnly) == nil)
    }

    @Test("framework languages map to catalog tags")
    func frameworkLanguagesMapToCatalogTags() {
        #expect(NativeLanguageCatalog.tag(languageCode: "zh", script: "Hant", region: "TW") == "zh-Hant")
        #expect(NativeLanguageCatalog.tag(languageCode: "pt", script: "Latn", region: "BR") == "pt-BR")
        #expect(NativeLanguageCatalog.tag(languageCode: "es", script: "Latn", region: "ES") == "es")
        #expect(NativeLanguageCatalog.tag(languageCode: "sv", script: nil, region: nil) == "sv")
    }

    @Test("onboarding preselects the system language")
    func onboardingPreselectsTheSystemLanguage() async {
        let model = OnboardingModel(
            store: store,
            languages: FixedLanguageSource(tags: ["ru", "es"]),
            systemLanguage: "ru-RU"
        )
        await model.load()
        #expect(model.languages.map(\.tag) == ["ru", "es"])
        #expect(model.selection == "ru")
        #expect(!model.isSystemLanguageUnsupported)
    }

    @Test("an unsupported system language preselects No translation")
    func unsupportedSystemLanguagePreselectsNoTranslation() async {
        let model = OnboardingModel(
            store: store,
            languages: FixedLanguageSource(tags: ["ru", "es"]),
            systemLanguage: "uz"
        )
        await model.load()
        #expect(model.selection == nil)
        #expect(model.isSystemLanguageUnsupported)
    }

    @Test("an English system language is not flagged")
    func englishSystemLanguageIsNotFlagged() async {
        let model = OnboardingModel(store: store, languages: FixedLanguageSource(tags: ["ru"]), systemLanguage: "en-US")
        await model.load()
        #expect(model.selection == nil)
        #expect(!model.isSystemLanguageUnsupported)
    }

    @Test("an unqueryable source shows every known language")
    func unqueryableSourceShowsEveryKnownLanguage() async {
        let model = OnboardingModel(store: store, languages: FixedLanguageSource(tags: nil), systemLanguage: "de-DE")
        await model.load()
        #expect(model.languages.map(\.tag) == NativeLanguageCatalog.knownSupported)
        #expect(model.selection == "de")
    }

    @Test("completing stores the choice and the flag")
    func completingStoresTheChoiceAndTheFlag() async throws {
        let model = OnboardingModel(store: store, languages: FixedLanguageSource(tags: nil), systemLanguage: "en")
        await model.load()
        model.selection = "es"
        #expect(model.complete())
        let settings = try storedSettings()
        #expect(settings.nativeLanguage == "es")
        #expect(settings.hasCompletedOnboarding)
    }

    @Test("completing with No translation stores nil")
    func completingWithNoTranslationStoresNil() async throws {
        try store.updateSettings { $0.nativeLanguage = "ru" }
        let model = OnboardingModel(store: store, languages: FixedLanguageSource(tags: nil), systemLanguage: "uz")
        await model.load()
        #expect(model.complete())
        let settings = try storedSettings()
        #expect(settings.nativeLanguage == nil)
        #expect(settings.hasCompletedOnboarding)
        #expect(model.failure == false)
    }
}
