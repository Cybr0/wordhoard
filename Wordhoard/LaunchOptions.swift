import Foundation
import WordhoardCore

/// Debug-only launch arguments that pick the `CardGenerator` and the native language (issue #39).
///
/// `--ui-testing` → the stub generator (deterministic fixtures, no delay). `--generator stub|unavailable`
/// → the stub without `--ui-testing`, or `UnavailableCardGenerator` (the non-AI device toggle).
/// `--native-language <bcp47>` sets `UserSettings.nativeLanguage` at launch when it differs; the owner's
/// stand-in until the onboarding picker (5.2) exists. In a release build everything is the default.
struct LaunchOptions: Sendable {
    enum Generator: Sendable {
        case production
        case stub
        case unavailable
    }

    var generator: Generator = .production
    var nativeLanguage: String?

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
            if arguments.contains("--ui-testing") {
                options.generator = .stub
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

    /// The generator this launch uses.
    func makeGenerator() -> any CardGenerator {
        switch generator {
        case .production:
            FoundationModelsCardGenerator()
        case .stub:
            StubCardGenerator()
        case .unavailable:
            UnavailableCardGenerator()
        }
    }
}
