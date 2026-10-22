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
    /// Namespaced grammar topic keys the user is currently learning (G2, S2). The stored default is
    /// empty; `current(in:catalog:)` seeds it from the catalog when it creates the record. Keys the
    /// catalog no longer knows are kept and ignored by readers via `GrammarCatalog.topic(for:)`.
    public var activeGrammarTopics: [GrammarTopicID] = []
    public var autoGenerateImages: Bool = true
    /// Set by the onboarding sheet's Continue (S1, plan 5.2) and never reset. `nativeLanguage == nil`
    /// cannot mean "not asked yet", because "No translation" is `nil` too. Device state, not the user's
    /// data: not exported by 1.7 and never changed by an import.
    public var hasCompletedOnboarding: Bool = false

    init() {}

    /// Fetches the settings record, creating and inserting it into `context` on first call. The
    /// caller saves. If more than one record exists (possible only after a future sync merge), the
    /// one with the lowest `id` is returned, so the choice is stable across launches and devices.
    ///
    /// Only the call that creates the record seeds `activeGrammarTopics` with
    /// `catalog.defaultActiveKeys`. An existing record is never re-seeded, even when its list is
    /// empty: deselecting every topic is a valid choice meaning "neutral examples only".
    public static func current(
        in context: ModelContext,
        catalog: GrammarCatalog = .english
    ) throws -> UserSettings {
        var descriptor = FetchDescriptor<UserSettings>(sortBy: [SortDescriptor(\.id)])
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let settings = UserSettings()
        settings.activeGrammarTopics = catalog.defaultActiveKeys
        context.insert(settings)
        return settings
    }
}
