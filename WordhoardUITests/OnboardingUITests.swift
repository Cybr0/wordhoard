// XCUITest requires XCTest; this is the one allowed exception to "Swift Testing for new tests".
import XCTest

/// The first-launch sheet (plan 5.2, #44). The UI-test store is in memory, so "never again across
/// launches" is the Core test `completingOnboardingPersists`; here: shown, not swipeable, Continue
/// closes it, and the pre-set flag of every other UI test means no sheet.
final class OnboardingUITests: XCTestCase {
    @MainActor
    func testOnboardingShowsOnceAndRemembersTheChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-onboarding"]
        app.launch()

        let sheet = app.descendants(matching: .any)["onboarding.sheet"]
        let continueButton = app.buttons["onboarding.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.exists)

        app.navigationBars.firstMatch.swipeDown(velocity: .fast)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2), "the sheet cannot be swiped away")

        let noTranslation = app.buttons["onboarding.noTranslation"]
        XCTAssertTrue(noTranslation.waitForExistence(timeout: 5))
        noTranslation.tap()
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()

        XCTAssertTrue(continueButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["wordList.addField"].isHittable)

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.textFields["wordList.addField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.continue"].waitForExistence(timeout: 2))
    }
}
