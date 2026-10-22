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

    init() {
        logger.info("Launching with WordhoardCore \(CoreInfo.version, privacy: .public)")
        let options = LaunchOptions.fromLaunchArguments()
        (container, isStorageUnavailable) = Self.makeContainer(logger: logger)
        store = WordStore(container: container)
        translator = options.makeTranslator()
        autofill = AutofillService(store: store, generator: options.makeGenerator(translator: translator))
        // Warm up the settings record now, before any in-place edit can be pending, so its first-use
        // save never becomes a surprise commit point from inside a card (1.4 ruling on #30).
        do {
            let settings = try store.settings()
            if let tag = options.nativeLanguage, settings.nativeLanguage != tag {
                try store.transaction { _ in settings.nativeLanguage = tag }
            }
        } catch {
            logger.error("Could not load settings: \(error.localizedDescription, privacy: .public)")
        }
        Task.detached {
            await WordNetLookup.shared.warmUp()
        }
    }

    var body: some Scene {
        WindowGroup {
            WordListView(
                store: store,
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
