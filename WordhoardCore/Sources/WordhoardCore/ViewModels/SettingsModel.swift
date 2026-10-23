import Foundation
import Observation
import os

/// State for the settings screens (S1–S3, S5, G2; plans 3.1 and 5.3): the grammar topics (3.1), the
/// native language, the images toggle and export / import (5.3).
///
/// **Isolation: `@MainActor`**, like the `WordStore` it wraps. Every write goes through
/// `WordStore.updateSettings(_:)` and re-reads the record afterwards, so what is published is what was
/// saved. An unchanged value saves nothing.
///
/// Topic storage rule: the stored list holds the active known keys as one block in catalog order; keys
/// the catalog does not know (a newer build's, 1.3) keep their relative order, those before the first
/// known key stay before the block and all others follow it. Unknown keys are never published in
/// `activeTopics` and never removed, so `["en.present_perfect", "en.no_such_topic"]` with *Past simple*
/// switched on becomes `["en.present_perfect", "en.past_simple", "en.no_such_topic"]`.
@MainActor
@Observable
public final class SettingsModel {
    /// Something the store could not do. The view shows an alert and sets this back to `nil` on dismiss.
    public enum Failure: Equatable, Sendable {
        /// The settings record could not be read.
        case loading
        /// A change could not be saved; the published state was re-read from the record.
        case saving
        /// An import was refused (the `ImportError`'s description) or could not be saved (`nil`).
        /// Nothing was written either way.
        case importing(String?)
    }

    public let catalog: GrammarCatalog

    /// The active topics the catalog knows. Unknown stored keys never appear here.
    public private(set) var activeTopics: Set<GrammarTopicID> = []

    /// "Generate images automatically" (S5).
    public private(set) var autoGenerateImages = true

    /// What the last `importWords(_:)` did; the view sets it back to `nil` when the alert is dismissed.
    public var importSummary: ImportSummary?

    public var failure: Failure?

    private let store: WordStore
    private let autofill: AutofillService?
    private let logger = Logger(subsystem: "Wordhoard", category: "settings")

    /// `autofill` fills imported words that have no senses (1.7); `nil` leaves them pending.
    public init(store: WordStore, catalog: GrammarCatalog = .english, autofill: AutofillService? = nil) {
        self.store = store
        self.catalog = catalog
        self.autofill = autofill
    }

    /// Re-reads the record, so a change made elsewhere (an import, 1.7) shows when the screen appears.
    public func load() {
        do {
            let settings = try store.settings()
            activeTopics = knownKeys(in: settings.activeGrammarTopics)
            autoGenerateImages = settings.autoGenerateImages
        } catch {
            logger.error("Could not load settings: \(error.localizedDescription, privacy: .public)")
            failure = .loading
        }
    }

    /// Switches one topic on or off. A key the catalog does not know is a logged no-op; asking for the
    /// state the topic already has saves nothing. Deselecting every topic is allowed (G2).
    public func setTopicActive(_ key: GrammarTopicID, _ active: Bool) {
        guard catalog.topic(for: key) != nil else {
            logger.notice("Ignored a change to an unknown grammar topic: \(key, privacy: .public)")
            return
        }
        guard let stored = storedTopics() else {
            return
        }
        var known = knownKeys(in: stored)
        guard known.contains(key) != active else {
            activeTopics = known
            return
        }
        if active {
            known.insert(key)
        } else {
            known.remove(key)
        }
        write(Self.ordered(stored: stored, active: known, catalog: catalog), replacing: stored)
    }

    /// The catalog's default set; unknown keys are kept. Saves nothing when the list already matches.
    public func resetTopicsToDefault() {
        guard let stored = storedTopics() else {
            return
        }
        let topics = Self.ordered(stored: stored, active: Set(catalog.defaultActiveKeys), catalog: catalog)
        write(topics, replacing: stored)
    }

    // MARK: - Images and onboarding

    /// Whether new words get a picture automatically (S5); read by the picture queue on every add.
    public func setAutoGenerateImages(_ isOn: Bool) {
        change(\.autoGenerateImages, to: isOn)
    }

    /// Marks the first-launch sheet as done without asking: the `--ui-testing` preset (5.2).
    public func markOnboardingCompleted() {
        change(\.hasCompletedOnboarding, to: true)
    }

    // MARK: - Export and import (S3)

    /// The whole hoard as the 1.7 JSON file.
    public func exportData(appVersion: String) throws -> Data {
        try Exporter.export(from: store, exportedAt: .now, appVersion: appVersion)
    }

    /// Merges an export file (1.7) and re-reads the settings, which the file may have changed. Publishes
    /// `importSummary` on success, else `failure = .importing`; returns the summary.
    @discardableResult
    public func importWords(_ data: Data) -> ImportSummary? {
        do {
            importSummary = try Importer.importAndFill(data, into: store, autofill: autofill)
        } catch let error as ImportError {
            importSummary = nil
            failure = .importing(error.errorDescription)
        } catch {
            logger.error("Could not import the file: \(error.localizedDescription, privacy: .public)")
            importSummary = nil
            failure = .importing(nil)
        }
        load()
        return importSummary
    }

    // MARK: - Helpers

    private func change<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<UserSettings, Value>, to value: Value) {
        do {
            let settings = try store.settings()
            if settings[keyPath: keyPath] != value {
                try store.updateSettings { $0[keyPath: keyPath] = value }
            }
        } catch {
            logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
            failure = .saving
        }
        load()
    }

    private func storedTopics() -> [GrammarTopicID]? {
        do {
            return try store.settings().activeGrammarTopics
        } catch {
            logger.error("Could not read settings: \(error.localizedDescription, privacy: .public)")
            failure = .loading
            return nil
        }
    }

    private func write(_ topics: [GrammarTopicID], replacing stored: [GrammarTopicID]) {
        if topics != stored {
            do {
                try store.updateSettings { $0.activeGrammarTopics = topics }
            } catch {
                logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
                failure = .saving
            }
        }
        load()
    }

    private func knownKeys(in topics: [GrammarTopicID]) -> Set<GrammarTopicID> {
        Set(topics.filter { catalog.topic(for: $0) != nil })
    }

    /// The storage rule in the type comment: the known block in catalog order at the position of the
    /// first known key (the start when there is none), unknown keys around it in their stored order.
    static func ordered(
        stored: [GrammarTopicID],
        active: Set<GrammarTopicID>,
        catalog: GrammarCatalog
    ) -> [GrammarTopicID] {
        let block = catalog.topics.map(\.key).filter(active.contains)
        let isKnown = { (key: GrammarTopicID) in catalog.topic(for: key) != nil }
        let firstKnown = stored.firstIndex(where: isKnown) ?? 0
        let before = stored[..<firstKnown].filter { !isKnown($0) }
        let after = stored[firstKnown...].filter { !isKnown($0) }
        return before + block + after
    }
}
