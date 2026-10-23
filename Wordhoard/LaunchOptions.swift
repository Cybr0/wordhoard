import Foundation
import WordhoardCore

/// Debug-only launch arguments that pick the `CardGenerator` and the picture stubs (issue #39).
///
/// `--ui-testing` → the stub generator (deterministic fixtures, no delay). `--generator stub|unavailable`
/// → the stub without `--ui-testing`, or `UnavailableCardGenerator` (the non-AI device toggle).
/// `--stub-images image|skip|refuse|fail|unavailable`
/// wires the picture stubs with a 2 s delay (plan 4.4), with or without `--ui-testing`. In a release build
/// everything is the default.
struct LaunchOptions: Sendable {
    enum Generator: Sendable {
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
    /// `nil` = the production picture generator and prompt writer.
    var images: ImageStub?

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
            if arguments.contains("--ui-testing") {
                options.generator = .stub
                // Deterministic: the stubs, never the real picture API, in UI tests.
                options.images = .image
            }
            switch UITestingHooks.value(after: "--generator", in: arguments) {
            case "stub":
                options.generator = .stub
            case "unavailable":
                options.generator = .unavailable
            default:
                break
            }
            if arguments.contains("--stub-images") {
                let value = UITestingHooks.value(after: "--stub-images", in: arguments) ?? ""
                options.images = ImageStub(rawValue: value) ?? .image
            }
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
