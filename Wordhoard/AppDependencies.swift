import Foundation
import OSLog
import SwiftData
import WordhoardCore

/// Everything the app shares, built once per process (plan 5.1, #6): the container, the store, the
/// picture directory and queue, the autofill service and the translator. The scene and the App Intent
/// read the same instance. An intent declared in the app target runs inside the app process (launched in
/// the background when needed), so sharing is a matter of reaching this object; there is no app group
/// and no second container.
///
/// **Isolation: `@MainActor`**, like the `WordStore` it owns. Views still receive what they need through
/// their initializers and never touch SwiftData, so `WordStore.init` stays the only code that configures
/// the main context.
@MainActor
final class AppDependencies {
    static let shared = AppDependencies()

    let container: ModelContainer
    let store: WordStore
    /// `true` when the on-disk store could not be opened and `container` is an in-memory fallback.
    let isStorageUnavailable: Bool
    /// Word pictures as files (plan 4.1); a fresh temporary directory under `--ui-testing`.
    let imageStore: ImageStore
    /// Background pictures (plan 4.4); suspended until the launch orphan scan has finished, and inactive
    /// until `WordhoardApp` reports an active scene, so a Siri background launch runs no job.
    let imageQueue: ImageGenerationQueue
    let autofill: AutofillService
    /// The card asks it whether the native language's pack is installed (plan 2.10).
    let translator: any Translator

    private let logger = Logger(subsystem: "Wordhoard", category: "app")

    private init() {
        logger.info("Launching with WordhoardCore \(CoreInfo.version, privacy: .public)")
        let options = LaunchOptions.fromLaunchArguments()
        (container, isStorageUnavailable) = Self.makeContainer(logger: logger)
        store = WordStore(container: container)
        imageStore = Self.makeImageStore(logger: logger)
        translator = options.makeTranslator()
        autofill = AutofillService(store: store, generator: options.makeGenerator(translator: translator))
        imageQueue = ImageGenerationQueue(
            store: store,
            imageStore: imageStore,
            generator: options.makeImageGenerator(),
            promptWriter: options.makeImagePromptWriter()
        )
        connectPicturesToAutofill()
        warmUpSettings(options)
        Task.detached {
            await WordNetLookup.shared.warmUp()
        }
        removeOrphanedImages()
    }

    // MARK: - Foreground

    /// Resets interrupted fills and queues every pending word. Idempotent, so launch and foreground
    /// can both call it.
    func resumeAutofill() {
        do {
            try autofill.resumeAfterLaunch()
        } catch {
            logger.error("Could not resume autofill: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Queues every word whose picture is still pending (a kill, or a job put back in the background).
    func resumePictures() {
        do {
            try imageQueue.resumePending()
        } catch {
            logger.error("Could not resume pictures: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Launch

    /// Warms up the settings record now, before any in-place edit can be pending, so its first-use save
    /// never becomes a surprise commit point from inside a card (1.4 ruling on #30).
    private func warmUpSettings(_ options: LaunchOptions) {
        do {
            _ = try store.settings()
        } catch {
            logger.error("Could not load settings: \(error.localizedDescription, privacy: .public)")
        }
        // Debug presets go through the one settings write path; unchanged values save nothing.
        let settings = SettingsModel(store: store)
        if let tag = options.nativeLanguageTag {
            settings.setNativeLanguage(tag)
        }
        if options.skipsOnboarding {
            settings.markOnboardingCompleted()
        }
    }

    /// A picture waits for its word's first card, so the prompt writer gets a definition (plan 4.4):
    /// jobs for a word still being filled are put off and resumed when the fill settles.
    private func connectPicturesToAutofill() {
        imageQueue.waitsFor = { $0.autofillState == .pending || $0.autofillState == .filling }
        autofill.onFirstCardSettled = { [weak self] _ in
            self?.resumePictures()
        }
    }

    /// The once-per-launch orphan scan (plan 4.1): the reference set is read on the main actor, the files
    /// are scanned off it, and only then does the picture queue start (4.4). Failures are logged, never
    /// shown; the queue starts either way. Never against the in-memory fallback store: its empty
    /// reference set would delete every picture on disk (`orphanScanKeepList()` refuses it as well).
    private func removeOrphanedImages() {
        imageQueue.isSuspended = true
        let referenced: Set<String>?
        do {
            referenced = isStorageUnavailable ? nil : try store.orphanScanKeepList()
        } catch {
            logger.error("Could not read picture names: \(error.localizedDescription, privacy: .public)")
            referenced = nil
        }
        let imageStore = imageStore
        Task {
            if let referenced {
                await Task.detached(priority: .utility) {
                    do {
                        try imageStore.removeOrphans(keeping: referenced)
                    } catch {
                        Logger(subsystem: "Wordhoard", category: "images")
                            .error("Orphan scan failed: \(error.localizedDescription, privacy: .public)")
                    }
                }.value
            }
            imageQueue.isSuspended = false
            resumePictures()
        }
    }

    /// Opens the on-disk store, or an in-memory one under `--ui-testing` so every UI-test launch starts
    /// empty. When the on-disk store cannot be opened the app still launches on an in-memory container
    /// and tells the user nothing will be kept; a crash loop would be a dead end they could not leave.
    private static func makeContainer(logger: Logger) -> (ModelContainer, isStorageUnavailable: Bool) {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                return (makeInMemoryContainer(), false)
            }
        #endif
        do {
            return try (WordhoardContainer.makeOnDisk(), false)
        } catch {
            logger.fault("Could not open the store, using memory: \(error.localizedDescription, privacy: .public)")
            return (makeInMemoryContainer(), true)
        }
    }

    /// An in-memory container cannot fail at runtime; if it does, the schema itself is broken and the
    /// build is defective, so stop with a message naming the failure rather than run without a store.
    private static func makeInMemoryContainer() -> ModelContainer {
        do {
            return try WordhoardContainer.makeInMemory()
        } catch {
            fatalError("Could not create an in-memory store: \(error)")
        }
    }

    /// An empty in-memory store for SwiftUI previews; `nil` if the schema cannot be opened.
    static func previewStore() -> WordStore? {
        (try? WordhoardContainer.makeInMemory()).map(WordStore.init(container:))
    }

    /// `Application Support/Images/`, or a fresh temporary directory under `--ui-testing` so UI tests leave
    /// nothing behind. If the directory cannot be created, the temporary one is used and pictures last
    /// until the system clears it; the app still launches.
    private static func makeImageStore(logger: Logger) -> ImageStore {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                return ImageStore(directory: URL.temporaryDirectory.appending(path: "Images-\(UUID().uuidString)"))
            }
        #endif
        do {
            return try ImageStore(directory: ImageStore.defaultDirectory())
        } catch {
            logger.error("Could not create the image directory: \(error.localizedDescription, privacy: .public)")
            return ImageStore(directory: URL.temporaryDirectory.appending(path: "Images"))
        }
    }
}
