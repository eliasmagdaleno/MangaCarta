import XCTest

final class LibraryMigrateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testMigrateKeepPinsTargetAndKeepsBackup() throws {
        let app = launch()
        openReview(app)
        tapDialogButton(app, identifier: "migrateApplyButton")
        app.buttons.matching(identifier: "migrateKeep").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["migrateSummary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["migrateSummary"].label.contains("Migrated 3 titles."))
        app.buttons["Done"].tap()
        openSameEntryDetail(app)
        let stamp = app.buttons["sourcePicker"]
        XCTAssertTrue(stamp.label.contains("pinned"))
        openSourceMenu(app)
        let sourceB = sourceMenuButton(app, source: "Source B")
        let sourceA = sourceMenuButton(app, source: "Source A")
        XCTAssertTrue(sourceB.waitForExistence(timeout: 5))
        XCTAssertTrue(sourceA.waitForExistence(timeout: 5))
        XCTAssertTrue(sourceB.label.localizedCaseInsensitiveContains("checkmark") || sourceB.isSelected)
        sourceB.tap()
    }

    func testMigrateRemoveDropsOldSource() throws {
        let app = launch()
        openReview(app)
        tapDialogButton(app, identifier: "migrateApplyButton")
        app.buttons.matching(identifier: "migrateRemove").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["migrateSummary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["migrateSummary"].label.contains("Migrated 3 titles."))
        app.buttons["Done"].tap()
        openSameEntryDetail(app)
        openSourceMenu(app)
        let sourceA = sourceMenuButton(app, source: "Source A")
        XCTAssertFalse(sourceA.exists)
        let sourceB = sourceMenuButton(app, source: "Source B")
        XCTAssertTrue(sourceB.waitForExistence(timeout: 5))
        sourceB.tap()
        let readChapter = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Chapter 1", "Read")).firstMatch
        XCTAssertTrue(readChapter.waitForExistence(timeout: 10))
    }

    func testNeedsPickRowCanBePicked() throws {
        let app = launch()
        openReview(app)
        XCTAssertTrue(app.staticTexts["migrateSection.needsPick"].waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, slug: "ambiguous-title").exists)
        XCTAssertEqual(app.buttons["migrateApplyButton"].label, "Migrate 3 titles")
        app.buttons["Choose match"].tap()
        let choice = app.buttons["migrateChoice.library-migrate-b.b-ambiguous-one"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertEqual(app.buttons["migrateApplyButton"].label, "Migrate 4 titles")
    }

    func testCancelDuringSearchChangesNothing() throws {
        let app = launch(slow: true)
        openMigrationSheet(app)
        chooseSources(app)
        app.buttons["Find titles on Source B"].tap()
        XCTAssertTrue(app.staticTexts["migrateProgress"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["migrateSection.notSearched"].waitForExistence(timeout: 10))
        let sameRow = row(app, slug: "same-entry-title")
        XCTAssertTrue(sameRow.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        openSameEntryDetail(app)
        XCTAssertFalse(app.buttons["sourcePicker"].label.contains("pinned"))
        openSourceMenu(app)
        XCTAssertTrue(sourceMenuButton(app, source: "Source A").exists)
        XCTAssertFalse(sourceMenuButton(app, source: "Source B").exists)
        // Open and dismiss the Add a Source sheet to close the menu without changing the pin.
        app.buttons["addSourceMenuItem"].tap()
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.staticTexts["Already Title"].tap()
        XCTAssertFalse(app.buttons["sourcePicker"].label.contains("pinned"))
    }

    func testLargeDynamicType() throws {
        let app = launch(largeType: true)
        openReview(app)
        let apply = app.buttons["migrateApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        let firstRow = row(app, slug: "same-entry-title")
        for _ in 0..<4 where !firstRow.exists { app.swipeUp() }
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        if !firstRow.isHittable { app.swipeUp() }
        XCTAssertTrue(apply.isHittable)
        XCTAssertTrue(firstRow.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "migrate-review-AXXXL"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(slow: Bool = false, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-library-migrate"]
        if slow { app.launchArguments.append("-uitest-library-migrate-slow") }
        if largeType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = "MIGRATE_\(UUID().uuidString)"
        app.launch()
        XCTAssertTrue(app.buttons["libraryMoreMenu"].waitForExistence(timeout: 10))
        return app
    }

    private func openMigrationSheet(_ app: XCUIApplication) {
        let more = app.buttons["libraryMoreMenu"]
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let migrate = app.buttons["Migrate Sources…"]
        XCTAssertTrue(migrate.waitForExistence(timeout: 5))
        migrate.tap()
        XCTAssertTrue(app.buttons["migrateFromPicker"].waitForExistence(timeout: 5))
    }

    private func chooseSources(_ app: XCUIApplication) {
        let from = app.buttons["migrateFromPicker"]
        from.tap()
        let sourceA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Source A ·")).firstMatch
        XCTAssertTrue(sourceA.waitForExistence(timeout: 5))
        sourceA.tap()

        let to = app.buttons["migrateToPicker"]
        to.tap()
        let sourceB = app.buttons.matching(NSPredicate(format: "label == %@", "Source B")).firstMatch
        XCTAssertTrue(sourceB.waitForExistence(timeout: 5))
        sourceB.tap()
    }

    private func openReview(_ app: XCUIApplication) {
        openMigrationSheet(app)
        chooseSources(app)
        app.buttons["Find titles on Source B"].tap()
        XCTAssertTrue(app.staticTexts["migrateSection.ready"].waitForExistence(timeout: 10))
    }

    private func tapDialogButton(_ app: XCUIApplication, identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    private func row(_ app: XCUIApplication, slug: String) -> XCUIElement {
        app.staticTexts["migrateRow.library-migrate-a.a-\(slug)"]
    }

    private func openSameEntryDetail(_ app: XCUIApplication) {
        let close = app.buttons["Done"]
        if close.exists { close.tap() }
        let card = app.staticTexts["Same Entry Title"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.buttons["sourcePicker"].waitForExistence(timeout: 10))
    }

    private func openSourceMenu(_ app: XCUIApplication) {
        app.buttons["sourcePicker"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func sourceMenuButton(_ app: XCUIApplication, source: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", source)).firstMatch
    }

}
