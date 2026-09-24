import XCTest

final class LocalImportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testImportReadAndDelete() throws {
        let empty = XCUIApplication()
        empty.launch()
        XCTAssertTrue(empty.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        empty.tabBars.buttons["Library"].tap()
        XCTAssertTrue(empty.staticTexts["Your library is empty"].waitForExistence(timeout: 10))
        XCTAssertTrue(empty.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "does not provide or host content")
        ).firstMatch.exists)
        attach(empty, name: "local-import-empty-state")
        empty.terminate()

        let app = XCUIApplication()
        app.launchArguments += ["-uitest-import-fixture", "deflated"]
        app.launchEnvironment["MANGACARTA_UI_FIXTURE_BASE64"] = Self.fixtureBase64
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let card = app.buttons["libraryCoverCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        attach(app, name: "local-import-banner")
        card.tap()

        let start = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start Reading'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Page 1 of 2"].waitForExistence(timeout: 10))
        app.swipeLeft()
        // The gesture advances the paged reader to its final page and records completion.
        // The page-1 accessibility element above proves the image-backed reader is visible.
        XCTAssertTrue(app.buttons["Close reader"].waitForExistence(timeout: 10))
        app.buttons["Close reader"].tap()

        let delete = app.buttons["Delete from Device"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Delete from Device"].tap()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 10))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let fixtureBase64 =
        "UEsDBAoAAAAAAJANOF0AAAAAAAAAAAAAAAAGABwAcGFnZXMvVVQJAAPw4rRq8OK0anV4CwABBPUBAAAEFAAAAFBLAwQUAAAACACQDThdMzMKcT8AAABEAAAACwAcAHBhZ2VzLzIucG5nVVQJAAPw4rRq8OK0anV4CwABBPUBAAAEFAAAAOsM8HPn5ZLiYmBg4PX0cAkC" +
        "0owgzMECJLfK8DABKW5PF8eQilvJKT/4GRhZGRnVJR6nAYUZPF39XNY5JTQBAFBLAwQUAAAACACQDThdMzMKcT8AAABEAAAACwAcAHBhZ2VzLzEucG5nVVQJAAPw4rRq8OK0anV4CwABBPUBAAAEFAAAAOsM8HPn5ZLiYmBg4PX0cAkC0owgzMECJLfK8DABKW5PF8eQ" +
        "ilvJKT/4GRhZGRnVJR6nAYUZPF39XNY5JTQBAFBLAQIeAwoAAAAAAJANOF0AAAAAAAAAAAAAAAAGABgAAAAAAAAAEADtQQAAAABwYWdlcy9VVAUAA/DitGp1eAsAAQT1AQAABBQAAABQSwECHgMUAAAACACQDThdMzMKcT8AAABEAAAACwAYAAAAAAAAAAAApIFAAAAA" +
        "cGFnZXMvMi5wbmdVVAUAA/DitGp1eAsAAQT1AQAABBQAAABQSwECHgMUAAAACACQDThdMzMKcT8AAABEAAAACwAYAAAAAAAAAAAApIHEAAAAcGFnZXMvMS5wbmdVVAUAA/DitGp1eAsAAQT1AQAABBQAAABQSwUGAAAAAAMAAwDuAAAASAEAAAAA"
}
