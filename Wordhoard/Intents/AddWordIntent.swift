import AppIntents
import OSLog
import WordhoardCore

/// "Hey Siri, add a word to Wordhoard" → "Which word?" → the word (C2, plan 5.1, #6). Saves through
/// `WordStore.add` exactly as the add field does and does nothing else: autofill fills the word when the
/// app next becomes active (C5), duplicates are the store's (C4). The word cannot be part of the trigger
/// phrase (App Shortcut parameters must be entities), so the two-step dialog is the design.
struct AddWordIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a word to Wordhoard"
    static let description = IntentDescription("Saves a word to your Wordhoard list.")
    /// Capture is instant: the word is saved in the background and the app stays closed.
    static let openAppWhenRun = false

    @Parameter(title: "Word", requestValueDialog: "Which word?")
    var word: String

    init() {}

    init(word: String) {
        self.word = word
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppDependencies.shared.store
        do {
            switch try store.add(word) {
            case let .created(added):
                return .result(dialog: "Added “\(added.headword)” to your hoard.")
            case let .existing(existing):
                return .result(dialog: "“\(existing.headword)” is already in your hoard.")
            }
        } catch WordStoreError.emptyHeadword {
            throw $word.needsValueError("Which word?")
        } catch {
            Logger(subsystem: "Wordhoard", category: "intent")
                .error("Could not save a word from Siri: \(error.localizedDescription, privacy: .public)")
            throw AddWordIntentError.couldNotSave
        }
    }
}

/// The one failure Siri reads out besides "Which word?".
enum AddWordIntentError: Error, CustomLocalizedStringResourceConvertible {
    case couldNotSave

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .couldNotSave:
            "Couldn't save the word."
        }
    }
}
