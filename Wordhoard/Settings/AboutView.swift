import SwiftUI
import WordhoardCore

/// About (S6, plan 5.3): the version, the Open English WordNet credit (always) with its full license
/// text when the file is in the Core bundle, and the app's own license. Credit and license line come
/// first so they are visible without scrolling.
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
                Text("Open English WordNet 2024 — CC BY 4.0, derived from Princeton WordNet")
                    .accessibilityIdentifier("about.wordNetCredit")
                if hasWordNetLicense {
                    NavigationLink(value: SettingsRoute.wordNetLicense) {
                        Text("Open English WordNet license")
                    }
                    .accessibilityIdentifier("about.wordNetLicense")
                }
            }
            Section("License") {
                Text("Wordhoard is open source under the Apache License 2.0.")
                    .accessibilityIdentifier("about.appLicense")
                if let repository = Self.repository {
                    Link("Source code and license", destination: repository)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
