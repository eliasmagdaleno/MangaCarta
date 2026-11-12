import XCTest

/// Hermetic: `-uitest-mal-hub` swaps in five fixture Sources and a canned MAL detail
/// (`MALHubUITestFixture`), on throwaway storage. The parent title, MAL id 1000, has one
/// Related title and five recommendations, one per state the hub has to render:
///
/// - **Fixture Resolved** — resolved at render time (exact MAL id on Source A).
/// - **Fixture Chooser** — exact on A and C, a possible match on B, a failed search on D.
/// - **Fixture Single Exact** — unresolved at render, one exact match on tap.
/// - **Fixture Nowhere** — no Source has it.
/// - **Fixture Challenge** — Source E raises the real Cloudflare challenge wait.
final class MALHubUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // Acceptance 13: mixed rails, truthful labels.
    func testUnavailableCardIsLabeledWithoutSources() throws {
        let app = launch()
        selectSection(app, "Related")
        XCTAssertTrue(app.descendants(matching: .any)["relatedSection"].waitForExistence(timeout: 10))
        selectSection(app, "Similar")
        XCTAssertTrue(app.descendants(matching: .any)["moreLikeThisSection"].waitForExistence(timeout: 10))
        XCTAssertEqual(card(app, "Fixture Resolved").label,
                       "Fixture Resolved, recommended by MyAnimeList, on your Sources")
        XCTAssertEqual(card(app, "Fixture Nowhere").label,
                       "Fixture Nowhere, recommended by MyAnimeList, not on your Sources")
        selectSection(app, "Related")
        XCTAssertEqual(card(app, "Fixture Related").label, "Fixture Related, sequel, not on your Sources")
        app.swipeUp()
        attach(app, name: "mal-hub-unavailable-card")
    }

    // Acceptance 11 (option B): switch off shows only the render-time-resolved card.
    func testSwitchOffShowsOnlyResolvedCards() throws {
        let app = launch(arguments: ["-uitest-mal-hub-adult-off"])
        selectSection(app, "Similar")
        XCTAssertTrue(app.descendants(matching: .any)["moreLikeThisSection"].waitForExistence(timeout: 10))
        let cards = app.buttons.matching(identifier: "malCandidateCard")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.firstMatch.label, "Fixture Resolved, recommended by MyAnimeList, on your Sources")
        // Every Related card is unresolved, so the whole section is gone.
        XCTAssertFalse(app.descendants(matching: .any)["relatedSection"].exists)
        attach(app, name: "mal-hub-adult-off")
    }

    // Acceptance 4–6, 8: preview, then a grouped chooser with exact, possible and failed Sources.
    func testTapUnresolvedCardShowsPreviewThenChooser() throws {
        let app = launch()
        openChooser(app, "Fixture Chooser")
        XCTAssertTrue(app.staticTexts["Fixture Source C"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Source D"].exists)
        XCTAssertTrue(choice(app, source: "Fixture Source A", confidence: "exact match").exists)
        XCTAssertTrue(choice(app, source: "Fixture Source C", confidence: "exact match").exists)
        let possible = choice(app, source: "Fixture Source B", confidence: "possible match")
        XCTAssertTrue(possible.exists)
        XCTAssertTrue(possible.label.contains("also known as Fixture Chooser Alternate"), possible.label)
        XCTAssertTrue(element(app, label: "Couldn't check").exists)
        XCTAssertTrue(app.buttons["Try again, Fixture Source D"].exists)
        // A's chapters count 3; C's chapter fetch throws, which is unknown — never "0".
        XCTAssertTrue(choice(app, source: "Fixture Source A", confidence: "3 chapters")
            .waitForExistence(timeout: 10))
        XCTAssertTrue(choice(app, source: "Fixture Source C", confidence: "Chapter count unknown").exists)
        attach(app, name: "mal-hub-chooser")
    }

    // Acceptance 5: one exact match across every Source opens that Listing without a chooser.
    func testSingleExactMatchOpensListingDirectly() throws {
        let app = launch()
        selectSection(app, "Similar")
        let single = card(app, "Fixture Single Exact")
        XCTAssertTrue(single.waitForExistence(timeout: 10))
        // Not already resolved at render time, so the open below is the tap-time search's.
        XCTAssertTrue(single.label.hasSuffix(", not on your Sources"), single.label)
        tapCard(app, "Fixture Single Exact")
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.navigationBars["Fixture Single Exact"].waitForExistence(timeout: 10)
                      || app.staticTexts["Fixture Single Exact"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Preview"].exists)
        XCTAssertFalse(app.staticTexts["Fixture Source A"].exists)
        attach(app, name: "mal-hub-single-exact-open")
    }

    // Acceptance 10: a confirmed choice reopens directly; "Choose another Source" forgets it.
    func testConfirmedChoiceIsRememberedOnReopen() throws {
        let app = launch()
        openChooser(app, "Fixture Chooser")
        choice(app, source: "Fixture Source B", confidence: "possible match").tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 10))
        app.buttons["BackButton"].tap()

        // Reopen: Read on… goes straight to B's Listing, no chooser.
        tapCard(app, "Fixture Chooser")
        XCTAssertTrue(app.buttons["Read on…"].waitForExistence(timeout: 10))
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Preview"].exists)
        attach(app, name: "mal-hub-remembered-open")
        app.buttons["BackButton"].tap()

        tapCard(app, "Fixture Chooser")
        let sourceMenu = app.buttons["Source"]
        XCTAssertTrue(sourceMenu.waitForExistence(timeout: 10))
        // A coordinate tap: on CI's iOS 26.2 `.tap()` first asks AX to scroll this toolbar
        // menu button into view, which fails with kAXErrorCannotComplete (it is already visible).
        sourceMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Choose another Source"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Source A"].waitForExistence(timeout: 10))
        attach(app, name: "mal-hub-choose-another")
    }

    // Acceptance 13: the honest empty state.
    func testNotOnYourSourcesStateOffersRepositoryHint() throws {
        let app = launch()
        selectSection(app, "Similar")
        tapCard(app, "Fixture Nowhere")
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.staticTexts["Not on your Sources"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Add a repository in Settings to add more places to read."].exists)
        XCTAssertFalse(element(app, label: "Couldn't check").exists)
        attach(app, name: "mal-hub-not-found")
    }

    // Acceptance 9: the challenge sheet appears over the preview, outlives the 8-second
    // search deadline, and Cancel returns to the preview with only that Source unchecked.
    func testTapMayPresentChallengeAndCancelReturnsToPreview() throws {
        let app = launch()
        selectSection(app, "Similar")
        tapCard(app, "Fixture Challenge")
        app.buttons["Read on…"].tap()
        let challenge = app.navigationBars["Verification Required"]
        XCTAssertTrue(challenge.waitForExistence(timeout: 10))
        attach(app, name: "mal-hub-challenge")
        // Past the orchestration deadline: the search must still be waiting on the sheet.
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(challenge.exists)
        challenge.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Not on the Sources that answered"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Fixture Source E"].exists)
        XCTAssertTrue(element(app, label: "Couldn't check").exists)
        XCTAssertFalse(app.staticTexts["Not on your Sources"].exists)
        XCTAssertFalse(challenge.exists)
        XCTAssertTrue(app.navigationBars["Preview"].exists)
        attach(app, name: "mal-hub-challenge-cancelled")
    }

    // Design "Accessibility": at large Dynamic Type nothing in the chooser truncates.
    func testChooserAtLargeDynamicType() throws {
        let app = launch(arguments: ["-uitest-mal-hub", "-UIPreferredContentSizeCategoryName",
                                     "UICTContentSizeCategoryAccessibilityL"])
        openChooser(app, "Fixture Chooser")
        XCTAssertTrue(choice(app, source: "Fixture Source B", confidence: "possible match").exists)
        attach(app, name: "mal-hub-chooser-large-type")
        app.swipeUp()
        attach(app, name: "mal-hub-chooser-large-type-scrolled")
    }

    // MARK: - Helpers

    private func launch(arguments: [String] = ["-uitest-mal-hub"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = UUID().uuidString
        app.launch()
        app.tabBars.buttons["Library"].tap()
        app.staticTexts["Hub Fixture Title"].tap()
        return app
    }

    private func openChooser(_ app: XCUIApplication, _ title: String) {
        selectSection(app, "Similar")
        let target = card(app, title)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        tapCard(app, title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A fixed fixture synopsis."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["MAL title · 1300"].exists)
        app.buttons["Read on…"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Source A"].waitForExistence(timeout: 10))
    }

    private func selectSection(_ app: XCUIApplication, _ title: String) {
        let segment = app.buttons[title]
        if segment.waitForExistence(timeout: 2) {
            segment.tap()
        } else {
            let picker = app.descendants(matching: .any)["detailSectionPicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 10), "section picker should exist")
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 10), "\(title) menu item should exist")
            app.buttons[title].tap()
        }
        if title == "Similar" {
            XCTAssertTrue(app.descendants(matching: .any)["moreLikeThisSection"]
                .waitForExistence(timeout: 10))
        } else if title == "Related" {
            XCTAssertTrue(app.descendants(matching: .any)["relatedSection"]
                .waitForExistence(timeout: 10))
        }
    }

    // After a segment switch XCUITest cannot scroll an off-screen rail card into view (bisected 2026-11-12: the pane switch alone causes it); swipe the rail instead.
    private func tapCard(_ app: XCUIApplication, _ title: String) {
        var target = card(app, title)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let railCandidates = app.scrollViews.containing(.button, identifier: "malCandidateCard")
        var rail = railCandidates.allElementsBoundByIndex.first(where: { $0.frame.height < 600 })
            ?? railCandidates.firstMatch
        let windowFrame = app.windows.firstMatch.frame
        for _ in 0..<3 where !windowFrame.contains(rail.frame) {
            app.swipeUp()
            rail = railCandidates.allElementsBoundByIndex.first(where: { $0.frame.height < 600 })
                ?? railCandidates.firstMatch
        }
        if target.frame.minX >= app.frame.maxX || target.frame.maxX <= app.frame.minX {
            for _ in 0..<4 {
                rail.swipeLeft()
                target = card(app, title)
                if target.waitForExistence(timeout: 2) && target.frame.minX < app.frame.maxX {
                    break
                }
            }
        }
        XCTAssertTrue(target.isHittable, "card should be hittable after scrolling rail")
        target.tap()
    }

    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(identifier: "malCandidateCard")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title),")).firstMatch
    }

    /// A chooser row, found by its spoken label: "title, Source, confidence, …, count".
    private func choice(_ app: XCUIApplication, source: String, confidence: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                         ", \(source),", confidence)).firstMatch
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
