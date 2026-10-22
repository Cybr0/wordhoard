import Foundation
import WordhoardCore

/// Debug-only launch arguments that pick the `CardGenerator`, the `Translator` and the native language
/// (issues #39, #22).
///
/// `--ui-testing` → the stub generator (deterministic fixtures, no delay) and a stub translator with
/// every pack installed. `--generator stub|unavailable` → the stub without `--ui-testing`, or
/// `UnavailableCardGenerator` (the non-AI device toggle). `--translator unavailable` → a stub
/// translator whose packs are not downloaded, so the card's missing-pack note can be seen (plan 2.10).
/// `--native-language <bcp47>` sets `UserSettings.nativeLanguage` at launch when it differs; the owner's
/// stand-in until the onboarding picker (5.2) exists. In a release build everything is the default.
struct LaunchOptions: Sendable {
    enum Generator: Sendable {
        case production
        case stub
        case unavailable
    }

    enum TranslatorChoice: Sendable {
        case production
        case stub
        case unavailable
    }

    var generator: Generator = .production
    var translator: TranslatorChoice = .production
    var nativeLanguage: String?

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
            if arguments.contains("--ui-testing") {
                options.generator = .stub
                options.translator = .stub
            }
            if UITestingHooks.value(after: "--translator", in: arguments) == "unavailable" {
                options.translator = .unavailable
            }
            switch UITestingHooks.value(after: "--generator", in: arguments) {
            case "stub":
                options.generator = .stub
            case "unavailable":
                options.generator = .unavailable
            default:
                break
            }
            options.nativeLanguage = UITestingHooks.value(after: "--native-language", in: arguments)
        #endif
        return options
    }

    /// The translator this launch uses: the generator's and the card's missing-pack check.
    func makeTranslator() -> any Translator {
        switch translator {
        case .production:
            AppleTranslator()
        case .stub:
            StubTranslator()
        case .unavailable:
            StubTranslator(availability: .supported)
        }
    }

    /// The generator this launch uses.
    func makeGenerator(translator: any Translator) -> any CardGenerator {
        switch generator {
        case .production:
            FoundationModelsCardGenerator(translator: translator)
        case .stub:
            StubCardGenerator()
        case .unavailable:
            UnavailableCardGenerator()
        }
    }
}
