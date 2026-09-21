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
        field.tap()
        field.typeText("https://fixture.invalid/index.json")
        app.buttons["repositorySettings.add"].tap()
        let install = app.buttons["repositorySettings.install.fixture"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.tap()
        XCTAssertTrue(app.buttons["Uninstall"].waitForExistence(timeout: 5))
    }
}
