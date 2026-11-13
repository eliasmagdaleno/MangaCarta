import XCTest

/// Xcode's automated accessibility audit over the screens #90's VoiceOver pass walks — Home,
/// Library, detail, reader and Settings — using a local import, so it needs no network or
/// repository. It catches missing descriptions, undersized hit regions and Dynamic Type gaps
/// before a person spends a device session on them. It does **not** replace that pass:
/// traversal order, announcements and focus restoration still need a human with VoiceOver on.
///
/// Two audit types are left out because they misfire here (checked 2026-10-01 against
/// screenshots of each finding):
/// - `.contrast` flags text scrolled under the translucent tab bar, which it samples through
///   the blur. Real contrast failures still need an eye; the one it found (Library chip
///   counts at 60% opacity) was fixed alongside this test.
/// - `.textClipped` flags single-line titles and labels that render whole.
final class AccessibilityAuditUITests: XCTestCase {
    private let storageID = UUID().uuidString
    private static let audited = XCUIAccessibilityAuditType.all.subtracting([.contrast, .textClipped])

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    func testCoreScreensPassTheAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-local-import", "-uitest-import-fixture", "deflated"]
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = storageID
        app.launchEnvironment["MANGACARTA_UI_FIXTURE_BASE64"] = LocalImportUITests.fixtureBase64
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        try audit(app, screen: "home")

        app.tabBars.buttons["Library"].tap()
        let card = app.buttons["libraryCoverCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        try audit(app, screen: "library")

        card.tap()
        let read = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'Start Reading' OR label CONTAINS[c] 'Continue'")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        try audit(app, screen: "detail")

        read.tap()
        XCTAssertTrue(app.buttons["Close reader"].waitForExistence(timeout: 10))
        try audit(app, screen: "reader")
        app.buttons["Close reader"].tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Manage Collections"].waitForExistence(timeout: 10))
        try audit(app, screen: "settings")
    }

    /// Notification-actions AC 10: the muted state is spoken, the unmute control is a named
    /// native control reachable without sight, and Home with a muted row passes the audit.
    func testNotificationMuteControlsAreAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-updates-state", "updates-filter"]
        app.launch()
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Update Title,")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "positive control: the update row exists")
        XCTAssertFalse(row.label.contains("Muted"))

        row.press(forDuration: 1.0)
        let mute = app.buttons["Mute notifications"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        mute.tap()   // closes the menu by its own entry (CI's iOS 26.2 quirk)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Muted"), object: row)],
                                     timeout: 5) == .completed,
                      "VoiceOver hears the muted state in the row: \(row.label)")

        row.press(forDuration: 1.0)
        let unmute = app.buttons["Unmute notifications"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 5), "the unmute control is named, not an icon")
        // Close the menu by tapping its entry; unmuting is not under test here, so mute again.
        unmute.tap()
        row.press(forDuration: 1.0)
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        mute.tap()
        XCTAssertTrue(row.label.contains("Muted"))

        // Scoped to the row and its control: Home's other controls have their own audit in
        // testCoreScreensPassTheAccessibilityAudit, and their findings are not this feature's.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "a11y-home-muted-update-row"
        shot.lifetime = .keepAlways
        add(shot)
        var rowAudited = false
        try app.performAccessibilityAudit(for: Self.audited) { issue in
            guard let element = issue.element else { return true }
            let isRow = element.label.hasPrefix("Fixture Update Title,")
                || element.identifier == "workMuteToggle"
            if isRow {
                rowAudited = true
                XCTFail("[home-muted-update-row] \(issue.compactDescription): '\(element.label)'")
            }
            return true
        }
        XCTAssertFalse(rowAudited, "the muted row and its control pass the audit")
    }

    /// Fails once per finding, naming the screen and element, and attaches the screen so a
    /// failure can be judged without re-running.
    private func audit(_ app: XCUIApplication, screen: String) throws {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "a11y-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)
        try app.performAccessibilityAudit(for: Self.audited) { issue in
            let element = issue.element.map { "'\($0.label)' (id '\($0.identifier)')" } ?? "no element"
            XCTFail("[\(screen)] \(issue.compactDescription): \(element)")
            return true
        }
    }
}
