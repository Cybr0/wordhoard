import Foundation

/// One language translations can be in (S1): its BCP-47 tag as stored in
/// `UserSettings.nativeLanguage`, and its name in the user's language.
public struct NativeLanguage: Hashable, Sendable, Identifiable {
    public let tag: String

    public var id: String {
        tag
    }

    public init(tag: String) {
        self.tag = tag
    }

    /// "Russian", "Chinese (Traditional)", … in the current locale; the tag when the system has no name.
    public var displayName: String {
        Self.name(of: tag, in: .current)
    }

    static func name(of tag: String, in locale: Locale) -> String {
        locale.localizedString(forIdentifier: tag) ?? tag
    }
}

/// Which languages the Translation framework can translate English into on this device; implemented in
/// the app over `LanguageAvailability`, so Core never queries the framework for the list.
public protocol SupportedLanguageSource: Sendable {
    /// The supported tags in `NativeLanguageCatalog` form, or `nil` when they could not be determined
    /// (show everything known).
    func supportedLanguageTags() async -> Set<String>?
}
