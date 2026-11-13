import XCTest

final class AnalyticsSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testNoticeDismissesAndToggleReflectsChoice() throws {
        let storageID = "TEST_RUNNER_\(UUID().uuidString)"
        var app = launch(region: "GBR", storageID: storageID)
        let notice = app.otherElements["analyticsNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Help improve recommendations?"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Not now"].exists)
        assertEqualButtonFrames(app.buttons["analyticsNotice.accept"], app.buttons["analyticsNotice.decline"])
        attach("notice-asking", app)

        openSettings(app)
        let undecidedToggle = app.switches["analyticsToggle"]
        XCTAssertTrue(undecidedToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(undecidedToggle.value as? String, "0")
        openWhatIsSent(app)
        XCTAssertFalse(app.descendants(matching: .any)["analyticsEventRow"].exists)
        XCTAssertEqual(app.staticTexts["analyticsInstallID"].value as? String, "None yet")
        attach("privacy-before-consent", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.terminate()
        app = launch(region: "GBR", storageID: storageID)
        XCTAssertTrue(app.otherElements["analyticsNotice"].waitForExistence(timeout: 10))
        app.buttons["analyticsNotice.accept"].tap()
        XCTAssertTrue(app.otherElements["analyticsNotice"].waitForNonExistence(timeout: 5))

        app.terminate()
        app = launch(region: "GBR", storageID: storageID)
        XCTAssertFalse(app.otherElements["analyticsNotice"].exists)
        openWhatIsSent(app)
        XCTAssertTrue(app.descendants(matching: .any)["analyticsEventRow"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["analyticsInstallID"].value as? String, "None yet")
        attach("privacy-after-consent", app)
        app.terminate()
        app = launch(region: "GBR", storageID: storageID)
        openSettings(app)
        let toggle = app.switches["analyticsToggle"]
        scrollToToggle(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        openWhatIsSent(app)
        XCTAssertFalse(app.descendants(matching: .any)["analyticsEventRow"].exists)
        XCTAssertEqual(app.staticTexts["analyticsInstallID"].value as? String, "None yet")
        attach("privacy-after-opt-out", app)
    }

    func testInformingCardOutsideTheConsentRegion() throws {
        let storageID = "TEST_RUNNER_\(UUID().uuidString)"
        let app = launch(region: "USA", storageID: storageID)
        XCTAssertTrue(app.otherElements["analyticsNotice"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Help improve recommendations"].exists)
        XCTAssertFalse(app.staticTexts["Help improve recommendations?"].exists)
        XCTAssertTrue(app.buttons["OK"].exists)
        XCTAssertTrue(app.buttons["Turn off"].exists)
        attach("notice-informing", app)
        app.buttons["analyticsNotice.decline"].tap()
        XCTAssertTrue(app.otherElements["analyticsNotice"].waitForNonExistence(timeout: 5))
        openSettings(app)
        let toggle = app.switches["analyticsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        app.terminate()
        let relaunched = launch(region: "USA", storageID: storageID)
        XCTAssertFalse(relaunched.otherElements["analyticsNotice"].exists)
    }

    func testNoticeIsHiddenForOtherUITestLaunches() throws {
        let hidden = launch(arguments: ["-uitest-zero-sources"], storageID: "TEST_RUNNER_\(UUID().uuidString)")
        XCTAssertTrue(hidden.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(hidden.otherElements["analyticsNotice"].exists)

        let shown = launch(region: "GBR", storageID: "TEST_RUNNER_\(UUID().uuidString)")
        XCTAssertTrue(shown.otherElements["analyticsNotice"].waitForExistence(timeout: 10))
    }

    private func launch(region: String? = nil, arguments: [String] = [], storageID: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        if let region {
            app.launchArguments += ["-uitest-analytics-region", region]
        }
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = storageID
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        return app
    }

    private func openWhatIsSent(_ app: XCUIApplication) {
        openSettings(app)
        XCTAssertTrue(app.switches["analyticsToggle"].waitForExistence(timeout: 10))
        app.buttons["analyticsWhatIsSent"].tap()
        XCTAssertTrue(app.navigationBars["What is sent"].waitForExistence(timeout: 5))
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Home"].tap()
        app.tabBars.buttons["Settings"].tap()
    }

    private func scrollToToggle(_ toggle: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if toggle.exists { return }
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    }

    private func assertEqualButtonFrames(_ first: XCUIElement, _ second: XCUIElement) {
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.height, second.frame.height, accuracy: 1)
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        XCTAssertGreaterThanOrEqual(second.frame.height, 44)
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
