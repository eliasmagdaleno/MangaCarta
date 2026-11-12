import XCTest

final class DetailSectionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testDetailOpensOnChaptersWithPreviewAndShowAll() throws {
        let app = launch()
        XCTAssertTrue(picker(app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Chapters"].isSelected)
        XCTAssertTrue(chapter(app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["showAllChaptersButton"].waitForExistence(timeout: 10))
        attach(app, name: "detail-sections-chapters")
    }

    func testSwitchingSegmentsSwapsThePane() throws {
        let app = launch()
        select(app, "Similar")
        XCTAssertTrue(app.staticTexts["More Like This"].waitForExistence(timeout: 10))
        XCTAssertFalse(chapter(app).exists)
        attach(app, name: "detail-sections-similar")

        select(app, "Chapters")
        XCTAssertTrue(chapter(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["More Like This"].exists)
        attach(app, name: "detail-sections-chapters-again")
    }

    func testSelectionSurvivesTheReaderRoundTrip() throws {
        let app = launch()
        select(app, "Chapters")
        chapter(app).tap()
        XCTAssertTrue(app.buttons["Close reader"].waitForExistence(timeout: 10))
        app.buttons["Close reader"].tap()
        XCTAssertTrue(app.buttons["Chapters"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Chapters"].isSelected)

        select(app, "Similar")
        let card = app.buttons.matching(identifier: "malCandidateCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.staticTexts["Fixture Resolved"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Similar"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Similar"].isSelected)
    }

    func testSegmentsExposeExactlyOneSelected() throws {
        let app = launch()
        let segments = [app.buttons["Chapters"], app.buttons["Related"], app.buttons["Similar"]]
        XCTAssertTrue(segments[0].waitForExistence(timeout: 10))
        XCTAssertEqual(segments.filter(\.isSelected).count, 1)
        XCTAssertTrue(segments.allSatisfy { !$0.label.isEmpty })

        select(app, "Related")
        XCTAssertEqual(segments.filter(\.isSelected).count, 1)
        select(app, "Similar")
        XCTAssertEqual(segments.filter(\.isSelected).count, 1)
    }

    func testDetailWithSectionsPassesTheAccessibilityAudit() throws {
        try auditDetail(launch(), name: "detail-sections-default")

        let large = launch(arguments: ["-uitest-mal-hub", "-UIPreferredContentSizeCategoryName",
                                       "UICTContentSizeCategoryAccessibilityXL"])
        let picker = picker(large)
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        XCTAssertFalse(large.segmentedControls["detailSectionPicker"].exists)
        XCTAssertTrue(large.buttons["detailSectionPicker"].exists || picker.exists)
        attach(large, name: "detail-sections-accessibility-xl")
        try audit(large, screen: "detail-sections-accessibility-xl")
    }

    func testNoPickerWithoutDiscoveryContent() throws {
        let app = launch(arguments: ["-uitest-mal-hub-no-rails"])
        XCTAssertTrue(app.staticTexts["No Rails Fixture"].waitForExistence(timeout: 15))
        XCTAssertFalse(picker(app).exists)
        XCTAssertTrue(chapter(app).waitForExistence(timeout: 10))
    }

    func testUnmatchedNoticeEndsTheChaptersPane() throws {
        let app = launch(arguments: ["-uitest-mal-hub-unmatched"])
        XCTAssertTrue(app.staticTexts["Unmatched Fixture"].waitForExistence(timeout: 15))
        XCTAssertFalse(picker(app).exists)
        XCTAssertTrue(app.descendants(matching: .any)["unmatchedTitleNotice"].waitForExistence(timeout: 10))
    }

    private func launch(arguments: [String] = ["-uitest-mal-hub"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = UUID().uuidString
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.staticTexts.matching(NSPredicate(format: "label == %@",
                                              fixtureTitle(for: arguments))).firstMatch.tap()
        XCTAssertTrue(app.staticTexts[fixtureTitle(for: arguments)].waitForExistence(timeout: 15))
        return app
    }

    private func fixtureTitle(for arguments: [String]) -> String {
        if arguments.contains("-uitest-mal-hub-no-rails") { return "No Rails Fixture" }
        if arguments.contains("-uitest-mal-hub-unmatched") { return "Unmatched Fixture" }
        return "Hub Fixture Title"
    }

    private func select(_ app: XCUIApplication, _ title: String) {
        let segment = app.buttons[title]
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        segment.tap()
    }

    private func chapter(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter ")).firstMatch
    }

    private func auditDetail(_ app: XCUIApplication, name: String) throws {
        XCTAssertTrue(picker(app).waitForExistence(timeout: 15))
        attach(app, name: name)
        try audit(app, screen: name)
    }

    private func picker(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["detailSectionPicker"]
    }

    private func audit(_ app: XCUIApplication, screen: String) throws {
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting([.contrast, .textClipped])) { issue in
            let element = issue.element.map { "'\($0.label)' (id '\($0.identifier)')" } ?? "no element"
            XCTFail("[\(screen)] \(issue.compactDescription): \(element)")
            return true
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
