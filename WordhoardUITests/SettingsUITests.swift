// XCUITest requires XCTest; this is the one allowed exception to "Swift Testing for new tests".
import XCTest

/// The Settings sheet (plan 5.3, #45): every row, no server-model toggle, the topics screen, changes
/// surviving Done and reopen, and About's exact credit.
final class SettingsUITests: XCTestCase {
    /// The six catalog groups, as section headers (the list may upper-case them).
    private static let groupNames: Set<String> = [
        "Tenses", "TENSES", "Conditionals", "CONDITIONALS", "Voice and reporting", "VOICE AND REPORTING", "Modals",
        "MODALS",
        "Verb patterns", "VERB PATTERNS", "Other", "OTHER",
    ]

    @MainActor
    func testSettingsShowsEveryRowAndTogglesPersistWithinALaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let gear = app.buttons["wordList.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        for identifier in [
            "settings.topics", "settings.export", "settings.import", "settings.about",
        ] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5), identifier)
        }
        let autoImages = app.switches["settings.autoImages"]
        XCTAssertTrue(autoImages.exists)
        XCTAssertFalse(app.staticTexts["Use Apple's server model when online"].exists)
        XCTAssertFalse(app.switches["Use Apple's server model when online"].exists)

        XCTAssertEqual(autoImages.value as? String, "1")
        autoImages.switches.firstMatch.tap()
        XCTAssertEqual(autoImages.value as? String, "0")

        app.buttons["settings.topics"].tap()
        checkTopicsScreenAndSelectArticles(app)

        app.buttons["settings.done"].tap()
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        XCTAssertTrue(autoImages.waitForExistence(timeout: 5))
        XCTAssertEqual(autoImages.value as? String, "0")
        XCTAssertTrue(app.buttons["settings.topics"].label.contains("6 of 32"), app.buttons["settings.topics"].label)

        app.buttons["settings.about"].tap()
        checkAbout(app)
    }

    /// 32 rows under six headers with the defaults checked; switches *Articles* on and goes back.
    @MainActor
    private func checkTopicsScreenAndSelectArticles(_ app: XCUIApplication) {
        let presentPerfect = app.buttons["settings.topics.en.present_perfect"]
        XCTAssertTrue(presentPerfect.waitForExistence(timeout: 5))
        XCTAssertTrue(presentPerfect.isSelected)
        // The list is lazy: collect the rows while scrolling to the end.
        let topicRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.topics.en.'"))
        var seen = Set<String>()
        var headers = Set<String>()
        for _ in 0 ..< 12 {
            seen.formUnion(topicRows.allElementsBoundByIndex.map(\.identifier))
            headers.formUnion(app.staticTexts.allElementsBoundByIndex.map(\.label).filter(Self.groupNames.contains))
            app.swipeUp()
        }
        XCTAssertEqual(seen.count, 32)
        XCTAssertEqual(Set(headers.map { $0.lowercased() }).count, 6, "\(headers)")
        let articles = app.buttons["settings.topics.en.articles"]
        for _ in 0 ..< 12 where !articles.isHittable {
            app.swipeDown()
        }
        XCTAssertFalse(articles.isSelected)
        articles.tap()
        XCTAssertTrue(articles.isSelected)
        app.navigationBars["Topics I'm learning"].buttons.element(boundBy: 0).tap()
    }

    /// The version line, the exact credit, the app license and the WordNet license text.
    @MainActor
    private func checkAbout(_ app: XCUIApplication) {
        let version = app.staticTexts["about.version"]
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertNotNil(version.label.range(of: #"^Wordhoard \d+\.\d+\.\d+ \(\d+\)$"#, options: .regularExpression))
        XCTAssertEqual(
            app.staticTexts["about.wordNetCredit"].label,
            "Open English WordNet 2024 — CC BY 4.0, derived from Princeton WordNet"
        )
        XCTAssertTrue(app.staticTexts["about.appLicense"].exists)
        // OEWN-LICENSE.txt arrived with 2.2, so the license row is shown and opens the full text.
        let license = app.buttons["about.wordNetLicense"]
        XCTAssertTrue(license.exists)
        license.tap()
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH 'Open English WordNet, 2024 edition'"))
            .firstMatch.waitForExistence(timeout: 5))
    }
}
