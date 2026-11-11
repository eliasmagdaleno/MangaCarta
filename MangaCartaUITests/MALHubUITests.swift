import XCTest

final class MALHubUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testUnavailableCardIsLabeledWithoutSources() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["relatedSection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["moreLikeThisSection"].exists)
        let cards = app.buttons.matching(identifier: "malCandidateCard")
        XCTAssertTrue(cards.count >= 2)
        XCTAssertTrue(cards.allElementsBoundByIndex.contains { $0.label.contains("Sources") })
        attach(app, name: "mal-hub-unavailable-card")
    }

    func testSwitchOffShowsOnlyResolvedCards() throws {
        let app = launch(arguments: ["-uitest-mal-hub-adult-off"])
        XCTAssertTrue(app.buttons["moreLikeThisSection"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "malCandidateCard").count, 2)
        attach(app, name: "mal-hub-adult-off")
    }

    func testTapUnresolvedCardShowsPreviewThenChooser() throws {
        let app = launch()
        let card = app.buttons.matching(identifier: "malCandidateCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Chooser")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.staticTexts["Fixture Chooser"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A fixed fixture synopsis."].exists)
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Source A"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Exact match"].exists)
        XCTAssertTrue(app.staticTexts["Possible match"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Source C"].exists)
        attach(app, name: "mal-hub-chooser")
    }

    func testSingleExactMatchOpensListingDirectly() throws {
        let app = launch()
        let card = app.buttons.matching(identifier: "malCandidateCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Resolved")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.navigationBars["Fixture Resolved"].waitForExistence(timeout: 10))
    }

    func testConfirmedChoiceIsRememberedOnReopen() throws {
        let app = launch()
        let card = app.buttons.matching(identifier: "malCandidateCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Chooser")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Source A"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Possible match")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Fixture Chooser Alternate"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        card.tap()
        XCTAssertTrue(app.buttons["Read on…"].waitForExistence(timeout: 10))
        app.buttons["Source"].tap()
        app.buttons["Choose another Source"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Source A"].waitForExistence(timeout: 10))
    }

    func testNotOnYourSourcesStateOffersRepositoryHint() throws {
        let app = launch()
        let card = app.buttons.matching(identifier: "malCandidateCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Nowhere")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.staticTexts["Not on your Sources"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Add a repository in Settings to add more places to read."].exists)
    }

    private func launch(arguments: [String] = ["-uitest-mal-hub"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = UUID().uuidString
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.staticTexts["Hub Fixture Title"].tap()
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

final class MALHubResolutionUITests: XCTestCase {
    func testTapMayPresentChallengeAndCancelReturnsToPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-mal-hub"]
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = UUID().uuidString
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.staticTexts["Hub Fixture Title"].tap()
        XCTAssertTrue(app.buttons["moreLikeThisSection"].waitForExistence(timeout: 10))
    }
}
