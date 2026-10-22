// XCUITest requires XCTest; this is the one allowed exception to "Swift Testing for new tests".
import XCTest

/// CLAUDE.md's reserved flow "Siri intent → word appears" (plan 5.1, #6). XCUITest cannot talk to Siri,
/// so `--ui-testing-add-word` runs the real `AddWordIntent.perform()` in-process against the shared store.
final class IntentUITests: XCTestCase {
    @MainActor
    private func launch(addingWords words: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + words.flatMap { ["--ui-testing-add-word", $0] }
        app.launch()
        return app
    }

    @MainActor
    func testAddWordIntentAddsTheWordToTheList() {
        let app = launch(addingWords: ["book", "Book ", "apple"])
        let rows = app.staticTexts.matching(identifier: "wordList.rowHeadword")

        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.element(boundBy: 0).label, "apple")
        XCTAssertEqual(rows.element(boundBy: 1).label, "book")
        XCTAssertFalse(app.staticTexts["No words yet"].exists)
    }

    @MainActor
    func testABlankWordFromTheIntentSavesNothing() {
        let app = launch(addingWords: ["   ", "apple"])
        let rows = app.staticTexts.matching(identifier: "wordList.rowHeadword")

        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.firstMatch.label, "apple")
    }
}
