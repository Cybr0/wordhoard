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

    func supportedLanguageTags() async -> Set<String>? {
        await withTaskGroup(of: Set<String>?.self) { group in
            group.addTask {
                await Self.query()
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return nil
            }
            let first = await group.next().flatMap(\.self)
            group.cancelAll()
            return first
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
