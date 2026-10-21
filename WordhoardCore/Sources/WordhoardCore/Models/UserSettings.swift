import Foundation
import SwiftData

/// The single settings record (requirements S1–S5).
///
/// Obtain it only through `UserSettings.current(in:)`, which creates the record on first use.
@Model
public final class UserSettings {
    public var id: UUID = UUID()
    /// BCP-47 tag of the user's language, e.g. `"ru"`, `"zh-Hans"`; `nil` means no translation (S1).
    public var nativeLanguage: String?
    public var learningLanguage: String = "en"
    /// Namespaced grammar topic keys. Empty until plan task 1.3 supplies the catalog default.
    public var activeGrammarTopics: [String] = []
    public var autoGenerateImages: Bool = true

    init() {}

    /// Fetches the settings record, creating and inserting it into `context` on first call. The
    /// caller saves. If more than one record exists (possible only after a future sync merge), the
    /// one with the lowest `id` is returned, so the choice is stable across launches and devices.
    public static func current(in context: ModelContext) throws -> UserSettings {
        var descriptor = FetchDescriptor<UserSettings>(sortBy: [SortDescriptor(\.id)])
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let settings = UserSettings()
        context.insert(settings)
        return settings
    }
}
