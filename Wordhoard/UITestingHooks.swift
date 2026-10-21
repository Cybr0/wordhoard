import Foundation

/// Debug-only launch arguments that let the UI tests drive the export and import flows without the two
/// system sheets. Honoured only together with `--ui-testing`; in a release build everything is `nil`.
///
/// `--ui-testing-export-path <path>`: "Export…" writes the file there instead of presenting the share
/// sheet. `--ui-testing-import-path <path>`: "Import…" imports that file instead of opening the picker.
/// Everything else (menu, model, importer, alert, reload) is the production path.
struct UITestingHooks: Sendable {
    var exportPath: String?
    var importPath: String?

    static let none = UITestingHooks()

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> UITestingHooks {
        #if DEBUG
            guard arguments.contains("--ui-testing") else {
                return .none
            }
            return UITestingHooks(
                exportPath: value(after: "--ui-testing-export-path", in: arguments),
                importPath: value(after: "--ui-testing-import-path", in: arguments)
            )
        #else
            return .none
        #endif
    }

    #if DEBUG
        private static func value(after flag: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
    #endif
}
