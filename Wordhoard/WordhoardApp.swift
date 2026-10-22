import OSLog
import SwiftData
import SwiftUI
import WordhoardCore

@main
struct WordhoardApp: App {
    private let logger = Logger(subsystem: "Wordhoard", category: "app")
    @Environment(\.scenePhase) private var scenePhase

    /// The one container, the one store and the one autofill queue for the whole app. Views receive
    /// them through their initializers and never touch SwiftData themselves, so no SwiftUI container
    /// modifier is applied and `WordStore.init` stays the only code that configures the main context.
    private let container: ModelContainer
    private let store: WordStore
    private let autofill: AutofillService
    /// The card asks it whether the native language's pack is installed (plan 2.10).
    private let translator: any Translator
    /// `true` when the on-disk store could not be opened and `container` is an in-memory fallback.
    private let isStorageUnavailable: Bool
    /// Word pictures as files (plan 4.1); a fresh temporary directory under `--ui-testing`.
    private let imageStore: ImageStore
    /// Background pictures (plan 4.4); suspended until the launch orphan scan has finished.
    private let imageQueue: ImageGenerationQueue

    init() {
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
        Self.connect(imageQueue, to: autofill, logger: logger)
        // Warm up the settings record now, before any in-place edit can be pending, so its first-use
        // save never becomes a surprise commit point from inside a card (1.4 ruling on #30).
        do {
            let settings = try store.settings()
            if let tag = options.nativeLanguage, settings.nativeLanguage != tag {
                try store.updateSettings { $0.nativeLanguage = tag }
            }
        } catch {
            logger.error("Could not load settings: \(error.localizedDescription, privacy: .public)")
        }
        Task.detached {
            await WordNetLookup.shared.warmUp()
        }
        Self.removeOrphanedImages(store: store, imageStore: imageStore, queue: imageQueue, logger: logger)
    }

    var body: some Scene {
        WindowGroup {
            WordListView(
                store: store,
                imageStore: imageStore,
                imageQueue: imageQueue,
                autofill: autofill,
                translator: translator,
                isStorageUnavailable: isStorageUnavailable,
                hooks: UITestingHooks.fromLaunchArguments()
            )
            .task(resumeAutofill)
        }
        .onChange(of: scenePhase) { _, phase in
            // Every foreground: a word added while the app was closed (the 5.1 intent) is filled now.
            if phase == .active {
                resumeAutofill()
            }
            imageQueue.isSceneActive = phase == .active
            if phase == .active {
                resumePictures()
            }
        }
    }

    /// Queues every word whose picture is still pending (a kill, or a job put back in the background).
    private func resumePictures() {
        do {
            try imageQueue.resumePending()
        } catch {
            logger.error("Could not resume pictures: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A picture waits for its word's first card, so the prompt writer gets a definition (plan 4.4):
    /// jobs for a word still being filled are put off and resumed when the fill settles.
    private static func connect(_ queue: ImageGenerationQueue, to autofill: AutofillService, logger: Logger) {
        queue.waitsFor = { $0.autofillState == .pending || $0.autofillState == .filling }
        autofill.onFirstCardSettled = { [weak queue] _ in
            do {
                try queue?.resumePending()
            } catch {
                logger.error("Could not resume pictures: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resets interrupted fills and queues every pending word. Idempotent, so launch and foreground
    /// can both call it.
    private func resumeAutofill() {
        do {
            try autofill.resumeAfterLaunch()
        } catch {
            logger.error("Could not resume autofill: \(error.localizedDescription, privacy: .public)")
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

    /// The once-per-launch orphan scan (plan 4.1): the reference set is read on the main actor, the files
    /// are scanned off it, and only then does the picture queue start (4.4). Failures are logged, never
    /// shown; the queue starts either way.
    private static func removeOrphanedImages(
        store: WordStore,
        imageStore: ImageStore,
        queue: ImageGenerationQueue,
        logger: Logger
    ) {
        queue.isSuspended = true
        let referenced: Set<String>?
        do {
            referenced = try store.imageFileNames()
        } catch {
            logger.error("Could not read picture names: \(error.localizedDescription, privacy: .public)")
            referenced = nil
        }
        Task { @MainActor in
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
            queue.isSuspended = false
            do {
                try queue.resumePending()
            } catch {
                logger.error("Could not resume pictures: \(error.localizedDescription, privacy: .public)")
            }
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
}
