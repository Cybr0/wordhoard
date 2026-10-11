import OSLog
import SwiftUI
import WordhoardCore

@main
struct WordhoardApp: App {
    private let logger = Logger(subsystem: "Wordhoard", category: "app")

    init() {
        logger.info("Launching with WordhoardCore \(CoreInfo.version, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            WordListView()
        }
    }
}
