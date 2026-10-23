import SwiftUI
import WordhoardCore

/// About (S6, plans 5.3 and 6.3; Phase 7): the version, the Simple English Wiktionary credit (CC BY-SA
/// 4.0) with its notice, the Open English WordNet credit (always) with its full
/// license text when the file is in the Core bundle, and the app's own license with its full text (the
/// repository's `LICENSE`, bundled by `project.yml`) and a link to the source. Credit and license line
/// come first so they are visible without scrolling.
struct AboutView: View {
    private static let repository = URL(string: "https://github.com/Cybr0/wordhoard")
    private let hasWordNetLicense = CoreInfo.wordNetLicenseText() != nil

    var body: some View {
        List {
            Section {
                Text("Wordhoard \(Bundle.main.wordhoardVersion)")
                    .accessibilityIdentifier("about.version")
            }
            Section("Data sources") {
                Text("Simple English Wiktionary — CC BY-SA 4.0, by its contributors; extract by kaikki.org")
                    .accessibilityIdentifier("about.wiktionaryCredit")
                if CoreInfo.wiktionaryLicenseText() != nil {
                    NavigationLink(value: SettingsRoute.wiktionaryLicense) {
                        Text("Simple English Wiktionary license")
                    }
                    .accessibilityIdentifier("about.wiktionaryLicense")
                }
                Text("Open English WordNet 2024 — CC BY 4.0, derived from Princeton WordNet")
                    .accessibilityIdentifier("about.wordNetCredit")
                if hasWordNetLicense {
                    NavigationLink(value: SettingsRoute.wordNetLicense) {
                        Text("Open English WordNet license")
                    }
                    .accessibilityIdentifier("about.wordNetLicense")
                } else {
                    // 6.2: a build defect, never a crash; the credit above still shows.
                    Text("The license text couldn't be loaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("about.wordNetLicenseMissing")
                }
            }
            Section("License") {
                Text("Wordhoard is open source under the Apache License 2.0.")
                    .accessibilityIdentifier("about.appLicense")
                if Self.appLicenseText() != nil {
                    NavigationLink(value: SettingsRoute.appLicense) {
                        Text("Apache License 2.0")
                    }
                    .accessibilityIdentifier("about.appLicenseText")
                }
                if let repository = Self.repository {
                    Link("Source code and license", destination: repository)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The repository's `LICENSE` from the app bundle, or `nil` if the build left it out.
    static func appLicenseText() -> String? {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
