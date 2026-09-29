import XCTest

final class RepositorySettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testInvalidRepositoryURLIsExplainedWithoutNetworkAccess() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-repository-settings"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let add = app.buttons["repositorySettings.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.staticTexts["Enter a valid HTTPS repository URL."].waitForExistence(timeout: 3))
    }

    func testRepositoryCanBeAddedAndItsSourceInstalledWithFixtureTransport() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-repository-settings"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let field = app.textFields["repositorySettings.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["Show adult content"].exists)
        field.tap()
        field.typeText("https://fixture.invalid/index.json")
        app.buttons["repositorySettings.add"].tap()
        // Add's result renders below the field; a keyboard left up would hide it. On CI one
        // accessibility query takes ~2s, so a 3s wait saw the keyboard mid-dismissal and failed.
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        let install = app.buttons["repositorySettings.install.fixture"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.tap()
        let ageCopy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "18 or over")).firstMatch
        XCTAssertTrue(ageCopy.waitForExistence(timeout: 5))
        XCTAssertTrue(ageCopy.label.contains("Fixture Source"))
        XCTAssertTrue(ageCopy.label.contains("Fixture Repository"))
        XCTAssertFalse(ageCopy.label.localizedCaseInsensitiveContains("moderated"))
        app.buttons["repositorySettings.confirmAge"].tap()
        XCTAssertTrue(app.buttons["Uninstall"].waitForExistence(timeout: 5))
        let adultToggle = app.switches["Show adult content"]
        XCTAssertTrue(adultToggle.waitForExistence(timeout: 5))
        // Depending on the device, the navigation bar or the keyboard left up by the URL field
        // covers the toggle after the scroll to Uninstall, and `isHittable` still reports true
        // under either, so bring it into the uncovered band by its frame instead.
        let top = app.navigationBars.firstMatch.frame.maxY
        func bottom() -> CGFloat {
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists ? keyboard.frame.minY : app.tabBars.firstMatch.frame.minY
        }
        for _ in 0..<5 {
            if adultToggle.frame.minY < top {
                app.swipeDown(velocity: .slow)
            } else if adultToggle.frame.maxY > bottom() {
                app.swipeUp(velocity: .slow)
            } else {
                break
            }
        }
        let adultSwitch = adultToggle.switches.firstMatch
        XCTAssertTrue(adultSwitch.waitForExistence(timeout: 2))
        adultSwitch.tap()
        let enabled = NSPredicate(format: "value == %@", "1")
        expectation(for: enabled, evaluatedWith: adultSwitch)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(adultSwitch.value as? String, "1")
        adultSwitch.tap()
        XCTAssertTrue(adultToggle.waitForNonExistence(timeout: 5))
    }

    func testDecliningAgeGateLeavesSourceUninstalled() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-repository-settings"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let field = app.textFields["repositorySettings.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://fixture.invalid/index.json")
        app.buttons["repositorySettings.add"].tap()
        app.buttons["repositorySettings.install.fixture"].tap()
        XCTAssertTrue(app.buttons["repositorySettings.confirmAge"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["The install was cancelled. Nothing was added."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["repositorySettings.install.fixture"].exists)
        XCTAssertFalse(app.buttons["Uninstall"].exists)
    }

    /// The ADR-0003 Amendment 10 disclosure: a Source that declares image-load reports is
    /// installed only past a sheet naming what is sent, and Cancel installs nothing.
    func testImageLoadReportsSheetGatesInstall() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-repository-settings", "-uitest-repository-reports"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let field = app.textFields["repositorySettings.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://fixture.invalid/index.json")
        app.buttons["repositorySettings.add"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        let install = app.buttons["repositorySettings.install.reporting"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))

        install.tap()
        XCTAssertTrue(app.staticTexts["Image-load reports"].waitForExistence(timeout: 5))
        let copy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                                                        "page-loading statistics")).firstMatch
        XCTAssertTrue(copy.label.hasPrefix("Reporting Source may have MangaCarta send"))
        XCTAssertTrue(copy.label.contains("No cookies or identifiers are sent."))
        XCTAssertFalse(copy.label.contains("18 or over"), "a general-content Source asks no age")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Image-load reports sheet"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["The Source was not installed or updated."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Uninstall"].exists)

        install.tap()
        let proceed = app.buttons["repositorySettings.continueInstall"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        XCTAssertEqual(proceed.label, "Install")
        proceed.tap()
        XCTAssertTrue(app.buttons["Uninstall"].waitForExistence(timeout: 5))
    }

    func testAddedRepositoryCanBeRemoved() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-repository-settings"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let field = app.textFields["repositorySettings.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://fixture.invalid/index.json")
        app.buttons["repositorySettings.add"].tap()
        let repositoryName = app.staticTexts["Fixture Repository"].firstMatch
        XCTAssertTrue(repositoryName.waitForExistence(timeout: 5))
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(repositoryName.waitForNonExistence(timeout: 5))
    }
}
