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
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let card = app.buttons["libraryCoverCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        attach(app, name: "local-import-banner")
        card.tap()

        let start = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start Reading'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        XCTAssertTrue(app.buttons["Close reader"].waitForExistence(timeout: 10))
        app.buttons["Close reader"].tap()
        app.buttons["libraryCoverCard"].tap()

        let delete = app.buttons["Delete from Device"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Delete from Device"].tap()
        app.navigationBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 10))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
