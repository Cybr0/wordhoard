import Foundation

/// Debug-only launch arguments that let the UI tests drive the export and import flows without the two
/// system sheets. Honoured only together with `--ui-testing`; in a release build everything is `nil`.
///
/// `--ui-testing-export-path <path>`: "Export…" writes the file there instead of presenting the share
/// sheet. `--ui-testing-import-path <path>`: "Import…" imports that file instead of opening the picker.
/// Everything else (menu, model, importer, alert, reload) is the production path.
///
/// `--ui-testing-add-word <word>` (repeatable, in order): runs the real `AddWordIntent.perform()` for each
/// value against the shared store before the list loads, the in-process stand-in for Siri that lets the
/// CLAUDE.md "Siri intent → word appears" flow have a UI test (plan 5.1).
///
/// `--seed-word <word>` (repeatable, Debug only, no `--ui-testing` needed): adds each word through the
/// add field's own path on the real on-disk store with the production generator, so content quality can be
/// checked on the owner's iPhone without typing (Phase 7).
struct UITestingHooks: Sendable {
    var exportPath: String?
    var importPath: String?
    var addWords: [String] = []
    var seedWords: [String] = []

    static let none = UITestingHooks()

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> UITestingHooks {
        #if DEBUG
            let seedWords = values(after: "--seed-word", in: arguments)
            guard arguments.contains("--ui-testing") else {
                return UITestingHooks(seedWords: seedWords)
            }
            return UITestingHooks(
                exportPath: value(after: "--ui-testing-export-path", in: arguments),
                importPath: value(after: "--ui-testing-import-path", in: arguments),
                addWords: values(after: "--ui-testing-add-word", in: arguments),
                seedWords: seedWords
            )
        #else
            return .none
        #endif
    }

    #if DEBUG
        /// The argument following `flag`, or `nil`. Shared with `LaunchOptions`.
        static func value(after flag: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        /// The argument after every occurrence of `flag`, in order.
        static func values(after flag: String, in arguments: [String]) -> [String] {
            arguments.indices.compactMap { index in
                arguments[index] == flag && arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            }
        }
    #endif
}
