import SwiftUI
import WordhoardCore

/// "No translation" first, then the languages, with a checkmark on the selection (S1). Shared by the
/// onboarding sheet (5.2) and Settings → Native language (5.3); `identifierPrefix` keeps their
/// accessibility identifiers apart (`onboarding.…`, `settings.language.…`).
struct LanguageRows: View {
    let languages: [NativeLanguage]
    let selection: String?
    let noTranslationIdentifier: String
    let identifierPrefix: String
    let select: (String?) -> Void

    var body: some View {
        row(Text("No translation"), tag: nil)
            .accessibilityIdentifier(noTranslationIdentifier)
        ForEach(languages) { language in
            row(Text(verbatim: language.displayName), tag: language.tag)
                .accessibilityIdentifier("\(identifierPrefix)\(language.tag)")
        }
    }

    private func row(_ label: Text, tag: String?) -> some View {
        let isSelected = selection == tag
        return Button {
            select(tag)
        } label: {
            HStack {
                label
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
