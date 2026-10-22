// XCUITest requires XCTest; this is the one allowed exception to "Swift Testing for new tests".
import XCTest

final class WordhoardUITests: XCTestCase {
    /// Launches with `--ui-testing`, so the app uses an empty in-memory store and leaves nothing behind.
    @MainActor
    private func launchApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
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

        // 6.2 (#32): with the keyboard up, a drag down dismisses it and the search field can be reached.
        app.swipeDown()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields.firstMatch.isHittable)
        addField.tap()

        // Same word, different case and a trailing space: the existing card opens instead of a new row (C4).
        addField.typeText("Book \n")
        let cardHeadword = app.textFields["wordCard.headword"]
        XCTAssertTrue(cardHeadword.waitForExistence(timeout: 5))
        XCTAssertEqual(cardHeadword.value as? String, "book")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(isEmpty(addField))
    }

    /// CLAUDE.md's third reserved flow: export → relaunch (empty in-memory store) → import, from
    /// Settings → Data (plan 5.3). The debug launch arguments replace only the two system sheets; the
    /// rows, model, importer, alert and reload are the production path.
    @MainActor
    func testExportThenImportRestoresTheWordList() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "Wordhoard-UITest-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL)
        }

        var app = launchApp(arguments: ["--ui-testing-export-path", fileURL.path()])
        let addField = app.textFields["wordList.addField"]
        XCTAssertTrue(addField.waitForExistence(timeout: 5))
        addField.tap()
        addField.typeText("book\n")
        addField.typeText("apple\n")
        let rows = app.staticTexts.matching(identifier: "wordList.rowHeadword")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))

        app.buttons["wordList.settings"].tap()
        let exportButton = app.buttons["settings.export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 5))
        exportButton.tap()

        let exported = NSPredicate { _, _ in FileManager.default.fileExists(atPath: fileURL.path()) }
        wait(for: [XCTNSPredicateExpectation(predicate: exported, object: nil)], timeout: 5)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        XCTAssertEqual((json?["words"] as? [Any])?.count, 2)

        app.terminate()
        app = launchApp(arguments: ["--ui-testing-import-path", fileURL.path()])
        XCTAssertTrue(app.staticTexts["No words yet"].waitForExistence(timeout: 5))

        app.buttons["wordList.settings"].tap()
        let importButton = app.buttons["settings.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        let alert = app.alerts["Import finished"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["Added 2, updated 0, skipped 0."].exists)
        alert.buttons["OK"].tap()
        app.buttons["settings.done"].tap()

        let restored = app.staticTexts.matching(identifier: "wordList.rowHeadword")
        XCTAssertTrue(restored.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.element(boundBy: 0).label, "apple")
        XCTAssertEqual(restored.element(boundBy: 1).label, "book")
        XCTAssertFalse(app.staticTexts["No words yet"].exists)
    }

    /// Plan 2.10: a translation that is the translated definition carries a caption; a card with no
    /// translation because the native language's pack is missing says so in one line (A9).
    @MainActor
    func testFallbackTranslationIsCaptioned() {
        var app = launchApp()
        openNewCard("look up", in: app)
        XCTAssertTrue(app.staticTexts["wordCard.sense.0.translationNote"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["wordCard.sense.0.translationNote"].label, "Translated from the definition")
        XCTAssertFalse(app.staticTexts["wordCard.translationNote"].exists, "the stub's packs are installed")

        app.terminate()
        app = launchApp(arguments: ["--native-language", "ru", "--translator", "unavailable"])
        openNewCard("zebra", in: app)
        let note = app.staticTexts["wordCard.translationNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.hasPrefix("Translations need the "), note.label)
        XCTAssertTrue(note.label.hasSuffix(" pack. Download it in Settings › Translate."), note.label)
        XCTAssertFalse(app.staticTexts["wordCard.sense.0.translationNote"].exists)
    }

    /// Adds `headword` from the list and opens its card.
    @MainActor
    private func openNewCard(_ headword: String, in app: XCUIApplication) {
        let addField = app.textFields["wordList.addField"]
        XCTAssertTrue(addField.waitForExistence(timeout: 5))
        addField.tap()
        addField.typeText("\(headword)\n")
        let row = app.staticTexts.matching(identifier: "wordList.rowHeadword").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.textFields["wordCard.headword"].waitForExistence(timeout: 5))
    }

    /// An empty `TextField` reports its placeholder as its value, so "empty" is either.
    @MainActor
    private func isEmpty(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return value.isEmpty || value == field.placeholderValue
    }
}
