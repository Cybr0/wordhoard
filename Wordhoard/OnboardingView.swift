import SwiftUI
import WordhoardCore

/// The one question on first launch (S1, plan 5.2, #44): which language translations are for. Not
/// dismissable; Continue is the only way out and is enabled once the list has loaded, because the
/// preselection is valid by construction. Every write goes through `OnboardingModel.complete()`.
struct OnboardingView: View {
    @State private var model: OnboardingModel
    @State private var isLoaded = false
    private let onFinish: () -> Void

    init(store: WordStore, languages: any SupportedLanguageSource, onFinish: @escaping () -> Void) {
        _model = State(initialValue: OnboardingModel(store: store, languages: languages))
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.paragraph)
                }
                Section {
                    LanguageRows(
                        languages: model.languages,
                        selection: model.selection,
                        noTranslationIdentifier: "onboarding.noTranslation",
                        identifierPrefix: "onboarding.language.",
                        select: { model.selection = $0 }
                    )
                    if !isLoaded {
                        ProgressView {
                            Text("Loading languages…")
                        }
                    }
                } header: {
                    Text("Native language")
                } footer: {
                    if model.isSystemLanguageUnsupported {
                        unsupportedNote
                            .accessibilityIdentifier("onboarding.unsupportedNote")
                    }
                }
                .accessibilityIdentifier("onboarding.languagePicker")
            }
            .navigationTitle("Welcome to Wordhoard")
            .safeAreaInset(edge: .bottom) {
                Button(action: finish) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isLoaded)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("onboarding.continue")
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("onboarding.sheet")
        .alert("Couldn't save your choice", isPresented: $model.failure) {
            Button("OK", role: .cancel) {}
        }
        .task {
            await model.load()
            isLoaded = true
        }
    }

    private static let paragraph: LocalizedStringKey = """
    Wordhoard writes definitions and examples on your iPhone and translates them with Apple's on-device \
    Translation. Choose the language translations should be in. You can change this later in Settings.
    """

    private var unsupportedNote: Text {
        let name = model.systemLanguageName
        return Text("Translation isn't available for \(name) yet. You can type translations yourself.")
    }

    private func finish() {
        if model.complete() {
            onFinish()
        }
    }
}
