import Foundation
import OSLog
import Translation
import WordhoardCore

/// The languages Apple's Translation framework can translate into on this device (S1, plan 5.2), in
/// `NativeLanguageCatalog` form (`zh-Hant`, `pt-BR`, else the language code), English dropped. `nil`
/// when the framework gives nothing or takes longer than two seconds, so the onboarding sheet never
/// waits offline; the caller then shows every known language.
struct TranslationLanguageSource: SupportedLanguageSource {
    private static let timeout = Duration.seconds(2)

    /// `withTimeLimit` returns at the limit even if the framework query ignores cancellation.
    func supportedLanguageTags() async -> Set<String>? {
        await withTimeLimit(Self.timeout) {
            await Self.query()
        }
    }

    private static func query() async -> Set<String>? {
        let languages = await LanguageAvailability().supportedLanguages
        let tags = Set(languages.compactMap { language -> String? in
            guard let code = language.languageCode?.identifier, code != "en" else {
                return nil
            }
            let script = language.script?.identifier ?? Locale.Language(identifier: language.maximalIdentifier)
                .script?.identifier
            return NativeLanguageCatalog.tag(languageCode: code, script: script, region: language.region?.identifier)
        })
        if tags.isEmpty {
            Logger(subsystem: "Wordhoard", category: "settings").notice("Translation listed no languages")
            return nil
        }
        return tags
    }
}
