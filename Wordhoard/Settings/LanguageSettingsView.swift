import SwiftUI
import WordhoardCore

/// Settings → Native language (S1, plan 5.3): "No translation" first, then the 5.2 list (every known
/// language until the Translation framework answers, which takes at most two seconds), a checkmark on the
/// stored value. Writes through the Settings sheet's `SettingsModel`.
struct LanguageSettingsView: View {
    let model: SettingsModel
    @State private var languages = NativeLanguageCatalog.ordered(supported: nil)

    var body: some View {
        List {
            Section {
                LanguageRows(
                    languages: languages,
                    selection: model.nativeLanguage,
                    noTranslationIdentifier: "settings.language.none",
                    identifierPrefix: "settings.language.",
                    select: model.setNativeLanguage
                )
            } footer: {
                Text("Changes apply to new autofill only. Existing cards keep their translations.")
            }
        }
        .navigationTitle("Native language")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            languages = await NativeLanguageCatalog
                .ordered(supported: TranslationLanguageSource().supportedLanguageTags())
        }
    }
}
