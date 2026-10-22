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
/// stand-in until the onboarding picker (5.2) exists. `--stub-images image|skip|refuse|fail|unavailable`
/// wires the picture stubs with a 2 s delay (plan 4.4), with or without `--ui-testing`. In a release build
/// everything is the default.
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

    /// `--stub-images`: both picture stubs with a 2 s delay, so every slot state shows on the simulator.
    enum ImageStub: String, Sendable {
        case image
        case skip
        case refuse
        case fail
        case unavailable
    }

    var generator: Generator = .production
    var translator: TranslatorChoice = .production
    var nativeLanguage: String?
    /// `nil` = the production picture generator and prompt writer.
    var images: ImageStub?

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
            if arguments.contains("--ui-testing") {
                options.generator = .stub
                options.translator = .stub
                // Deterministic and instant: no real picture API in UI tests unless `--stub-images` asks.
                options.images = .unavailable
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
            if arguments.contains("--stub-images") {
                let value = UITestingHooks.value(after: "--stub-images", in: arguments) ?? ""
                options.images = ImageStub(rawValue: value) ?? .image
            }
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

    // MARK: - Pictures (plan 4.4)

    private static let stubDelay = Duration.seconds(2)

    /// The picture generator this launch uses.
    func makeImageGenerator() -> any ImageGenerator {
        switch images {
        case nil:
            ProductionImageServices.generator()
        case .image, .skip:
            StubImageGenerator(delay: Self.stubDelay)
        case .refuse:
            StubImageGenerator(outcome: .refused, delay: Self.stubDelay)
        case .fail:
            StubImageGenerator(outcome: .failed, delay: Self.stubDelay)
        case .unavailable:
            StubImageGenerator(availability: .unavailable)
        }
    }

    /// The picture prompt writer this launch uses.
    func makeImagePromptWriter() -> any ImagePromptWriter {
        switch images {
        case nil:
            ProductionImageServices.promptWriter()
        case .image, .refuse, .fail:
            StubImagePromptWriter(delay: Self.stubDelay) { headword in
                .success("A simple flat illustration of \(headword).")
            }
        case .skip:
            StubImagePromptWriter(result: .success(nil), delay: Self.stubDelay)
        case .unavailable:
            StubImagePromptWriter(availability: .unavailable)
        }
    }
}
