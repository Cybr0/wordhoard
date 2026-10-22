import Foundation

/// The native-language list (S1, plan 5.2, #44): data and rules only, so the order, the filtering and
/// the preselection are unit-tested without the Translation framework.
public enum NativeLanguageCatalog {
    /// S1's sixteen most common learner languages, in S1's order.
    public static let preferredOrder: [String] = [
        "ru", "es", "zh-Hans", "hi", "ar", "pt-BR", "fr", "de",
        "ja", "ko", "tr", "it", "vi", "id", "pl", "uk",
    ]

    /// The static fallback list: `preferredOrder`, then the other languages the framework is documented
    /// to support, alphabetically by English name. English is the learning language, so it is never
    /// listed. Exact membership is a device check (#44); a wrong entry is a one-line fix here.
    public static let knownSupported: [String] = preferredOrder + ["zh-Hant", "nl", "th"]

    /// The list to show: when `supported` is `nil` or empty (the framework could not be asked), every
    /// known language; otherwise the known ones the framework supports, in catalog order, then any
    /// supported tag the catalog does not know, alphabetically by English name. Never English.
    public static func ordered(supported: Set<String>?) -> [NativeLanguage] {
        guard let supported, !supported.isEmpty else {
            return knownSupported.map(NativeLanguage.init(tag:))
        }
        let known = knownSupported.filter(supported.contains)
        let english = Locale(identifier: "en")
        let extras = supported
            .subtracting(knownSupported)
            .filter { languageCode(of: $0) != "en" }
            .sorted { NativeLanguage.name(of: $0, in: english) < NativeLanguage.name(of: $1, in: english) }
        return (known + extras).map(NativeLanguage.init(tag:))
    }

    /// The tag to preselect for the system language, or `nil` for "No translation": an exact tag match,
    /// then the catalog form of the language (`zh-TW` → `zh-Hant`, `ru-RU` → `ru`), then any listed
    /// language with the same language code (`pt-PT` → `pt-BR`). English and unlisted languages → `nil`.
    public static func preselection(systemLanguage: String, in languages: [NativeLanguage]) -> String? {
        let tags = languages.map(\.tag)
        guard let code = languageCode(of: systemLanguage), code != "en" else {
            return nil
        }
        if tags.contains(systemLanguage) {
            return systemLanguage
        }
        let language = Locale.Language(identifier: systemLanguage)
        let tag = tag(
            languageCode: code,
            script: language.maximalIdentifier.split(separator: "-").dropFirst().first.map(String.init),
            region: language.region?.identifier
        )
        if tags.contains(tag) {
            return tag
        }
        return tags.first { languageCode(of: $0) == code }
    }

    /// The catalog form of a language: `language-script` or `language-region` when the catalog lists
    /// that variant (`zh-Hant`, `pt-BR`), otherwise the bare language code (`es-ES` → `es`).
    public static func tag(languageCode: String, script: String?, region: String?) -> String {
        let candidates = [script, region].compactMap { $0.map { "\(languageCode)-\($0)" } }
        return candidates.first(where: knownSupported.contains) ?? languageCode
    }

    static func languageCode(of tag: String) -> String? {
        Locale.Language(identifier: tag).languageCode?.identifier
    }
}
