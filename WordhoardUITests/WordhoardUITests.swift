// XCUITest requires XCTest; this is the one allowed exception to "Swift Testing for new tests".
import XCTest

final class WordhoardUITests: XCTestCase {
    /// Launches with `--ui-testing`, so the app uses an empty in-memory store and leaves nothing behind.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
    }

    @MainActor
    func testAppLaunchesToTheEmptyList() {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["No words yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["wordList.addField"].isHittable)
    }

    @MainActor
    func testAddingAWordShowsItAtTheTopAndAddingItAgainOpensItsCard() {
        let app = launchApp()
        let addField = app.textFields["wordList.addField"]
        let rows = app.staticTexts.matching(identifier: "wordList.rowHeadword")

        XCTAssertTrue(addField.waitForExistence(timeout: 5))
        addField.tap()
        addField.typeText("book\n")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.element(boundBy: 0).label, "book")
        XCTAssertFalse(app.staticTexts["No words yet"].exists)

        // The field keeps focus after a successful add, so the next word is typed without tapping.
        addField.typeText("apple\n")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.element(boundBy: 0).label, "apple")
        XCTAssertEqual(rows.element(boundBy: 1).label, "book")
        XCTAssertTrue(
            isEmpty(addField),
            "the add field should be cleared after adding, was \(String(describing: addField.value))"
        )

        // Same word, different case and a trailing space: the existing card opens instead of a new row (C4).
        addField.typeText("Book \n")
        let cardHeadword = app.staticTexts["wordCard.headword"]
        XCTAssertTrue(cardHeadword.waitForExistence(timeout: 5))
        XCTAssertEqual(cardHeadword.label, "book")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(isEmpty(addField))
    }

    /// An empty `TextField` reports its placeholder as its value, so "empty" is either.
    @MainActor
    private func isEmpty(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return value.isEmpty || value == field.placeholderValue
    }
}
