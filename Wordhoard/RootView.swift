import SwiftUI
import WordhoardCore

/// The word list. There is no onboarding: its only question was the translation language, and cards
/// carry no translation (owner's decision, Phase 7).
struct RootView: View {
    let dependencies: AppDependencies
    let hooks: UITestingHooks

    var body: some View {
        WordListView(
            store: dependencies.store,
            imageStore: dependencies.imageStore,
            imageQueue: dependencies.imageQueue,
            autofill: dependencies.autofill,
            isStorageUnavailable: dependencies.isStorageUnavailable,
            hooks: hooks
        )
    }
}
