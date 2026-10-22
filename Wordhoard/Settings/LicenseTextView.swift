import SwiftUI

/// A bundled license file in full, scrollable and selectable (S6).
struct LicenseTextView: View {
    let title: Text
    let text: String?

    var body: some View {
        ScrollView {
            if let text {
                Text(verbatim: text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
