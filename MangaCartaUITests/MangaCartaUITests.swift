//
//  MangaCartaUITests.swift
//  MangaCartaUITests
//
//  Created by Elias Magdaleno on 5/31/24.
//

import XCTest

// MARK: - The live set — deliberately NOT in the must-be-green set (#134)
//
// Every test in this file drives the real reader against live MangaDex, MyAnimeList or
// AniList. They are a **local, run-by-name gate**: run them with `-only-testing:` when you
// touch the path they cover, not as a whole-target sweep and not as a merge condition.
//
// WHY THEY ARE NOT A MERGE CONDITION. #134 found the two ways they go red, and only one of
// them is a defect:
//
//  1. A real regression — an accessibility label changed and no query followed it. That is
//     what these tests are for, and it went unnoticed for two weeks.
//  2. The catalog moved. WeebCentral stopped carrying chapters for a title one leg had named,
//     and the leg failed for a reason that has nothing to do with this app. Nothing in the
//     repository could have noticed, and no amount of care prevents the next one.
//
// A gate that cannot tell those apart teaches people to ignore it. So the answer is not to
// run these in CI: it is to **not name live data** wherever the test does not measure it —
// see `displaceUsingAnyLibraryTitle` for the shape — and to keep the hermetic suites, which
// *are* a merge condition, carrying the regression coverage. Those are `UpdatesUITests` and
// `SourcePreferenceUITests`; they launch on a fixture registry with isolated storage, make no
// network request, and run on every PR (`.github/workflows/ci.yml`, the `ui-tests` job).
//
// Moving a test out of this file into the hermetic set is a claim that it makes no network
// request. Moving one in is a claim that it cannot be written without live data.

final class MangaCartaUITests: XCTestCase {

    /// No remote Source ships in the app (ADR-0003 Amendment 6), so every test here that
    /// browses installs the published repository first, through the real installer
    /// (`LiveUITestRepositoryInstall`). Idempotent: on a device that already has it, the
    /// launch refreshes it and installs nothing. `-uitest-source mangadex` then names the
    /// installed Source by its `localId`.
    static let liveRepositoryArguments = [
        "-uitest-install-repository",
        "https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/index.json",
    ]

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    /// Walks Home → Detail and attaches screenshots. Doubles as a smoke test for
    /// the source chip bar (Home) and the action row (Detail).
    func testHomeAndDetailScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        // Home: the source chip bar must be present and MangaDex active.
        let mangadexChip = app.buttons["Browse MangaDex"]
        XCTAssertTrue(mangadexChip.waitForExistence(timeout: 10),
                      "source chip bar should be on Home")

        // Wait for the first rail to load real content.
        let firstCard = app.buttons.matching(identifier: "mangaCoverCard").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 20),
                      "a cover card should load on Home")
        sleep(3) // let cover images finish

        attach(app, name: "01-home")

        // Detail: open the first cover card. Tap the cover art itself (upper
        // half) — and retry once, since a LazyVStack re-layout while covers
        // stream in can swallow the first tap.
        let addOrToggle = app.buttons["Add to Library"]
        let removeToggle = app.buttons["Remove from Library"]
        firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        if !addOrToggle.waitForExistence(timeout: 8) && !removeToggle.exists {
            firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        }
        XCTAssertTrue(addOrToggle.waitForExistence(timeout: 15) || removeToggle.exists,
                      "the library toggle should be on Detail")
        sleep(4) // let chapters + cover load

        attach(app, name: "02-detail")
    }

    /// The signed-out MyAnimeList section, in the real Settings screen. It is the one state
    /// reachable without an account, and the only wiring that cannot be proven below the
    /// UI: that `MALAccountSettingsView` is actually in `SettingsView`, and that the store
    /// reaches it through the environment (a missing `environmentObject` traps at runtime,
    /// so this test failing is how that shows up).
    func testSettingsShowsTheSignedOutMyAnimeListSection() throws {
        let app = XCUIApplication()
        // Without this the test reads the real Keychain and preferences: it passes on a
        // fresh simulator and fails on any machine where someone has actually signed in.
        app.launchArguments.append("-uitest-mal-signed-out")
        app.launch()

        app.tabBars.buttons["Settings"].tap()

        let header = app.staticTexts["MyAnimeList"]
        XCTAssertTrue(header.waitForExistence(timeout: 10),
                      "the MyAnimeList section should be in Settings")
        XCTAssertTrue(app.buttons["Sign in"].exists,
                      "signed out, the section offers Sign in")
        XCTAssertFalse(app.staticTexts["Sync reading progress"].exists,
                       "signed out, no account controls are rendered")

        attach(app, name: "10-settings-mal-signed-out")
    }

    /// **The four MAL Settings states that had never been rendered on a device** (MAL plan,
    /// Task 12). Everything below the view — which branch a state maps to — is decided in
    /// `MALAccountPresentation` and tested there; what only a device can answer is whether
    /// the resulting section actually lays out, and at an accessibility text size whether it
    /// still fits. The screenshots are the artifact.
    ///
    /// Runs on a seeded stand-in account, never this device's real one.
    func testMyAnimeListSettingsStatesRender() throws {
        for state in ["signed-in", "refreshing", "reauthorization-required", "account-switch"] {
            let app = XCUIApplication()
            app.launchArguments += ["-uitest-mal-state", state]
            // A previous test can leave the simulator on its side, and these screenshots
            // are the deliverable. Set it rather than inherit it.
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            app.tabBars.buttons["Settings"].tap()

            XCTAssertTrue(app.staticTexts["MyAnimeList"].waitForExistence(timeout: 10),
                          "the MyAnimeList section should be in Settings for \(state)")
            // The switch alert is modal, so nothing under it is hittable — that state's
            // screenshot is of the alert, which is the thing that had never been seen.
            if state != "account-switch" { scrollToMALSection(app) }
            // Every one of these is a signed-in-shaped section, so the sign-in offer must
            // be gone — that is what tells a rendered state from a silently signed-out one.
            XCTAssertFalse(app.buttons["Sign in"].exists,
                           "\(state) should not be offering a fresh sign-in")
            attach(app, name: "11-settings-mal-\(state)")

            if state == "account-switch" {
                XCTAssertTrue(app.buttons["Keep them"].waitForExistence(timeout: 5),
                              "the account-switch alert should be up")
                XCTAssertTrue(app.buttons["Delete queued updates"].exists)
                app.buttons["Keep them"].tap()
            }
            app.terminate()
        }
    }

    /// The signed-in section at the largest accessibility text size. Separate from the loop
    /// above because the size is set by a launch argument to the whole app, not by state.
    func testMyAnimeListSettingsAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-mal-state", "signed-in",
                                "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["MyAnimeList"].waitForExistence(timeout: 10),
                      "the MyAnimeList section should survive accessibility text sizes")
        scrollToMALSection(app)
        attach(app, name: "12-settings-mal-large-text")
    }

    /// Existing in the hierarchy is not the same as being on screen, and a screenshot of
    /// the section scrolled past proves nothing. MyAnimeList is the last section in
    /// Settings, so this scrolls to the bottom — stopping at the header would leave the
    /// card itself behind the tab bar, which is what the first attempt at this captured.
    private func scrollToMALSection(_ app: XCUIApplication) {
        let header = app.staticTexts["MyAnimeList"]
        for _ in 0..<8 where !header.isHittable {
            app.swipeUp(velocity: .fast)
            usleep(400_000)
        }
        XCTAssertTrue(header.isHittable, "the MyAnimeList section should be reachable on screen")
        // Past the header, to the end of the scroll view.
        for _ in 0..<3 {
            app.swipeUp(velocity: .fast)
            usleep(400_000)
        }
    }

    /// **A one-off live verification for MAL Task 12, not a CI test.** It reads a chapter of
    /// a real title to the end, which is the only thing that may move MyAnimeList progress —
    /// manual mark-as-read deliberately cannot. Run only with explicit approval, and only
    /// through `scripts/mal_live_write.py fire` — that harness records the account's list
    /// entry before the run and puts it back afterwards, including when the run fails.
    ///
    /// Chapter **124** is not arbitrary: the account sits at 100 chapters, and the coordinator
    /// treats a desired progress at or below the remote value as already delivered
    /// (`MALProgressCoordinator.swift:281`), so anything lower would verify nothing. 101 does
    /// not exist — MangaDex's English list for this title jumps from 30 to 123.1.
    func testLiveHorimiyaCompletionPushesProgress() throws {
        // **Cannot run by accident.** This one writes to a real MyAnimeList account, so a
        // plain `xcodebuild test` must skip it — the variable has to be set deliberately,
        // and only alongside the read/restore harness described above.
        //
        // From the CLI the variable must carry the `TEST_RUNNER_` prefix, which `xcodebuild`
        // strips before handing it to the runner process. A bare `MAL_LIVE_WRITE=1` in the
        // shell does *not* reach `ProcessInfo` and the test silently skips:
        //
        //     TEST_RUNNER_MAL_LIVE_WRITE=1 xcodebuild -scheme MangaCarta \
        //       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
        //       test -only-testing:MangaCartaUITests/MangaCartaUITests/\
        //     testLiveHorimiyaCompletionPushesProgress
        //
        // Verified 2026-08-24 with both `test` and `test-without-building`. An Xcode scheme's
        // environment variable works too, and needs no prefix.
        //
        // `scripts/mal_live_write.py fire` is the invocation to reach for: it runs exactly the
        // command above with the account's list entry recorded first and restored after.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAL_LIVE_WRITE"] == "1",
                          "live MAL write: set TEST_RUNNER_MAL_LIVE_WRITE=1 to run, and restore the entry after")

        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launchArguments += ["-uitest-source", "mangadex"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        app.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Horimiya\n")

        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Horimiya"))
            .firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 25), "search should return Horimiya")
        result.tap()

        let libraryToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Library"))
            .firstMatch
        XCTAssertTrue(libraryToggle.waitForExistence(timeout: 25), "should reach the detail page")

        let showAll = app.buttons["showAllChaptersButton"]
        for _ in 0..<10 where !showAll.exists {
            app.swipeUp(velocity: .fast)
            usleep(500_000)
        }
        XCTAssertTrue(showAll.exists, "Horimiya should have a full chapter list")
        showAll.tap()

        // Find chapter 124. The list is long, so scroll toward it rather than assuming it is
        // on screen.
        let chapter = app.buttons.matching(Self.chapterRow(number: "124")).firstMatch
        var found = false
        for _ in 0..<40 where !found {
            if chapter.exists { found = true; break }
            app.swipeUp(velocity: .fast)
            usleep(300_000)
        }
        XCTAssertTrue(found, "chapter 124 should be in the list")
        attach(app, name: "30-chapter-124-row")
        chapter.tap()

        // Read it to the last page. The indicator reads "n · total" and is part of the
        // reader chrome, which is hidden until tapped — so reveal it before looking.
        let indicator = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " · "))
            .firstMatch
        for _ in 0..<12 where !indicator.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            usleep(1_500_000)
        }
        XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the reader should load pages")
        let total = Self.indicatorTotal(indicator.label)
        XCTAssertNotNil(total, "could not read a page count from '\(indicator.label)'")
        let pages = total ?? 0
        XCTAssertGreaterThan(pages, 1, "a one-page chapter would not prove paging")

        // Direction is a property of the title's reading direction, so probe rather than
        // assume: R→L is implemented as reversed page order, not a mirror.
        var advancing = false
        app.swipeLeft()
        usleep(600_000)
        if Self.indicatorCurrent(indicator.label) ?? 1 > 1 { advancing = true }

        for _ in 0..<(pages + 5) {
            if (Self.indicatorCurrent(indicator.label) ?? 0) >= pages { break }
            if advancing { app.swipeLeft() } else { app.swipeRight() }
            usleep(500_000)
        }
        attach(app, name: "31-last-page")
        XCTAssertEqual(Self.indicatorCurrent(indicator.label), pages,
                       "the chapter must reach its final page — anything less is not a completion")

        // `HistoryStore` throttles its writes and flushes on `.background`; a run that just
        // ends loses the entry, and with it the queued update.
        XCUIDevice.shared.press(.home)
        sleep(8)
    }

    // The indicator renders "4 · 20" but now *speaks* "Page 4 of 20" (issue #90): the
    // middle dot is typography, and XCUITest reads the accessibility label, not the glyphs.
    // Both helpers parse the spoken form, which is the one an assertion should depend on
    // anyway — the visual string is free to change again.
    private static func indicatorCurrent(_ label: String) -> Int? {
        indicatorNumbers(label).first
    }

    private static func indicatorTotal(_ label: String) -> Int? {
        indicatorNumbers(label).last
    }

    private static func indicatorNumbers(_ label: String) -> [Int] {
        label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Captures Settings only after the MyAnimeList evidence is visibly above the tab bar.
    /// `isHittable` is deliberately not used: XCTest reports elements covered by the tab bar
    /// as hittable on the current runtime, which produced correctly asserted but useless
    /// screenshots twice. Frame containment is the artifact contract.
    private func attachSettingsEvidence(_ app: XCUIApplication, name: String) {
        let queue = syncQueue(in: app)
        let candidates = [
            queue,
            app.switches["Sync reading progress"],
            app.buttons["Sign in"],
            app.staticTexts["MyAnimeList"]
        ]
        guard let evidence = candidates.first(where: \.exists) else {
            XCTFail("Settings screenshot '\(name)' has no MyAnimeList evidence element")
            attach(app, name: name)
            return
        }

        let tabBar = app.tabBars.firstMatch
        for _ in 0..<10 {
            let top = app.frame.minY + 8
            let bottom = tabBar.exists ? tabBar.frame.minY - 8 : app.frame.maxY - 8
            let frame = evidence.frame
            if frame.minY >= top && frame.maxY <= bottom { break }
            if frame.maxY > bottom {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            usleep(400_000)
        }

        let visibleBottom = tabBar.exists ? tabBar.frame.minY - 8 : app.frame.maxY - 8
        XCTAssertGreaterThanOrEqual(evidence.frame.minY, app.frame.minY + 8,
                                    "Settings evidence must be below the top edge in '\(name)'")
        XCTAssertLessThanOrEqual(evidence.frame.maxY, visibleBottom,
                                 "Settings evidence must be above the tab bar in '\(name)'")
        attach(app, name: name)
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    /// Permanent live-verification of the real detail-page rail: open a popular Home title,
    /// scroll to the bottom, and assert the "More Like This" header plus at least one card
    /// appear — end-to-end against the real MAL + MangaDex APIs.
    func testMoreLikeThisDetailRailLiveVerification() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        // Home: wait for the first cover card, then open it (retry once — a LazyVStack
        // re-layout while covers stream in can swallow the first tap).
        let firstCard = app.buttons.matching(identifier: "mangaCoverCard").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 20), "a cover card should load on Home")
        // Any of the detail page's library labels ("Add to Library", "In Library",
        // "Remove from Library") proves it opened — which one shows depends on whether this
        // device already has the title, and Home's ranking drifts, so naming one is a
        // coin flip the test would lose.
        let libraryToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Library"))
            .firstMatch
        firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        // Retry only while the card is still there to tap. Once the push has happened the
        // same coordinate lands on the detail page and can navigate deeper, out of reach of
        // the assertion below — a slow detail page would then read as a broken one.
        if !libraryToggle.waitForExistence(timeout: 8) && firstCard.isHittable {
            firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        }
        XCTAssertTrue(libraryToggle.waitForExistence(timeout: 15),
                      "should have opened a manga detail page")

        // The rail loads async (MAL + MangaDex round-trips) and sits at the very bottom.
        // Poll: swipe up, check for the header, repeat until it appears or we give up.
        let header = app.staticTexts["More Like This"]
        var railAppeared = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if header.exists { railAppeared = true; break }
            app.swipeUp(velocity: .fast)
            usleep(700_000)
        }
        XCTAssertTrue(railAppeared,
                      "the 'More Like This' header should appear at the bottom of the detail page")

        // And at least one recommendation card under it. Query at app level rather than
        // scoping through `otherElements["moreLikeThisSection"]`: a plain VStack carrying
        // only an accessibilityIdentifier does not reliably surface as a queryable container
        // element, so the scoped `.buttons` query finds nothing even though the cards exist.
        // On the detail page the rail is the only source of `mangaCoverCard`s, so an
        // app-level query is equivalent (and mirrors the header assertion above).
        let card = app.buttons.matching(identifier: "mangaCoverCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "at least one More Like This card should render")
    }

    /// The detail page shows a truncated chapter preview, so the bottom-of-page
    /// "More Like This" rail is reachable in a few swipes instead of scrolling past
    /// the entire chapter list. Opens the first Home title and asserts the rail header
    /// appears within a small number of swipes.
    func testChapterPreviewKeepsRailReachable() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        let firstCard = app.buttons.matching(identifier: "mangaCoverCard").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 20), "a cover card should load on Home")
        // Any of the detail page's library labels ("Add to Library", "In Library",
        // "Remove from Library") proves it opened — which one shows depends on whether this
        // device already has the title, and Home's ranking drifts, so naming one is a
        // coin flip the test would lose.
        let libraryToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Library"))
            .firstMatch
        firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        // Retry only while the card is still there to tap. Once the push has happened the
        // same coordinate lands on the detail page and can navigate deeper, out of reach of
        // the assertion below — a slow detail page would then read as a broken one.
        if !libraryToggle.waitForExistence(timeout: 8) && firstCard.isHittable {
            firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        }
        XCTAssertTrue(libraryToggle.waitForExistence(timeout: 15),
                      "should have opened a manga detail page")

        XCTAssertTrue(app.staticTexts["Chapters"].waitForExistence(timeout: 15),
                      "the Chapters section should render")

        // Rail must be reachable within a handful of swipes (previously required
        // scrolling past the full list). Allow time for the async MAL/MangaDex rail load.
        let header = app.staticTexts["More Like This"]
        var reached = false
        for _ in 0..<8 where !reached {
            if header.exists { reached = true; break }
            app.swipeUp(velocity: .fast)
            usleep(500_000)
        }
        XCTAssertTrue(reached,
                      "the More Like This rail should be reachable within a few swipes of a truncated chapter list")
    }

    /// "Show all N chapters" opens the full-list screen, where sort and multi-select
    /// live. Taps through, toggles sort, then marks a chapter read via select mode.
    func testShowAllChaptersOpensFullListWithSortAndSelect() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        // Two things this test must establish rather than inherit. The browse source is
        // persisted (`SourceRegistry`), so a previous WeebCentral run would otherwise
        // decide which catalog this searches.
        app.launchArguments += ["-uitest-source", "mangadex"]
        app.launch()

        // **Searched, not taken from Home.** The full-list screen only exists above five
        // chapters, and Home's first card is whatever live ranking puts there — it was
        // "6000: Rokusen", three chapters, the day this was written, and the row was
        // correctly absent. Berserk is long, complete, and not going to shorten.
        app.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field should be present")
        field.tap()
        field.typeText("Berserk\n")

        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Berserk"))
            .firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 25), "search should return Berserk")
        result.tap()

        // Any of the detail page's library labels ("Add to Library", "In Library",
        // "Remove from Library") proves it opened — which one shows depends on whether this
        // device already holds the title.
        let libraryToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Library"))
            .firstMatch
        XCTAssertTrue(libraryToggle.waitForExistence(timeout: 25),
                      "should have opened a manga detail page")

        // The "Show all" row only exists for titles with > 5 chapters. Scroll it into
        // view; popular Home titles reliably qualify. (If the first title has ≤ 5
        // chapters the button is legitimately absent — re-run against a longer title.)
        let showAll = app.buttons["showAllChaptersButton"]
        var foundShowAll = false
        for _ in 0..<10 where !foundShowAll {
            if showAll.exists { foundShowAll = true; break }
            app.swipeUp(velocity: .fast)
            usleep(500_000)
        }
        if !foundShowAll {
            // Which title, and what the chapter section actually rendered — this assertion
            // failed for two very different reasons historically (wrong source, short
            // title), and the label alone cannot tell them apart.
            attach(app, name: "20-show-all-missing")
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "20-show-all-missing-hierarchy"
            dump.lifetime = .keepAlways
            add(dump)
        }
        XCTAssertTrue(foundShowAll, "a long title should show the 'Show all N chapters' row")
        showAll.tap()

        // Full-list screen: assert it appeared, exercise the sort toggle, then select-mode.
        XCTAssertTrue(app.otherElements["chapterListScreen"].waitForExistence(timeout: 8)
                      || app.navigationBars["Chapters"].waitForExistence(timeout: 8),
                      "the full chapter-list screen should open")

        // Queried by accessibility label, which is now a word rather than the tracked
        // uppercase typography the button draws (issue #90). The sort control keeps one
        // label and reports the order as its *value*, so the flip is a value change.
        let sort = app.buttons["Sort order"]
        if sort.waitForExistence(timeout: 5) {
            let before = sort.value as? String
            sort.tap()
            XCTAssertNotEqual(sort.value as? String, before,
                              "the sort toggle should flip its announced order")
        }

        let select = app.buttons["Select chapters"]
        XCTAssertTrue(select.waitForExistence(timeout: 5),
                      "the select control should be available on the full list")
        select.tap()
        XCTAssertTrue(app.buttons["Select All"].waitForExistence(timeout: 5),
                      "entering select mode should reveal the batch-action bar")
        app.buttons["Select All"].tap()
        let markRead = app.buttons["Mark Read"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 5))
        markRead.tap()
        // Select mode dismisses after a batch action.
        XCTAssertTrue(select.waitForExistence(timeout: 5),
                      "select mode should exit after Mark Read")
    }

    // `testADR0018WindBreakerAcquiresMalIdThroughSearch` is deleted (2026-09-28). It was the
    // one-off run for ADR-0018 amendment 1, written up in
    // `docs/superpowers/specs/2026-08-11-adr-0018-in-app-verification.md`, and it stopped
    // meaning anything once its refusal aged out (~2026-08-23): the seeded simulator now has
    // Wind Breaker in the library, so "Add to Library" never appears. Decision 3 stays covered
    // by `UpgradeAttemptMemoryTests.testAnUnmatchedWorkIsReopenedByLearningAnAuthoritativeId`.
    // Recover it from `git show 62301f9:MangaCartaUITests/MangaCartaUITests.swift`.

    /// **The seeding control for the ADR-0019 Amendment 1 run**, not a CI test.
    ///
    /// The run plants 80 WeebCentral Works into `works.json` rather than adding them by
    /// hand. The protocol
    /// (`docs/superpowers/specs/2026-08-11-adr-0019-amendment-1-run-protocol.md`) allows
    /// that only if the planted shape is *checked* against one the app really produces —
    /// so this mints exactly one, through `Add to Library`, and the run diffs its stored
    /// entry against a planted one before pass 1 starts.
    ///
    /// Asserts nothing about resolution. Its output is the file the app writes.
    func testMintOneWeebCentralWorkThroughTheRealPath() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        let weeb = app.buttons["Browse WeebCentral"]
        XCTAssertTrue(weeb.waitForExistence(timeout: 15), "the WeebCentral source chip should exist")
        weeb.tap()

        let card = app.buttons.matching(identifier: "mangaCoverCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60),
                      "WeebCentral should load cover cards — a failure here is Cloudflare, not logic")
        attach(app, name: "seed-01-weebcentral-home")
        card.tap()

        // Either library state proves the detail page rendered, which is all this assertion
        // ever meant. The test seeds a Work, so a title a previous run already added has
        // satisfied it — re-adding is not what is being verified.
        let addToLibrary = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Add to Library"))
            .firstMatch
        let anyLibraryToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Library"))
            .firstMatch
        XCTAssertTrue(anyLibraryToggle.waitForExistence(timeout: 45),
                      "should reach a WeebCentral detail page")
        attach(app, name: "seed-02-detail")
        if addToLibrary.exists {
            addToLibrary.tap()
            sleep(4)
        }
        attach(app, name: "seed-03-after-add")

        // Background to force the stores to flush; a run that just ends loses the write.
        XCUIDevice.shared.press(.home)
        sleep(3)
    }

    // MARK: - ADR-0018 Decision 1, in-app (2026-08-13)

    /// The two legs below verify **Decision 1** — *history carries the id its source published* —
    /// which `2026-08-11-adr-0018-in-app-verification.md` explicitly could not reach. Protocol and
    /// registered predictions: `docs/superpowers/specs/2026-08-13-adr-0018-decision-1-run-protocol.md`;
    /// the run itself is `…-adr-0018-decision-1-verified.md`.
    ///
    /// **Not CI tests.** They are instruments, pinned to the seeded simulator (`2A0D54DF-…`) and to
    /// live network. They assert what the UI can see; **the actual verification is the plist** each
    /// one leaves behind, because `ReadingEntry.malId` is never rendered.
    ///
    /// **Both fixtures are MangaDex titles on purpose.** The original leg B — a still-refused
    /// WeebCentral read, showing the scraped path writes `malId: nil` — was deleted on 2026-08-13
    /// because its fixture aged out with the 14-day refusal TTL (~2026-08-25) and it could not be
    /// re-pointed without hand-picking a fresh refusal each time. Its result is recorded in the run
    /// write-up; recover the test itself from `git show 7f434b8` if the scraped path needs
    /// re-checking, and expect to find a new fixture for it.
    ///
    /// **Run them in order, one at a time.** Leg C used to depend on leg B running between to
    /// displace Berserk from the top of history — `record` updates the newest entry in place when
    /// manga *and* chapter match, so an undisplaced resume writes nothing new. Leg C now displaces
    /// Berserk itself, which is what makes it standalone.
    ///
    /// Every one presses home before returning — `HistoryStore` throttles its writes and flushes on
    /// `.background`, and a run that just ends loses the entry it was verifying.

    /// **Leg A — the substantive one.** Berserk (`801513ba…`, `links.mal = 2`) reached through
    /// Search, so the `Manga` handed to the reader came off the API carrying its published id.
    /// Berserk is already in this sim's history from the pre-0018 seeding with `malId: null` under
    /// the same `mangaId`, so the before-state is on record rather than asserted.
    func testADR0018Decision1MangaDexReadWritesThePublishedId() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        app.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field should be present")
        field.tap()
        field.typeText("Berserk\n")

        // MangaDex returns `Boushoku no Berserk` (mal 113958) ahead of the target for this query.
        // Excluding it by label is load-bearing: the wrong hit would write a real id and read as a
        // pass.
        let target = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND NOT (label CONTAINS[c] %@)",
                        "Berserk", "Boushoku")
        ).element(boundBy: 0)
        XCTAssertTrue(target.waitForExistence(timeout: 25), "search should return Berserk itself")
        attach(app, name: "legA-01-search-results")
        target.tap()

        readFirstChapter(app, label: "legA")
    }

    /// **Leg C — the resume route.** Amendment 1 found `ReadingEntry.asManga` hardcoding
    /// `malId: nil`, which broke exactly this path. Resuming leg A's entry from History must
    /// prepend a **new** entry still carrying `mal 2`; the plist check is on the entry's UUID being
    /// new, since a silent in-place update would preserve the value while proving nothing.
    ///
    /// Reads *something other than Berserk* first, purely to displace Berserk from the top of
    /// history — an undisplaced resume matches on manga *and* chapter and updates in place, which
    /// would preserve `mal 2` while proving nothing. The displacer's own entry is not the subject
    /// of any assertion.
    ///
    /// **The displacer is whatever the seeded library provides, deliberately not a named title.**
    /// It used to be Junjou Romantica, searched for by name. That rotted (#134, cause 2):
    /// WeebCentral stopped carrying chapters for it, the detail page came up with `0 AVAILABLE`,
    /// nothing was displaced, and the leg failed for a reason that had nothing to do with what it
    /// measures. Repointing at another title only resets the clock until the next licensor pulls
    /// one. So `displaceUsingAnyLibraryTitle` walks the library grid instead and takes the first
    /// card that actually yields a readable chapter — the same requirement as before (**a
    /// displacer needs readable chapters, which is not the same as existing**), asserted against
    /// the fixture rather than against a name.
    func testADR0018Decision1ResumeFromHistoryKeepsTheId() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        // --- displacement, not the measurement ---
        displaceUsingAnyLibraryTitle(app, excluding: "Berserk", label: "legC-displacer")

        // --- the measurement ---
        // Relaunch rather than re-activate: `readFirstChapter` leaves the app backgrounded *in the
        // reader*, and the tab bar is not reachable from there. The relaunch is also what makes the
        // displacer's write durable before the resume reads it back.
        app.terminate()
        app.launch()

        app.buttons["History"].tap()
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND NOT (label CONTAINS[c] %@)",
                        "Berserk", "Boushoku")
        ).element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "leg A's Berserk entry should be in History")
        attach(app, name: "legC-01-history")
        row.tap()

        turnPagesAndBackground(app, label: "legC")
    }

    /// Matches a chapter row by what it *says*, not by what it draws.
    ///
    /// The row draws the stamp "CH·124", but #103 made the whole row one accessibility
    /// element labelled from `ChapterRowPresentation` — "Chapter 124, Title, September 1
    /// 2026, Unread" — because a middle dot is not a word VoiceOver can announce. XCUITest
    /// matches the label, so every query here must speak the sentence, not read the stamp.
    /// Three call sites drifted onto "CH·" for two weeks (#134); they go through here now.
    ///
    /// Passing a `number` anchors to the head of the sentence, and the trailing comma is
    /// what keeps chapter 12 from matching chapter 124.
    private static func chapterRow(number: String? = nil) -> NSPredicate {
        guard let number else {
            return NSPredicate(format: "label BEGINSWITH %@", "Chapter ")
        }
        return NSPredicate(format: "label BEGINSWITH %@", "Chapter \(number),")
    }

    /// Reads a chapter from **whatever the seeded library provides**, so that history's newest
    /// entry is no longer `excluding`'s. This is displacement only — nothing here is asserted
    /// about the title that ends up being used.
    ///
    /// Walks the library grid in order and takes the first card that opens a detail page with a
    /// chapter row on it, skipping any card whose title contains `excluding` and any card whose
    /// source currently carries no chapters. That skip is the whole point: a title can be alive,
    /// searchable and openable and still read `0 AVAILABLE` because its source dropped it (#134,
    /// cause 2), and a displacer that does not displace fails the measurement downstream for a
    /// reason that has nothing to do with ADR-0018.
    ///
    /// Fails only when *no* library title anywhere yields a chapter — which is a real finding
    /// about the app or the fixture, not catalog rot.
    private func displaceUsingAnyLibraryTitle(_ app: XCUIApplication,
                                              excluding: String,
                                              label: String) {
        app.tabBars.buttons["Library"].tap()
        let cards = app.buttons.matching(identifier: "libraryCoverCard")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20),
                      "the seeded library should hold at least one title — hierarchy:\n"
                      + "\(app.debugDescription)")
        attach(app, name: "\(label)-00-library")

        var skipped: [String] = []
        for index in 0..<cards.count {
            let card = cards.element(boundBy: index)
            guard card.exists else { continue }
            let title = card.label
            if title.range(of: excluding, options: .caseInsensitive) != nil {
                skipped.append("\(title) [the subject]")
                continue
            }

            card.tap()
            let chapter = app.buttons.matching(Self.chapterRow()).element(boundBy: 0)
            // Shorter than `readFirstChapter`'s 45s: this is a poll over candidates, and a
            // title with no chapters costs the full wait before the next one is tried.
            if chapter.waitForExistence(timeout: 25) {
                attach(app, name: "\(label)-01-detail")
                chapter.tap()
                turnPagesAndBackground(app, label: label)
                return
            }
            skipped.append("\(title) [no chapters]")
            popToRoot(app)
        }

        XCTFail("no library title yielded a readable chapter, so nothing displaced "
                + "\(excluding) from the top of history; tried: \(skipped)")
    }

    /// Pops an open detail page back to the tab's root.
    private func popToRoot(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists && back.isHittable {
            back.tap()
            _ = app.buttons.matching(identifier: "libraryCoverCard")
                .firstMatch.waitForExistence(timeout: 15)
        }
    }

    /// Opens the first chapter row on a detail page and reads far enough to commit.
    private func readFirstChapter(_ app: XCUIApplication, label: String) {
        let chapter = app.buttons.matching(Self.chapterRow()).element(boundBy: 0)
        XCTAssertTrue(chapter.waitForExistence(timeout: 45),
                      "the detail page should list a chapter — hierarchy:\n\(app.debugDescription)")
        attach(app, name: "\(label)-02-detail")
        chapter.tap()

        turnPagesAndBackground(app, label: label)
    }

    /// Turns pages in both directions — the reader's advancing direction depends on the stored
    /// R→L setting, and a swipe the wrong way at page 0 moves nothing — then waits out
    /// `HistoryStore`'s 2s throttle and backgrounds to force the flush.
    private func turnPagesAndBackground(_ app: XCUIApplication, label: String) {
        sleep(8)
        attach(app, name: "\(label)-03-reader-opened")
        for _ in 0..<3 { app.swipeLeft(velocity: .fast); usleep(700_000) }
        for _ in 0..<3 { app.swipeRight(velocity: .fast); usleep(700_000) }
        sleep(4)
        attach(app, name: "\(label)-04-reader-after-turns")

        XCUIDevice.shared.press(.home)
        sleep(4)
    }

    // MARK: - ADR-0019, the gate leg (2026-08-13) — REMOVED 2026-08-13
    //
    // The two seeding tests that lived here (`testADR0019SeedGateSubject`,
    // `testADR0019SeedGateControl`) and their `addFirstResultToLibrary` helper are deleted.
    // They asserted nothing — they only pushed two fixtures into the library so the drain that
    // followed under `simctl launch` had something to attempt — and that drain is done and
    // written up in `docs/superpowers/specs/2026-08-13-adr-0019-gate-verified.md`. Re-running
    // them would seed the same two Works into an already-seeded sim.
    //
    // Recover them from `git show 7f434b8` if a second gate run is ever needed. Note the finding
    // that killed the first attempt: a fresh control is not enough, it has to be a Work this app
    // has already refused, and its TTL suppression has to be lifted or the drain asks nothing.

    /// The "For You" rail still populates end-to-end with the composite (tag + MAL)
    /// provider wired in. Network-dependent: a flake is API/seed availability, not a
    /// logic bug. The rail is hidden until there's enough reading signal, so this asserts
    /// the app launches to a populated Home and — if a "For You" rail is present — it has
    /// at least one card.
    func testForYouRailPopulatesWithCompositeProvider() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()
        // Home must load content at all (proves the composite provider didn't break Home).
        let anyCard = app.buttons.matching(identifier: "mangaCoverCard").firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 25), "Home should load cover cards")

        // If the personalized rail is showing, it must have a card under it.
        let forYou = app.staticTexts["For You"]
        if forYou.waitForExistence(timeout: 5) {
            let card = app.buttons.matching(identifier: "mangaCoverCard").firstMatch
            XCTAssertTrue(card.exists, "the For You rail should render at least one card")
        }
    }

    // MARK: - ADR-0020 in-app run

    /// One seed for the widening regression: a MangaDex title to search for, the substring
    /// that identifies its result cell, and the cards its More Like This rail must show.
    ///
    /// `cards` are the **MangaDex display titles** of targets that ADR-0020's widening
    /// recovered on 2026-08-19 — each one a row whose MAL spelling misses and whose MangaDex
    /// spelling differs. They are the user-visible effect of the ADR: without widening these
    /// cards are simply absent from the rail.
    private struct ReverseSeed {
        let query: String
        let match: String
        let cards: [String]
    }

    /// The seed list registered in
    /// `docs/superpowers/specs/2026-08-19-adr-0020-in-app-run-protocol-amendment-1.md`.
    /// **Do not edit this array in response to a run.** Claim 6 says under-delivery is
    /// answered with more seeds drawn by the published rule in a further amendment
    /// committed before the re-run, never by swapping out the rows that disappointed.
    ///
    /// *Never Give Up*'s second registered target (Teppen!, MAL 10776) is **not** listed as a
    /// card: it never appeared in the discharging run, which reported it as never-observed
    /// rather than as a loss. Asserting on it here would encode a row we have never seen.
    private static let adr0020Seeds: [ReverseSeed] = [
        .init(query: "Vagabond", match: "Vagabond", cards: ["Mugen no Junin"]),
        .init(query: "Golden Kamuy", match: "Golden Kamuy",
              cards: ["Mugen no Junin", "RED: Living On the Edge"]),
        .init(query: "Meitantei Conan", match: "Meitantei Conan",
              cards: ["Kindaichi Case Files", "Q.E.D"]),
        .init(query: "Angel Sanctuary", match: "Tenshi Kinryouku", cards: ["X (CLAMP)"]),
        .init(query: "Kimi wa Pet", match: "Kimi wa Pet", cards: ["Futago", "The One"]),
        .init(query: "Eden: It's an Endless World", match: "Eden",
              cards: ["Neon Genesis Evangelion"]),
        .init(query: "Blood+ Adagio", match: "BLOOD+", cards: ["BLOOD+"]),
        .init(query: "Ai wo Utau yori Ore ni Oborero", match: "Oborero",
              cards: ["Kaikan Phrase"]),
        .init(query: "Kaichou-san Chi no Koneko", match: "Kaichou-san",
              cards: ["Cosplay Animal"]),
        .init(query: "Hotaru no Hikari", match: "Hotaru no Hikari",
              cards: ["Lifetime of a Man"]),
        .init(query: "Ugly Duckling to Swan", match: "Swan", cards: ["Ahiru no Oujisama"]),
        .init(query: "Never Give Up", match: "Never Give Up", cards: ["The One"]),
        .init(query: "Kaikan Phrase", match: "Kaikan", cards: ["Love Monster"]),
    ]

    /// Drives the thirteen registered seeds through **Search** and asserts that the cards
    /// ADR-0020's widening recovers actually appear in each seed's More Like This rail.
    ///
    /// ADR-0020: `docs/adr/0020-widening-the-search-input-on-the-reverse-resolution-path.md`.
    /// The discharging run is
    /// `docs/superpowers/specs/2026-08-19-adr-0020-in-app-run-enriched.md`.
    ///
    /// **This asserts cards, not log lines.** The run that discharged Decision 5 read its
    /// claims off a debug instrument inside `MALReverseResolver`; that instrument is deleted
    /// now the run is written up, and what survives it is this: fourteen rows that miss on
    /// MAL's spelling and are carried by MangaDex under another one. If widening regresses,
    /// these cards vanish from the rail and this test says which ones.
    ///
    /// **The floor is 10 of 14, not 14 of 14, and that is deliberate.** Both MAL and MangaDex
    /// are live here, and MAL's recommendation ordering shifts — a target can leave the top 8
    /// that `MoreLikeThisProvider.topRecommendations` takes without anything in this app
    /// changing. A hard all-or-nothing assertion would turn that into a red build. Losing a
    /// third of the set is not ordering drift.
    func testADR0020WidenedCardsAppearInTheRail() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        var seedsMissed: [String] = []
        var railsReached: [String] = []
        var railsUnreached: [String] = []
        var cardsFound: [String] = []
        var cardsMissing: [String] = []

        for seed in Self.adr0020Seeds {
            // Always start a seed from the Search tab with no detail page underneath. An
            // earlier revision skipped this on the `continue` paths, so one seed that failed
            // to reach its rail left its detail page open — and the next iteration found two
            // "Search" buttons, the tab and the page's own, and failed on ambiguity rather
            // than on anything to do with widening.
            returnToSearchRoot(app)
            searchTab(app).tap()
            let field = app.searchFields.firstMatch
            guard field.waitForExistence(timeout: 15) else {
                seedsMissed.append("\(seed.query) [no search field]")
                continue
            }
            field.tap()
            // Clear whatever the previous seed left behind; the field persists across tabs.
            if let existing = field.value as? String, !existing.isEmpty,
               existing != "Search titles" {
                field.buttons.firstMatch.tap()
            }
            field.typeText(seed.query + "\n")

            let result = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", seed.match))
                .element(boundBy: 0)
            guard result.waitForExistence(timeout: 30) else {
                seedsMissed.append("\(seed.query) [no result]")
                continue
            }
            result.tap()

            let libraryToggle = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Library")).firstMatch
            guard libraryToggle.waitForExistence(timeout: 25) else {
                seedsMissed.append("\(seed.query) [detail page never appeared]")
                continue
            }

            // Scroll until the rail's first cell is **hittable**, not until its header
            // `exists`. XCUITest reports a lazily-built element as existing while it is still
            // below the fold, so the discharging run's screenshots were all framed at the top
            // of the detail page and showed no cards at all. Hittability is what "on screen"
            // actually means here, and it is also what makes the card assertions below
            // meaningful rather than accidental.
            let header = app.staticTexts["More Like This"]
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline && !railIsOnScreen(app, header: header) {
                app.swipeUp(velocity: .fast)
                usleep(700_000)
            }
            // Not reaching the rail is a **scroll budget** problem, not a navigation one:
            // a seed with hundreds of chapters can outrun 45 seconds of swiping. The rail is
            // built either way, so the card checks below still mean something — they just
            // rest on `exists` rather than on a picture. Kept separate from `seedsMissed` so
            // a long page never reads as a broken app.
            if railIsOnScreen(app, header: header) {
                railsReached.append(seed.query)
            } else {
                railsUnreached.append(seed.query)
            }

            for card in seed.cards {
                let cell = app.buttons
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", card))
                    .firstMatch
                // The rail is horizontally scrollable and the target may sit off its right
                // edge; `exists` is the right predicate for membership, hittability was the
                // question for the rail as a whole.
                if cell.waitForExistence(timeout: 10) {
                    cardsFound.append("\(seed.query) → \(card)")
                } else {
                    cardsMissing.append("\(seed.query) → \(card)")
                }
            }

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "seed-\(seed.query)-rail"
            shot.lifetime = .keepAlways
            add(shot)
        }

        // A run where navigation broke must never read as a run where widening had nothing
        // to do, so the frame is asserted before the cards are.
        XCTAssertTrue(seedsMissed.isEmpty,
                      "seeds whose detail page never opened: \(seedsMissed)")
        XCTAssertGreaterThanOrEqual(
            railsReached.count, 10,
            "rails brought on screen \(railsReached.count)/13; outran the scroll budget: \(railsUnreached)")
        XCTAssertGreaterThanOrEqual(
            cardsFound.count, 10,
            "widened cards found \(cardsFound.count)/14; missing: \(cardsMissing)")
    }

    /// The rail the ADR-0020 AniList-arm run was driven through
    /// (`docs/superpowers/specs/2026-08-20-adr-0020-anilist-arm-results.md`).
    ///
    /// What survives the run is the regression it needs anyway: the For You rail — which is
    /// where the AniList pool's reverse-resolved candidates surface — is built and reaches
    /// the screen with cards on it. The instrument that scored the run is gone, so this
    /// asserts the visible thing rather than the path.
    ///
    /// **Preconditions, none of them assertable from here:** a seeded library (the pool
    /// gate needs 3+ AniList-resolved Works) plus live AniList and MangaDex. Run it through
    /// `-only-testing:`, the way the other live tests in this file are run; CI runs unit
    /// tests only.
    func testForYouRailReachesTheScreenWithCards() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launch()

        // The rail is built from a live AniList query plus up to 12 MangaDex searches, so
        // it arrives well after Home does. Waiting on the header's *existence* first is
        // deliberate: it is the signal the section was built at all, which is what tells an
        // empty log apart from a pool that never ran.
        let header = app.staticTexts["For You"]
        XCTAssertTrue(header.waitForExistence(timeout: 120),
                      "the For You rail never appeared; the pool did not run, so an empty "
                      + "log would say nothing about widening")

        // Then scroll until it is **hittable**. `exists` is true for a lazily-built element
        // still below the fold — the bug that made every screenshot in the MAL arm's
        // discharging run useless.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && !railIsOnScreen(app, header: header) {
            app.swipeUp(velocity: .fast)
            usleep(700_000)
        }
        XCTAssertTrue(railIsOnScreen(app, header: header),
                      "the For You rail never reached the screen")

        // Claim 4's visual half: the card, on screen, in the rail the widened queries fed.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "adr0020-anilist-arm-for-you-rail"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(app.buttons.matching(identifier: "mangaCoverCard")
                        .allElementsBoundByIndex.contains { $0.isHittable },
                      "the For You rail reached the screen with no cards on it")
    }

    /// True once the More Like This rail is actually on screen — either its header or one of
    /// its cells is **hittable**, not merely `exists`.
    ///
    /// Both halves are needed. A card alone is the strong signal, but a title with no
    /// recommendations renders the section header over an empty rail, and treating that as
    /// "not reached" would spin the scroll loop to its deadline and then report a navigation
    /// failure for what is really an empty rail. The card assertions tell those apart.
    private func railIsOnScreen(_ app: XCUIApplication, header: XCUIElement) -> Bool {
        if header.isHittable { return true }
        return app.buttons.matching(identifier: "mangaCoverCard")
            .allElementsBoundByIndex.contains { $0.isHittable }
    }

    /// The Search tab. A detail page carries its own "Search" affordance, so an unqualified
    /// `app.buttons["Search"]` is ambiguous whenever one is open; the tab is the bottom-most
    /// match.
    private func searchTab(_ app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", "Search"))
            .allElementsBoundByIndex
        return matches.max(by: { $0.frame.minY < $1.frame.minY }) ?? app.buttons["Search"]
    }

    /// Pops any open detail page so the next seed starts from a known state.
    private func returnToSearchRoot(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists && back.isHittable {
            back.tap()
            _ = app.searchFields.firstMatch.waitForExistence(timeout: 15)
        }
    }

}

// MARK: - Task 12's remaining manual checks
//
// Offline completion, relaunch persistence, foreground retry, the sync toggle, sign-out
// cleanup, and signed-out reading. All six run on the **seeded stand-in account**
// (`AppComposition.malUITestProfile`, id 1_000_001) rather than this device's real one, and
// two independent things keep them off a real MyAnimeList list:
//
// 1. the seeded credential is the string `uitest-access`, which cannot authenticate; and
// 2. `-uitest-mal-offline` swaps the authenticated client's transport for one that always
//    fails, so no request leaves the process at all.
//
// They are not gated: CI runs `-only-testing:MangaCartaTests`, so this target never runs
// there, and every other live UI test in this file is ungated for the same reason. Each drives
// the real reader over the network, so run them by name rather than as part of a whole-target
// sweep.
extension MangaCartaUITests {

    /// **Signed-out reading is unchanged** (MAL plan, Task 12).
    ///
    /// The claim is a negative one — that an app with no MyAnimeList account reads exactly as
    /// it did before the feature — so the test drives a whole chapter to its last page and
    /// then confirms Settings still offers only **Sign in**. The queue assertion that pairs
    /// with it is made outside the process, against `mal-progress-outbox.json`: a UI test
    /// cannot see the app's container.
    func testSignedOutReadingIsUnchanged() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launchArguments += ["-uitest-mal-signed-out", "-uitest-mal-reset-outbox",
                                "-uitest-source", "mangadex"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let pages = try readFirstLibraryChapterToItsLastPage(app, screenshotPrefix: "40-signed-out")
        XCTAssertGreaterThan(pages, 1, "a one-page chapter would not prove paging")

        returnToTabBar(app)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["MyAnimeList"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sign in"].exists,
                      "reading while signed out must not have signed anyone in")
        XCTAssertFalse(syncQueue(in: app).exists,
                       "signed out, a completed chapter must not produce a queue summary")
        attach(app, name: "41-signed-out-settings-after-reading")
    }

    /// **Offline completion, and that it survives a relaunch** (MAL plan, Task 12).
    ///
    /// One test rather than two because the second claim is only meaningful about an item the
    /// first one queued: the queue has to be observed before the relaunch to know what the
    /// relaunch preserved.
    func testOfflineCompletionQueuesAndSurvivesRelaunch() throws {
        let arguments = ["-uitest-mal-state", "signed-in",
                         "-uitest-mal-offline",
                         "-uitest-source", "mangadex"] + Self.liveRepositoryArguments

        let app = XCUIApplication()
        app.launchArguments += ["-uitest-mal-reset-outbox"] + arguments
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        _ = try readFirstLibraryChapterToItsLastPage(app, screenshotPrefix: "50-offline")

        // `HistoryStore` throttles its writes and the outbox flushes on `.background`; a run
        // that goes straight to Settings can beat its own persistence.
        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()

        returnToTabBar(app)
        app.tabBars.buttons["Settings"].tap()
        let queue = syncQueue(in: app)
        XCTAssertTrue(queue.waitForExistence(timeout: 15),
                      "a completion with MyAnimeList unreachable must be queued, not dropped")
        let queuedBefore = queue.value as? String ?? ""
        XCTAssertTrue(queuedBefore.contains("waiting to send"),
                      "expected a pending line, got '\(queuedBefore)'")
        attachSettingsEvidence(app, name: "51-offline-queued")

        // The relaunch. `terminate()` rather than a second `launch()` on a live app, so this
        // is a genuine cold start reading the queue back off disk.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments += arguments
        relaunched.launch()
        relaunched.tabBars.buttons["Settings"].tap()

        let queueAfter = syncQueue(in: relaunched)
        XCTAssertTrue(queueAfter.waitForExistence(timeout: 15),
                      "the queued update must survive a relaunch")
        XCTAssertEqual(queueAfter.value as? String, queuedBefore,
                       "the relaunched queue should be the same queue, not a rebuilt one")
        attachSettingsEvidence(relaunched, name: "52-offline-queued-after-relaunch")
    }

    /// **Turning sync off stops queueing, and turning it back on resumes** (MAL plan, Task 12).
    ///
    /// The interesting half is the first: `MALProgressCoordinator.chapterCompleted` returns
    /// early when sync is off, so a chapter finished in that window is never queued and never
    /// arrives late. Reading the *same* chapter again after re-enabling is what separates
    /// "not queued" from "queued but not shown".
    func testDisablingSyncStopsQueueingAndReenablingResumes() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launchArguments += ["-uitest-mal-state", "signed-in",
                                "-uitest-mal-offline",
                                "-uitest-mal-reset-outbox",
                                "-uitest-source", "mangadex"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["Sync reading progress"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the sync toggle should be in Settings")
        XCTAssertEqual(toggle.value as? String, "1", "the seeded account starts with sync on")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0", "the toggle should turn sync off")
        attachSettingsEvidence(app, name: "60-sync-disabled")

        _ = try readFirstLibraryChapterToItsLastPage(app, screenshotPrefix: "61-sync-off")
        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()

        returnToTabBar(app)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(syncQueue(in: app).exists,
                       "a chapter finished with sync off must not be queued")
        attachSettingsEvidence(app, name: "62-sync-off-nothing-queued")

        // Back on. The same chapter is already complete, so re-reading it is what proves the
        // path is live again rather than merely that the toggle flipped.
        let toggleAgain = app.switches["Sync reading progress"]
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 10))
        toggleAgain.tap()
        XCTAssertEqual(toggleAgain.value as? String, "1")
        attachSettingsEvidence(app, name: "63-sync-reenabled")

        _ = try readFirstLibraryChapterToItsLastPage(app, screenshotPrefix: "64-sync-on")
        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()

        returnToTabBar(app)
        app.tabBars.buttons["Settings"].tap()
        let resumedQueue = syncQueue(in: app)
        XCTAssertTrue(resumedQueue.waitForExistence(timeout: 15),
                      "a completion after re-enabling sync must be queued")
        XCTAssertTrue((resumedQueue.value as? String ?? "").contains("waiting to send"),
                      "re-enabled sync should resume the normal delivery path")
        attachSettingsEvidence(app, name: "65-sync-on-queued")
    }

    /// **Signing out clears the account and its queued work** (MAL plan, Task 12).
    ///
    /// Runs against the seeded stand-in credential, so this signs nothing real out. The queue
    /// is loaded first, because "sign-out clears the queue" is a claim about a queue that
    /// exists.
    func testSignOutClearsTheAccountAndItsQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launchArguments += ["-uitest-mal-state", "signed-in",
                                "-uitest-mal-offline",
                                "-uitest-mal-reset-outbox",
                                "-uitest-source", "mangadex"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        _ = try readFirstLibraryChapterToItsLastPage(app, screenshotPrefix: "70-before-signout")
        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()

        returnToTabBar(app)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(syncQueue(in: app).waitForExistence(timeout: 15),
                      "there should be something queued to lose")
        attachSettingsEvidence(app, name: "71-queued-before-signout")

        let signOut = app.buttons["Sign out on this device"]
        for _ in 0..<8 where !signOut.isHittable {
            app.swipeUp()
            usleep(400_000)
        }
        XCTAssertTrue(signOut.isHittable, "the sign-out button should be reachable")
        signOut.tap()

        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 15),
                      "signing out should return the section to its signed-out state")
        XCTAssertFalse(syncQueue(in: app).exists,
                       "sign-out must clear the queued updates, not orphan them")
        XCTAssertFalse(app.switches["Sync reading progress"].exists,
                       "signed out, no account controls remain")
        attachSettingsEvidence(app, name: "72-after-signout")
    }

    /// **Foreground retry** (MAL plan, Task 12).
    ///
    /// Once the persisted backoff is eligible, backgrounding and returning must make the
    /// coordinator re-attempt queued work instead of leaving it dormant until another event.
    ///
    /// What this observes is that the attempt *happens* (the item's retry count advances and
    /// the section keeps reporting it as pending). That it *succeeds* against a real list was
    /// proved separately by `testLiveHorimiyaCompletionPushesProgress`; here the credential is
    /// a stand-in and cannot deliver by construction.
    func testForegroundingRetriesQueuedWork() throws {
        let app = XCUIApplication()
        app.launchArguments += Self.liveRepositoryArguments
        app.launchArguments += ["-uitest-mal-state", "signed-in",
                                "-uitest-mal-offline",
                                "-uitest-mal-reset-outbox",
                                "-uitest-source", "mangadex"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        _ = try readFirstLibraryChapterToItsLastPage(app, screenshotPrefix: "80-foreground-retry")
        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()

        returnToTabBar(app)
        app.tabBars.buttons["Settings"].tap()
        let queue = syncQueue(in: app)
        XCTAssertTrue(queue.waitForExistence(timeout: 15))
        attachSettingsEvidence(app, name: "81-queued")

        // Background past the initial one-minute retry window, then return. Foregrounding
        // starts a fresh drain, which should attempt the now-eligible item immediately. The
        // persisted retry-count assertion is made outside the process after this run.
        XCUIDevice.shared.press(.home)
        sleep(65)
        app.activate()

        XCTAssertTrue(queue.waitForExistence(timeout: 15),
                      "the item must survive a foreground retry that could not deliver")
        attachSettingsEvidence(app, name: "82-after-foreground")
    }

    // MARK: Shared driver

    private func syncQueue(in app: XCUIApplication) -> XCUIElement {
        // SwiftUI's combined accessibility element is projected as a StaticText on the
        // current simulator runtime, but that implementation detail is not part of the UI's
        // semantic contract. Match the explicit label regardless of XCTest element type.
        app.descendants(matching: .any)["Sync queue"]
    }

    /// Walks back out of the reader and the detail stack until the tab bar is on screen.
    /// The reader hides it, so every check that reads a chapter and then wants Settings has
    /// to come back up first.
    private func returnToTabBar(_ app: XCUIApplication) {
        for _ in 0..<10 {
            if app.tabBars.buttons["Settings"].exists { return }

            // The reader hides the navigation bar and the tab bar, so its own close button is
            // the only way out — and the chrome holding it is hidden until the screen is
            // tapped.
            let close = app.buttons["readerCloseButton"]
            if close.exists && close.isHittable {
                close.tap()
                usleep(1_200_000)
                continue
            }
            let back = app.navigationBars.buttons.firstMatch
            if back.exists && back.isHittable {
                back.tap()
                usleep(1_200_000)
                continue
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            usleep(1_200_000)
        }
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10),
                      "should be able to get back to the tab bar after reading")
    }

    /// The title these checks read. Named rather than "whatever is first in the library"
    /// because the seeded library's first card is Junjou Romantica **on WeebCentral**, and a
    /// second source's detail page is a variable none of these checks are about — the same
    /// inherited-source trap that produced Issue #81.
    private static let manualCheckTitle = "Chainsaw Man"
    private static let manualCheckChapterNumber = "97"

    /// Opens `manualCheckTitle` from the library, reads its first chapter to the last page,
    /// and returns the page count. Factored out because five checks above differ only in what
    /// they assert afterwards — the completion itself is the same act every time.
    @discardableResult
    // swiftlint:disable:next cyclomatic_complexity
    private func readFirstLibraryChapterToItsLastPage(
        _ app: XCUIApplication,
        screenshotPrefix: String
    ) throws -> Int {
        app.tabBars.buttons["Library"].tap()

        // Selecting a tab preserves that tab's NavigationStack. A second traversal in the
        // same test therefore returns to the prior detail page, not necessarily the grid.
        let anyCard = app.buttons.matching(identifier: "libraryCoverCard").firstMatch
        for _ in 0..<6 where !anyCard.exists {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists && back.isHittable else { break }
            back.tap()
            usleep(800_000)
        }

        let card = app.buttons.matching(identifier: "libraryCoverCard")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", Self.manualCheckTitle))
            .firstMatch
        for _ in 0..<8 where !card.exists {
            app.swipeUp(velocity: .fast)
            usleep(400_000)
        }
        XCTAssertTrue(card.waitForExistence(timeout: 20),
                      "\(Self.manualCheckTitle) should be in the seeded library")
        // `tap()` on the element, not a normalized coordinate: the grid re-lays out as covers
        // stream in, and a coordinate computed from the matched frame lands on whichever cell
        // has moved into that spot. That is how an earlier run of this read Made in Abyss
        // while asserting nothing about which title it had opened.
        card.tap()

        let libraryToggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Library"))
            .firstMatch
        XCTAssertTrue(libraryToggle.waitForExistence(timeout: 25), "should reach the detail page")
        XCTAssertTrue(app.staticTexts[Self.manualCheckTitle].waitForExistence(timeout: 15),
                      "should have opened \(Self.manualCheckTitle), not another library title")

        // Chapters 230–232 are listed but currently have no pages on MangaDex. Pin this
        // exercise to a chapter whose at-home payload is known to contain readable pages
        // instead of taking whichever metadata row is newest.
        // The row's read state and resume marker live in its accessibility *value*, not its
        // label, so anchoring to the head of the label is safe.
        let chapter = app.buttons.matching(
            Self.chapterRow(number: Self.manualCheckChapterNumber)
        )
            .firstMatch
        _ = chapter.waitForExistence(timeout: 25)   // chapters arrive over the network
        for _ in 0..<10 where !chapter.exists {
            app.swipeUp(velocity: .fast)
            usleep(800_000)
        }
        XCTAssertTrue(chapter.waitForExistence(timeout: 20),
                      "the title should list chapter \(Self.manualCheckChapterNumber) — hierarchy:\n\(app.debugDescription)")

        // Completion notifications are edge-triggered: HistoryStore emits only when a
        // chapter moves from incomplete to complete. Reset through the real UI so this
        // manual exercise remains repeatable after a failed run that already reached the
        // final page, without adding a test-only history mutation to the app.
        chapter.press(forDuration: 1)
        let markUnread = app.buttons["Mark as unread"]
        if markUnread.waitForExistence(timeout: 3) {
            markUnread.tap()
        } else {
            XCTAssertTrue(app.buttons["Mark as read"].exists,
                          "the chapter context menu should expose its read state")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        }

        attach(app, name: "\(screenshotPrefix)-chapter-row")
        chapter.tap()

        // Reader chrome is hidden until tapped, so the page indicator does not exist yet.
        let indicator = app.staticTexts["readerPageIndicator"]
        for _ in 0..<12 where !indicator.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            usleep(1_500_000)
        }
        XCTAssertTrue(
            indicator.waitForExistence(timeout: 30),
            "the reader should load pages — hierarchy:\n\(app.debugDescription)"
        )
        guard let pages = Self.indicatorTotal(indicator.label) else {
            XCTFail("could not read a page count from '\(indicator.label)'")
            return 0
        }
        XCTAssertGreaterThan(pages, 1, "a one-page chapter would not prove paging")

        // Reading direction is a property of the title, so probe rather than assume: R→L is
        // reversed page order here, not a mirror. Probing backwards, because the reader
        // restores the last position — a chapter already read opens *on* its final page, and
        // a forward probe there advances into the next chapter instead.
        let before = Self.indicatorCurrent(indicator.label) ?? 1
        app.swipeRight()
        usleep(700_000)
        let backwardIsSwipeRight = (Self.indicatorCurrent(indicator.label) ?? before) < before

        // To the first page, so the run that follows is a real traversal of the whole chapter
        // rather than whatever the restored position left.
        for _ in 0..<(pages + 5) {
            if (Self.indicatorCurrent(indicator.label) ?? 1) <= 1 { break }
            if backwardIsSwipeRight { app.swipeRight() } else { app.swipeLeft() }
            usleep(400_000)
        }
        XCTAssertEqual(Self.indicatorCurrent(indicator.label), 1,
                       "should be able to get back to the first page, indicator '\(indicator.label)'")

        // And forward to the last one. Reaching it is what records the completion.
        for _ in 0..<(pages + 5) {
            if (Self.indicatorCurrent(indicator.label) ?? 0) >= pages { break }
            if backwardIsSwipeRight { app.swipeLeft() } else { app.swipeRight() }
            usleep(400_000)
        }
        XCTAssertEqual(Self.indicatorCurrent(indicator.label), pages,
                       """
                       the chapter must reach its final page — anything less is not a \
                       completion. Indicator '\(indicator.label)', pages \(pages)
                       """)
        attach(app, name: "\(screenshotPrefix)-last-page")
        return pages
    }
}
