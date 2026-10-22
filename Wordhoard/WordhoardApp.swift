import SwiftUI
import WordhoardCore

@main
struct WordhoardApp: App {
    @Environment(\.scenePhase) private var scenePhase

    /// The one container, store and set of services for the whole process, shared with the App Intent
    /// (plan 5.1). Views receive what they need through their initializers.
    private let dependencies = AppDependencies.shared

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies, hooks: UITestingHooks.fromLaunchArguments())
                .task {
                    dependencies.resumeAutofill()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            dependencies.imageQueue.isSceneActive = phase == .active
            // Every foreground: a word added while the app was closed (the 5.1 intent) is filled now.
            if phase == .active {
                dependencies.resumeAutofill()
                dependencies.resumePictures()
            }
        }
    }
}
