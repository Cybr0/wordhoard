import OSLog
import SwiftUI
import WordhoardCore

/// The word list with the first-launch onboarding sheet over it (S1, plan 5.2): shown while
/// `UserSettings.hasCompletedOnboarding` is `false`, once per install.
struct RootView: View {
    let dependencies: AppDependencies
    let hooks: UITestingHooks
    @State private var isOnboardingPresented: Bool

    init(dependencies: AppDependencies, hooks: UITestingHooks) {
        self.dependencies = dependencies
        self.hooks = hooks
        let isOnboarded: Bool
        do {
            isOnboarded = try dependencies.store.settings().hasCompletedOnboarding
        } catch {
            // Without a readable record the choice could not be saved either; never block the list.
            Logger(subsystem: "Wordhoard", category: "settings")
                .error("Could not read the onboarding flag: \(error.localizedDescription, privacy: .public)")
            isOnboarded = true
        }
        _isOnboardingPresented = State(initialValue: !isOnboarded)
    }

    var body: some View {
        WordListView(
            store: dependencies.store,
            imageStore: dependencies.imageStore,
            imageQueue: dependencies.imageQueue,
            autofill: dependencies.autofill,
            translator: dependencies.translator,
            isStorageUnavailable: dependencies.isStorageUnavailable,
            hooks: hooks
        )
        .sheet(isPresented: $isOnboardingPresented) {
            OnboardingView(store: dependencies.store, languages: TranslationLanguageSource()) {
                isOnboardingPresented = false
            }
        }
    }
}
