import XCTest

final class TitleSourcesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testAddSourceFromStampAppearsInReadFrom() throws {
        let app = launch()
        openAddSheet(app)
        let row = app.descendants(matching: .any)["addSourceRow.title-sources-fixture-c.fixture-c-same"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.staticTexts.matching(NSPredicate(format: "label == %@", "Fixture Title")).firstMatch.tap()
        XCTAssertTrue(app.textFields["addSourceSearchField"].waitForNonExistence(timeout: 10))
        openSourceMenu(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Source C")).firstMatch.exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Source C")).firstMatch.tap()
    }

    func testDifferentMALResultAsksFirst() throws {
        let app = launch()
        openAddSheet(app)
        let row = app.descendants(matching: .any)["addSourceRow.title-sources-fixture-d.fixture-d-different"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if !row.isHittable { app.swipeUp() }
        app.staticTexts["Fixture Title (Novel)"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "MyAnimeList lists this as a different title")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add anyway"].exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch.tap()
        XCTAssertTrue(app.textFields["addSourceSearchField"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["addSourceRow.title-sources-fixture-d.fixture-d-different"].exists)
    }

    func testServingSourcesAreNotSearched() throws {
        let app = launch()
        openAddSheet(app)
        XCTAssertTrue(app.descendants(matching: .any)["addSourceRow.title-sources-fixture-c.fixture-c-same"].waitForExistence(timeout: 10))
        let sourceA = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "addSourceRow.title-sources-fixture-a.")).firstMatch
        let sourceB = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "addSourceRow.title-sources-fixture-b.")).firstMatch
        XCTAssertFalse(sourceA.exists)
        XCTAssertFalse(sourceB.exists)
    }

    func testRemoveAsSameTitleKeepsReadChapter() throws {
        let app = launch()
        chooseSourceA(app)
        XCTAssertTrue(readChapter5(app).waitForExistence(timeout: 10))
        removeSourceB(app, answer: "removeSourceSameTitle")
        XCTAssertTrue(readChapter5(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Source B"].exists)
    }

    func testRemoveAsDifferentTitleDropsReadChapter() throws {
        let app = launch()
        chooseSourceA(app)
        XCTAssertTrue(readChapter5(app).waitForExistence(timeout: 10))
        removeSourceB(app, answer: "removeSourceDifferentTitle")
        let unread = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Chapter 5", "Unread")).firstMatch
        XCTAssertTrue(unread.waitForExistence(timeout: 10))
    }

    func testRemovedSourceStaysRemovedAfterRelaunchAndRefresh() throws {
        let storageID = "TEST_RUNNER_\(UUID().uuidString)"
        let app = launch(storageID: storageID)
        removeSourceB(app, answer: "removeSourceSameTitle")
        app.terminate()

        let relaunched = launch(storageID: storageID, openTitle: false)
        relaunched.buttons["Refresh Library"].tap()
        XCTAssertTrue(relaunched.staticTexts["Library updated"].waitForExistence(timeout: 10))
        relaunched.staticTexts["Fixture Title"].firstMatch.tap()
        XCTAssertTrue(relaunched.buttons["sourcePicker"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(relaunched.staticTexts["Source B"].exists)
    }

    func testRemoveMenuHiddenWithOneCopy() throws {
        let app = launch()
        removeSourceB(app, answer: "removeSourceSameTitle")
        XCTAssertTrue(app.buttons["sourcePicker"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["removeSourceMenu"].exists)
    }

    func testAddSheetAtLargeDynamicType() throws {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openAddSheet(app)
        let row = app.descendants(matching: .any)["addSourceRow.title-sources-fixture-c.fixture-c-same"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "title-sources-add-large-type"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(row.label, "Fixture Title, Source C, Same MyAnimeList entry, 14 chapters")
    }

    private func launch(arguments: [String] = [], storageID: String? = nil,
                        openTitle: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-title-sources"] + arguments
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = storageID ?? "TEST_RUNNER_\(UUID().uuidString)"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Library"].tap()
        guard openTitle else { return app }
        let title = app.staticTexts["Fixture Title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        XCTAssertTrue(app.buttons["sourcePicker"].waitForExistence(timeout: 10))
        return app
    }

    private func openAddSheet(_ app: XCUIApplication) {
        openSourceMenu(app)
        let add = app.buttons["addSourceMenuItem"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.textFields["addSourceSearchField"].waitForExistence(timeout: 10))
    }

    private func openSourceMenu(_ app: XCUIApplication) {
        let stamp = app.buttons["sourcePicker"]
        stamp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func chooseSourceA(_ app: XCUIApplication) {
        openSourceMenu(app)
        let sourceA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Source A")).firstMatch
        XCTAssertTrue(sourceA.waitForExistence(timeout: 5))
        sourceA.tap()
    }

    private func readChapter5(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Chapter 5", "Read")).firstMatch
    }

    private func removeSourceB(_ app: XCUIApplication, answer: String) {
        openSourceMenu(app)
        let removeMenu = app.descendants(matching: .any)["removeSourceMenu"]
        XCTAssertTrue(removeMenu.waitForExistence(timeout: 5))
        removeMenu.tap()
        let removeB = app.descendants(matching: .any)["removeSourceMenuItem.title-sources-fixture-b"]
        XCTAssertTrue(removeB.waitForExistence(timeout: 5))
        removeB.tap()
        let confirmation = app.buttons[answer].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
    }

}
