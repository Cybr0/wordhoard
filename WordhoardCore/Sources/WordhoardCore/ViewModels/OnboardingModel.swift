import Foundation
import Observation
import os

/// State for the first-launch sheet (S1, plan 5.2, #44): the language list, the preselection and the
/// one write, `complete()`.
///
/// **Isolation: `@MainActor`**, like the `WordStore` it writes through.
@MainActor
@Observable
public final class OnboardingModel {
    /// The languages after `load()`, empty before.
    public private(set) var languages: [NativeLanguage] = []
    /// The chosen tag; `nil` is "No translation".
    public var selection: String?
    /// The system language is neither English nor in the list, so "No translation" was preselected and
    /// the sheet says why.
    public private(set) var isSystemLanguageUnsupported = false
    /// `complete()` could not save; the sheet stays and shows an alert.
    public var failure = false

    public let systemLanguage: String
    private let store: WordStore
    private let source: any SupportedLanguageSource
    private let logger = Logger(subsystem: "Wordhoard", category: "settings")

    public init(
        store: WordStore,
        languages: any SupportedLanguageSource,
        systemLanguage: String = Locale.preferredLanguages.first ?? "en"
    ) {
        self.store = store
        source = languages
        self.systemLanguage = systemLanguage
    }

    /// The system language's name in the current locale, for the unsupported note.
    public var systemLanguageName: String {
        NativeLanguage(tag: systemLanguage).displayName
    }

    public func load() async {
        languages = await NativeLanguageCatalog.ordered(supported: source.supportedLanguageTags())
        selection = NativeLanguageCatalog.preselection(systemLanguage: systemLanguage, in: languages)
        isSystemLanguageUnsupported = selection == nil && NativeLanguageCatalog.languageCode(of: systemLanguage) != "en"
    }

    /// Stores the choice and the onboarded flag in one save. `false`, with `failure` set, when it could
    /// not be saved.
    public func complete() -> Bool {
        let selection = selection
        do {
            try store.updateSettings {
                $0.nativeLanguage = selection
                $0.hasCompletedOnboarding = true
            }
            return true
        } catch {
            logger.error("Could not save the onboarding choice: \(error.localizedDescription, privacy: .public)")
            failure = true
            return false
        }
    }
}
