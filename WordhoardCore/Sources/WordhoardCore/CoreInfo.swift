import Foundation

/// Namespace for package-level facts about `WordhoardCore`.
///
/// Models, services and the grammar catalog are added by later plan tasks; this type exists so the
/// app target has something real to import and the package has something real to test. It is not
/// named after the module on purpose: a type called `WordhoardCore` would shadow the module and break
/// `WordhoardCore.SomeType` qualified lookups.
public enum CoreInfo {
    /// Semantic version of the core package.
    public static let version = "0.1.0"

    /// The package's resource bundle (`GrammarCatalog/`, `WordNet/`), for tests and the About screen.
    public static var resourceBundle: Bundle {
        .module
    }

    /// The full Open English WordNet license (CC BY 4.0, `WordNet/OEWN-LICENSE.txt`) for the About screen
    /// (S6, plan 5.3), or `nil` when the file is not in the bundle.
    public static func wordNetLicenseText() -> String? {
        wordNetLicenseText(in: .module)
    }

    /// The same lookup in another bundle, so a test can show the `nil` path.
    public static func wordNetLicenseText(in bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: "OEWN-LICENSE", withExtension: "txt", subdirectory: "WordNet") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The Simple English Wiktionary notice shipped with its bundle (CC BY-SA 4.0, Phase 7), or `nil`
    /// if the build left it out.
    public static func wiktionaryLicenseText() -> String? {
        guard let url = Bundle.module.url(
            forResource: "SIMPLEWIKT-LICENSE", withExtension: "txt", subdirectory: "Wiktionary"
        ) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
