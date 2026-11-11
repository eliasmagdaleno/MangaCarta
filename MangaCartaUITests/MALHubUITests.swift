import XCTest

final class MALHubUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testUnavailableCardIsLabeledWithoutSources() throws {
        let app = launch()
        print(app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["relatedSection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["moreLikeThisSection"].exists)
        let cards = app.buttons.matching(identifier: "malCandidateCard")
        XCTAssertTrue(cards.count >= 2)
        XCTAssertTrue(cards.allElementsBoundByIndex.contains { $0.label.hasSuffix("not on your Sources") })
        XCTAssertTrue(cards.allElementsBoundByIndex.contains { $0.label.hasSuffix(", on your Sources") })
        attach(app, name: "mal-hub-unavailable-card")
    }

    func testSwitchOffShowsOnlyResolvedCards() throws {
        let app = launch(arguments: ["-uitest-mal-hub-adult-off"])
        XCTAssertTrue(app.descendants(matching: .any)["moreLikeThisSection"].waitForExistence(timeout: 10))
        let cards = app.buttons.matching(identifier: "malCandidateCard")
        XCTAssertEqual(cards.count, 1)
        XCTAssertFalse(cards.allElementsBoundByIndex.contains { $0.label.hasSuffix("not on your Sources") })
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
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Exact match")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Possible match")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Fixture Source C"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Source D"].exists)
        XCTAssertTrue(element(app, label: "Couldn't check").exists)
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "chapters")).count > 0)
        attach(app, name: "mal-hub-chooser")
    }

    func testSingleExactMatchOpensListingDirectly() throws {
        let app = launch()
        let card = app.buttons.matching(identifier: "malCandidateCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Single Exact")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        attach(app, name: "mal-hub-single-exact-open")
    }

    func testConfirmedChoiceIsRememberedOnReopen() throws {
        let app = launch()
        let card = app.buttons.matching(identifier: "malCandidateCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Chooser")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Source A"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Possible match")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        card.tap()
        XCTAssertTrue(app.buttons["Read on…"].waitForExistence(timeout: 10))
        app.buttons["Source"].tap()
        app.buttons["Choose another Source"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Source A"].waitForExistence(timeout: 10))
        attach(app, name: "mal-hub-remembered-choice")
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
        attach(app, name: "mal-hub-not-found")
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

    private func element(_ app: XCUIApplication, label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
