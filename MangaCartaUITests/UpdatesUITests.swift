//
//  UpdatesUITests.swift
//  MangaCartaUITests
//

import XCTest

/// Device-level evidence for the five update surfaces in ADR-0021. Every launch
/// uses the app's deterministic fixture; these assertions intentionally never
/// infer state from a live source request.
final class UpdatesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testNoSavedWorksExplainsHowToBeginUpdates() throws {
        let app = launch(state: "empty", accessibilitySize: true)

        XCTAssertTrue(app.staticTexts["Keep your library current"].waitForExistence(timeout: 10),
                      "Home should explain the no-saved-Works update state")
        XCTAssertTrue(app.buttons["Browse Titles"].exists,
                      "the empty update state should offer a direct browse action")
        XCTAssertTrue(app.buttons["Search Titles"].exists,
                      "the empty update state should offer a direct search action")
        XCTAssertFalse(app.staticTexts["Not checked yet"].exists,
                       "an empty library must not make a freshness claim")
        attach(app, name: "01-updates-no-saved-works")
    }

    func testSavedWorkWithoutBaselineShowsNotCheckedYet() throws {
        let app = launch(state: "not-checked", accessibilitySize: true)

        XCTAssertTrue(app.staticTexts["Not checked yet"].waitForExistence(timeout: 10),
                      "a saved work without a baseline should say Not checked yet")
        XCTAssertTrue(app.buttons["updatesRefreshButton"].exists,
                      "the foreground refresh action should be available")
        attach(app, name: "02-updates-not-checked-yet")
    }

    func testForegroundRefreshCompletesWithoutUsingALiveSource() throws {
        let app = launch(state: "refresh-complete")

        let refresh = app.buttons["updatesRefreshButton"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Not checked yet"].exists)
        refresh.tap()

        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Last checked")
        ).firstMatch.waitForExistence(timeout: 10),
                      "the fixture-backed foreground refresh should finish and expose fresh status")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Last checked")
        ).firstMatch.exists,
                      "the refresh control should expose its completed state to VoiceOver")
        attach(app, name: "03-updates-refresh-complete")
    }

    func testUpdatesFilterExposesSelectedState() throws {
        let app = launch(state: "updates-filter")

        app.tabBars.buttons["Library"].tap()
        let updates = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Updates")
        ).firstMatch
        XCTAssertTrue(updates.waitForExistence(timeout: 10))
        updates.tap()

        XCTAssertEqual(updates.value as? String, "Selected",
                       "the Updates filter must expose selection beyond its color")
        XCTAssertTrue(app.buttons.matching(identifier: "libraryCoverCard").firstMatch.exists,
                      "the selected filter should retain the fixture's discovered work")
        attach(app, name: "04-updates-filter-selected")
    }

    func testSettingsShowsNotificationAuthorizationRowAtAccessibilitySize() throws {
        let app = launch(state: "not-checked", accessibilitySize: true)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Updates"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["System notifications"].exists,
                      "Settings should identify the system authorization row")
        XCTAssertTrue(app.staticTexts["Not requested"].exists,
                      "the fixture must not inherit this simulator's authorization state")
        XCTAssertTrue(app.switches["Notify about new chapters"].exists,
                      "the authorization control should remain reachable at accessibility sizes")
        attach(app, name: "05-updates-settings-authorization-large-text")
    }

    /// Notification-actions AC 7: Mute from the Home row, Unmute from the Library card, and
    /// the row says which state it is in. Whether the next release then notifies (and old
    /// ones are not replayed) is `UpdateNotifierTests.unmuteSchedulesNextEventWithoutReplay`.
    func testUnmuteRestoresFutureNotifications() throws {
        let app = launch(state: "updates-filter")
        let row = updateRow(in: app, title: "Fixture Update Title")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "positive control: the fixture's row exists")
        XCTAssertFalse(row.label.contains("Muted"))

        row.press(forDuration: 1.0)
        let mute = app.buttons["Mute notifications"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        mute.tap()
        XCTAssertTrue(waitForLabel(of: row, toContain: "Muted"), "the row must say it is muted")
        attach(app, name: "06-updates-row-muted")

        app.tabBars.buttons["Library"].tap()
        let card = app.buttons.matching(identifier: "libraryCoverCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertEqual(card.value as? String, "Muted", "the card exposes the muted state")
        card.press(forDuration: 1.0)
        let unmute = app.buttons["Unmute notifications"]
        XCTAssertTrue(unmute.waitForExistence(timeout: 5))
        unmute.tap()
        XCTAssertTrue(waitForValue(of: card, toBe: ""), "the card no longer reads as muted")

        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: row, toLack: "Muted"), "unmuting from Library reaches Home")
        attach(app, name: "07-updates-row-unmuted")
    }

    /// Notification-actions AC 9 (Amendment 1 item 6): a real delivered notification's
    /// "Mark Read", chosen from SpringBoard while the app is in the background, marks the
    /// captured chapter (2) and leaves the later discovery (3) new, without bringing the app
    /// forward. The fixture schedules the request through `UpdateNotifier.schedule`, so the
    /// category and payload are production's.
    func testDeliveredNotificationMarkReadAction() throws {
        let app = launch(state: "notification-actions")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }

        let row = updateRow(in: app, title: "Notification Action Title")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("3 unread chapters"), "precondition: \(row.label)")
        XCTAssertTrue(row.label.contains("2 new chapters"), "precondition: \(row.label)")

        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "new chapter of Notification Action Title")
        ).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "the scheduled notification is delivered")
        banner.press(forDuration: 1.5)
        let markRead = springboard.buttons["Mark Read"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5), "the expanded banner offers Mark Read")
        XCTAssertTrue(springboard.buttons["Mute"].exists, "and Mute")
        attachScreen(springboard, name: "08-notification-actions-expanded")
        markRead.tap()

        // A background action: the app must not be brought to the foreground. Judged by the
        // screen, not `app.state`: once the system wakes the app in the background to run the
        // action, XCUITest reports it `runningForeground` while the home screen is showing.
        sleep(4)
        attachScreen(springboard, name: "09a-after-mark-read")
        XCTAssertTrue(springboard.icons["MangaCarta"].isHittable,
                      "the home screen is still in front: Mark Read is a background action")

        app.activate()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: row, toContain: "2 unread chapters"),
                      "chapter 2 is read: \(row.label)")
        XCTAssertTrue(row.label.contains("1 new chapter"), "chapter 3 is still new: \(row.label)")
        attach(app, name: "10-notification-action-marked-read")
    }

    // MARK: - Updates screen (spec 2026-11-09, slice 2)
    //
    // Reached through `-uitest-open-updates`, a debug-only route that pushes the screen from
    // Home at launch. Slice 3 replaces it with Home's and Library's real entry points.

    /// AC 7, minus the Home link slice 3 adds: day sections, Work groups and chapter rows,
    /// a chapter that reaches the reader, and a discovery with no chapter behind it.
    func testUpdatesDestinationShowsDayWorkAndChapterRows() throws {
        let app = launchUpdatesScreen(state: "updates-screen")

        XCTAssertTrue(app.navigationBars["Updates"].waitForExistence(timeout: 10))
        XCTAssertTrue(heading(in: app, "Today").exists, "the answering Work was discovered today")
        XCTAssertTrue(heading(in: app, "Yesterday").exists, "the failing Work was discovered yesterday")
        XCTAssertTrue(workHeader(in: app, title: "Fixture Update Title").exists)
        XCTAssertTrue(app.staticTexts["4 new chapters"].exists, "the header counts new chapters, not unread")

        let chapter3 = chapterLink(in: app, containing: "Fixture Chapter 3")
        XCTAssertTrue(chapter3.waitForExistence(timeout: 10), "chapter metadata loads for an expanded Work")
        XCTAssertTrue(chapterLink(in: app, containing: "Fixture Chapter 2").exists)
        XCTAssertFalse(chapterLink(in: app, containing: "Fixture Chapter 1").exists,
                       "a chapter that was not newly discovered is not listed")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "updatesChapterUnresolved")
            .matching(NSPredicate(format: "label CONTAINS %@", "Chapter 4")).firstMatch.exists,
                      "a discovery the Source no longer lists stays visible")
        XCTAssertTrue(app.buttons["updatesViewChapterList"].firstMatch.exists,
                      "and offers the chapter list instead")
        attach(app, name: "11-updates-screen")

        chapter3.tap()
        XCTAssertTrue(app.buttons["readerCloseButton"].waitForExistence(timeout: 10),
                      "a chapter row opens the reader")
    }

    /// AC 9: Mark all seen empties the inbox and leaves every chapter unread.
    func testMarkAllSeenAnnouncesAndPreservesUnread() throws {
        let app = launchUpdatesScreen(state: "updates-screen")
        let markAll = app.buttons["updatesMarkAllSeenButton"]
        XCTAssertTrue(markAll.waitForExistence(timeout: 10))
        XCTAssertTrue(markAll.isEnabled)
        let chapter2 = chapterLink(in: app, containing: "Fixture Chapter 2")
        XCTAssertTrue(chapter2.waitForExistence(timeout: 10))
        XCTAssertTrue(chapter2.label.contains("Unread"), "precondition: \(chapter2.label)")
        XCTAssertTrue(chapter2.label.contains("NEW"), "new is spoken, not only stamped: \(chapter2.label)")

        markAll.tap()

        XCTAssertTrue(app.descendants(matching: .any)["updatesUpToDate"].waitForExistence(timeout: 5))
        XCTAssertFalse(workHeader(in: app, title: "Fixture Update Title").exists)
        XCTAssertTrue(markAll.exists, "the control stays where focus was")
        XCTAssertFalse(markAll.isEnabled, "and has nothing left to do")
        attach(app, name: "12-updates-all-seen")

        // Seen is not read: the same chapter is still unread on the detail page.
        app.tabBars.buttons["Library"].tap()
        let card = app.buttons.matching(identifier: "libraryCoverCard")
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Update Title")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let detailRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Chapter 2")).firstMatch
        for _ in 0..<4 where !detailRow.exists { app.swipeUp() }
        XCTAssertTrue(detailRow.waitForExistence(timeout: 10))
        XCTAssertTrue(detailRow.label.contains("Unread"), "seen is not read: \(detailRow.label)")
    }

    /// The per-Work "Mark seen" in the Work row's trailing menu clears that Work alone.
    func testPerWorkMarkSeenFromTrailingMenu() throws {
        let app = launchUpdatesScreen(state: "updates-screen")
        let menu = app.buttons["Actions for Second Fixture Title"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))

        menu.tap()
        let markSeen = app.buttons["Mark seen"]
        XCTAssertTrue(markSeen.waitForExistence(timeout: 5))
        markSeen.tap()

        XCTAssertTrue(waitForAbsence(of: workHeader(in: app, title: "Second Fixture Title")))
        XCTAssertFalse(heading(in: app, "Yesterday").exists, "its day section goes with it")
        XCTAssertTrue(workHeader(in: app, title: "Fixture Update Title").exists, "the other Work stays")
        XCTAssertTrue(app.staticTexts["3 new chapters"].exists)
    }

    /// AC 12: the up-to-date state, the no-saved-Works state, a load failure that keeps its
    /// rows, and a refresh failure that names its Source without erasing known rows.
    func testUpdatesEmptyStateAndRefreshFailure() throws {
        var app = launchUpdatesScreen(state: "refresh-complete")
        XCTAssertTrue(app.descendants(matching: .any)["updatesUpToDate"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["You’re up to date"].exists)
        XCTAssertTrue(app.buttons["updatesScreenRefreshButton"].exists, "refresh stays available")
        XCTAssertFalse(app.buttons["updatesMarkAllSeenButton"].isEnabled)
        attach(app, name: "13-updates-up-to-date")
        app.terminate()

        app = launchUpdatesScreen(state: "empty")
        XCTAssertTrue(app.descendants(matching: .any)["updatesNoSavedWorks"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Browse Titles"].exists)
        app.terminate()

        app = launchUpdatesScreen(state: "updates-screen")
        let failing = workHeader(in: app, title: "Second Fixture Title")
        XCTAssertTrue(failing.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["updatesChaptersRetry"].waitForExistence(timeout: 10),
                      "a Source that fails to list chapters offers Try Again")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "updatesChapterUnresolved")
            .matching(NSPredicate(format: "label CONTAINS %@", "Chapter 2")).firstMatch.exists,
                      "and keeps the discovered chapter's row")

        app.buttons["updatesScreenRefreshButton"].tap()
        let notice = app.descendants(matching: .any)["updatesRecoveryNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "a failed check is named after refresh")
        XCTAssertTrue(notice.label.contains("Failing Fixture"), notice.label)
        XCTAssertTrue(failing.exists, "failed data is unknown, not a vanished chapter")
        XCTAssertTrue(workHeader(in: app, title: "Fixture Update Title").exists)
        attach(app, name: "14-updates-refresh-failure")
    }

    /// AC 11's reachability half: at the largest accessibility size the controls and a
    /// chapter link are still there and hittable.
    func testUpdatesAccessibilityAtLargeText() throws {
        let app = launchUpdatesScreen(state: "updates-screen", accessibilitySize: true)
        XCTAssertTrue(app.buttons["updatesMarkAllSeenButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["updatesMarkAllSeenButton"].isHittable)
        XCTAssertTrue(app.buttons["updatesScreenRefreshButton"].isHittable)
        XCTAssertTrue(heading(in: app, "Today").exists)

        let chapter = chapterLink(in: app, containing: "Fixture Chapter 3")
        for _ in 0..<6 where !(chapter.exists && chapter.isHittable) { app.swipeUp() }
        XCTAssertTrue(chapter.isHittable, "a chapter link is reachable at accessibility sizes")
        attach(app, name: "15-updates-large-text")
    }

    private func launchUpdatesScreen(state: String, accessibilitySize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-updates-state", state, "-uitest-open-updates"]
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                    "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func heading(in app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "updatesDayHeading")
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func workHeader(in app: XCUIApplication, title: String) -> XCUIElement {
        app.buttons.matching(identifier: "updatesWorkHeader")
            .matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func chapterLink(in app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(identifier: "updatesChapterLink")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func waitForAbsence(of element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                              timeout: 5) == .completed
    }

    private func updateRow(in app: XCUIApplication, title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func waitForLabel(of element: XCUIElement, toContain text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                              timeout: 5) == .completed
    }

    private func waitForLabel(of element: XCUIElement, toLack text: String) -> Bool {
        let predicate = NSPredicate(format: "NOT (label CONTAINS %@)", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                              timeout: 5) == .completed
    }

    private func waitForValue(of element: XCUIElement, toBe value: String) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                              timeout: 5) == .completed
    }

    private func attachScreen(_ springboard: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: springboard.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(state: String, accessibilitySize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-updates-state", state]
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                    "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
