import AppIntents

/// The App Shortcut for `AddWordIntent` (plan 5.1): exactly these two phrases, registered by the app
/// target on first launch; no Info.plist entry, no entitlement.
struct WordhoardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddWordIntent(),
            phrases: [
                "Add a word to \(.applicationName)",
                "Save a word in \(.applicationName)",
            ],
            shortTitle: "Add a word",
            systemImageName: "plus.circle"
        )
    }
}
