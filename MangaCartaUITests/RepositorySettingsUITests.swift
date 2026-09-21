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
        XCTAssertFalse(app.switches["Show adult sources"].exists)
        field.tap()
        field.typeText("https://fixture.invalid/index.json")
        app.buttons["repositorySettings.add"].tap()
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
        let adultToggle = app.switches["Show adult sources"]
        XCTAssertTrue(adultToggle.waitForExistence(timeout: 5))
        adultToggle.tap()
        adultToggle.tap()
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
