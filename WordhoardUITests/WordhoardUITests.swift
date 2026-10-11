// XCUITest requires XCTest; this is the one allowed exception to "Swift Testing for new tests".
import XCTest

final class WordhoardUITests: XCTestCase {
    @MainActor
    func testAppLaunchesToTheEmptyList() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["No words yet"].waitForExistence(timeout: 5))
    }
}
