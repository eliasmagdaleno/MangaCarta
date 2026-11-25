//
//  WebtoonGeometryTests.swift
//  MangaCartaTests
//
//  The vertical reader's pure pieces: what a measurement means (`stripPosition`) and
//  when it is allowed to reach the store (`recordAction`). ADR-0014 decisions 5 and 9.
//
//  Frames here are **viewport-relative**, as they are in the reader: the viewport top is
//  y = 0 and a strip that has scrolled above it has a negative `minY`.
//

import XCTest
@testable import MangaCarta

final class WebtoonGeometryTests: XCTestCase {

    private let viewport = CGRect(x: 0, y: 0, width: 390, height: 800)

    /// A strip `height` tall whose top sits `minY` from the viewport top.
    private func strip(_ minY: CGFloat, _ height: CGFloat, decoded: Bool = true) -> StripFrame {
        StripFrame(rect: CGRect(x: 0, y: minY, width: 390, height: height), isDecoded: decoded)
    }

    // MARK: - Capture: the ordinary case

    /// The whole point of the ADR: a webtoon strip is long, and the position inside it is
    /// what a page index cannot say.
    func testTheStripUnderTheViewportTopGivesThePageAndHowFarIntoIt() {
        let position = stripPosition(frames: [5: strip(-1500, 3000)], viewport: viewport)

        XCTAssertEqual(position?.page, 5)
        XCTAssertEqual(position?.fraction ?? 0, 0.5, accuracy: 0.0001)
    }

    /// The fraction is a ratio, so the same content position reports the same value at any
    /// width — which is what lets it survive rotation and travel between devices.
    func testTheFractionIsScaleInvariant() {
        let tall = stripPosition(frames: [2: strip(-1500, 3000)], viewport: viewport)
        let short = stripPosition(frames: [2: strip(-750, 1500)], viewport: viewport)

        XCTAssertEqual(tall?.fraction ?? 0, short?.fraction ?? -1, accuracy: 0.0001)
    }

    // MARK: - Capture: the four holes

    /// Hole 1. Restore fires before any row has reported a frame, and an unmeasured strip
    /// is *unknown* — not "the top". Returning `(0, 0)` here would be harmless only
    /// because `record` is monotonic, which is a property of another type.
    func testNothingMeasuredReportsNothing() {
        XCTAssertNil(stripPosition(frames: [:], viewport: viewport))
    }

    /// Hole 2. Rubber-banding at the top of the chapter is not a position.
    func testOverscrollAboveTheFirstStripIsTheTopOfIt() {
        let position = stripPosition(frames: [0: strip(120, 3000)], viewport: viewport)

        XCTAssertEqual(position, ReadingPosition(page: 0, fraction: 0))
    }

    /// Hole 3. Past the last strip the viewport top is in the interstitial, the end mark or
    /// the 50pt loader. Completion is unaffected — `finished` only asks
    /// `page >= pageCount - 1`, which entering the last strip already satisfied — but the
    /// value has to keep moving instead of freezing partway down the final strip.
    func testPastTheLastStripHoldsTheLastStripJustUnderOne() {
        let frames = [0: strip(-6000, 3000), 1: strip(-3000, 3000)]

        let position = stripPosition(frames: frames, viewport: viewport)

        XCTAssertEqual(position?.page, 1)
        XCTAssertEqual(position?.fraction ?? 0, maxStripFraction, accuracy: 0.0001)
    }

    /// Hole 4, the one the second grill added. A `WebtoonPage` is a 460pt placeholder until
    /// its image decodes, so a fraction measured against it describes a layout about to be
    /// replaced — and capture *persists* what it measures. A cold-cache flick would
    /// otherwise record 60% into a 460pt strip and resume 1800pt into the real 3000pt one,
    /// which is decision 7's rejected "skips content" failure arriving through capture.
    func testAStripThatHasNotDecodedReportsNothing() {
        let frames = [7: strip(-276, 460, decoded: false)]

        XCTAssertNil(stripPosition(frames: frames, viewport: viewport))
    }

    /// The gate has to hold on the past-the-end path too, or placeholder fractions come
    /// back in through that door.
    func testPastTheLastStripSkipsAnUndecodedTail() {
        let frames = [0: strip(-3460, 3000), 1: strip(-460, 460, decoded: false)]

        let position = stripPosition(frames: frames, viewport: viewport)

        XCTAssertEqual(position?.page, 0)
        XCTAssertEqual(position?.fraction ?? 0, maxStripFraction, accuracy: 0.0001)
    }

    /// A row that has been realized but not yet laid out has no height, and a ratio into it
    /// is a division by zero. That is "not measured", not "the top".
    func testAStripWithNoHeightYetIsNotAMeasurement() {
        XCTAssertNil(stripPosition(frames: [2: strip(0, 0)], viewport: viewport))
    }

    // MARK: - Capture: the range

    /// `1.0` would address slot 50 of a `0..<50` grid, so the clamp lives where the value is
    /// made rather than only where it is spent.
    func testTheFractionNeverReachesOne() throws {
        let position = stripPosition(frames: [3: strip(-2999.7, 3000)], viewport: viewport)

        let fraction = try XCTUnwrap(position?.fraction)
        XCTAssertLessThan(fraction, 1)
        XCTAssertEqual(Int(fraction * Double(stripAnchorSlots)), stripAnchorSlots - 1)
    }

    // MARK: - Restore: what a completed load should do

    /// The bug this exists for: a `ScrollView` keeps its content offset when the pages under
    /// it are replaced, so landing in a new chapter with nothing saved leaves the reader at
    /// the bottom of the chapter they just left — which puts the end-of-chapter loader back
    /// on screen and requests the chapter after. Arriving is a scroll, not a no-op.
    func testANewChapterWithNothingSavedGoesToItsTop() {
        XCTAssertEqual(restorePlan(target: ReadingPosition(page: 0), isNewChapter: true), .top)
    }

    func testASavedPositionSettles() {
        let target = ReadingPosition(page: 3, fraction: 0.4)

        XCTAssertEqual(restorePlan(target: target, isNewChapter: true), .settle(target))
    }

    /// A position inside the *first* strip is a real position. The guard this replaces was
    /// `pagerTarget > 0`, which skipped restore for the whole of a one- or two-strip chapter.
    func testAPositionInsideTheFirstStripStillSettles() {
        let target = ReadingPosition(page: 0, fraction: 0.6)

        XCTAssertEqual(restorePlan(target: target, isNewChapter: true), .settle(target))
    }

    /// A retry re-runs the load without changing chapter, and the reader has not moved — so
    /// settling back to where they are is right, and it costs nothing when it is a no-op.
    func testAReloadOfTheSameChapterSettlesBackToWhereTheReaderIs() {
        let target = ReadingPosition(page: 6, fraction: 0.2)

        XCTAssertEqual(restorePlan(target: target, isNewChapter: false), .settle(target))
    }

    /// But a reload with nothing to restore must not yank a reader who is sitting at the top.
    func testAReloadOfTheSameChapterWithNothingSavedLeavesTheReaderAlone() {
        XCTAssertEqual(restorePlan(target: ReadingPosition(page: 0), isNewChapter: false), .none)
    }

    // MARK: - Restore: the settle loop's stopping rule

    /// The grid can only address multiples of a slot, so the first aim floors the fraction —
    /// which can only land the reader *early*, never past the position they saved.
    func testTheFirstAimIsTheSliceAtOrJustBeforeTheFraction() {
        let step = settleStep(target: ReadingPosition(page: 5, fraction: 0.62),
                              strip: strip(-100, 3000), viewport: viewport,
                              currentAim: nil, attempt: 0)

        XCTAssertEqual(step, .scroll(StripAnchor(page: 5, slot: 31)))
    }

    /// `Int(0.99 * 50)` is 49, and 49 is the last slot of a `0..<50` grid. The clamp on
    /// capture is what keeps this from ever being asked to address slot 50.
    func testAFractionJustUnderOneAddressesTheLastSlot() {
        let step = settleStep(target: ReadingPosition(page: 2, fraction: 0.99),
                              strip: strip(-100, 3000), viewport: viewport,
                              currentAim: nil, attempt: 0)

        XCTAssertEqual(step, .scroll(StripAnchor(page: 2, slot: stripAnchorSlots - 1)))
    }

    /// One of the four pathological cases: the target row is not realized at all. Aiming at
    /// the row itself is what forces a `LazyVStack` to build it, and this is what replaces
    /// ADR-0013's fixed 50ms sleep rather than sitting beside it.
    func testAnUnrealizedTargetRowIsAimedAtDirectly() {
        let step = settleStep(target: ReadingPosition(page: 7, fraction: 0.4),
                              strip: nil, viewport: viewport, currentAim: nil, attempt: 0)

        XCTAssertEqual(step, .realize(page: 7))
    }

    /// Realized but not yet laid out is the same case: there is no height to divide by.
    func testARealizedButUnmeasuredRowIsAlsoAimedAtDirectly() {
        let step = settleStep(target: ReadingPosition(page: 7, fraction: 0.4),
                              strip: strip(0, 0), viewport: viewport, currentAim: nil, attempt: 0)

        XCTAssertEqual(step, .realize(page: 7))
    }

    /// The stopping rule is the grid's own resolution: with a 3000pt strip and N = 50 a slot
    /// is 60pt, and anything tighter is unsatisfiable — the loop would spend its whole budget
    /// and stop at the same place anyway.
    func testItStopsOnceTheResidualIsWithinOneSlot() {
        let step = settleStep(target: ReadingPosition(page: 5, fraction: 0.62),
                              strip: strip(-1830, 3000), viewport: viewport,   // residual 30pt
                              currentAim: StripAnchor(page: 5, slot: 31), attempt: 1)

        XCTAssertEqual(step, .stop)
    }

    /// Overshoot is never accepted — a residual below zero means content was skipped. This is
    /// what makes "the leftover error lands behind the reader" true by construction.
    func testOvershootAlwaysEarnsAnotherAttemptAimingEarlier() {
        let step = settleStep(target: ReadingPosition(page: 5, fraction: 0.62),
                              strip: strip(-1960, 3000), viewport: viewport,   // residual -100pt
                              currentAim: StripAnchor(page: 5, slot: 31), attempt: 1)

        XCTAssertEqual(step, .scroll(StripAnchor(page: 5, slot: 29)))           // ⌈100/60⌉ = 2
    }

    /// The other direction: strips above the target decoded between the scroll and the
    /// measurement, so everything moved down and the reader is short of where they asked for.
    func testFallingShortAimsFurtherDown() {
        let step = settleStep(target: ReadingPosition(page: 5, fraction: 0.62),
                              strip: strip(-1660, 3000), viewport: viewport,    // residual 200pt
                              currentAim: StripAnchor(page: 5, slot: 31), attempt: 1)

        XCTAssertEqual(step, .scroll(StripAnchor(page: 5, slot: 34)))           // ⌊200/60⌋ = 3
    }

    /// What a cold reader does: page 3 is laid out below the first screen before any scroll has
    /// taken effect. Stepping slices cannot close that distance, and the last slice ends the loop
    /// with the reader at the top of the chapter.
    func testATargetStillBelowTheViewportIsAimedAtAgainByRow() {
        let target = ReadingPosition(page: 2, fraction: 0.31)
        for slot in [15, stripAnchorSlots - 1] {
            let step = settleStep(target: target, strip: strip(viewport.maxY, 603), viewport: viewport,
                                  currentAim: StripAnchor(page: 2, slot: slot), attempt: 1)
            XCTAssertEqual(step, .realize(page: 2), "slot \(slot)")
        }
        // The first aim is still a slice: nothing has been tried yet.
        XCTAssertEqual(settleStep(target: target, strip: strip(viewport.maxY, 603), viewport: viewport,
                                  currentAim: nil, attempt: 0), .scroll(StripAnchor(page: 2, slot: 15)))
        // A visible strip that runs out of content underneath keeps the old rule, and stops.
        XCTAssertEqual(settleStep(target: target, strip: strip(viewport.maxY - 1, 603), viewport: viewport,
                                  currentAim: StripAnchor(page: 2, slot: stripAnchorSlots - 1), attempt: 1), .stop)
    }

    /// A measurement that never stabilises: the budget is the only thing that ends it, and it
    /// has to end it even while the residual is still enormous.
    func testTheBudgetStopsALoopThatIsStillNowhereNearIt() {
        let step = settleStep(target: ReadingPosition(page: 5, fraction: 0.62),
                              strip: strip(-9000, 3000), viewport: viewport,
                              currentAim: StripAnchor(page: 5, slot: 31),
                              attempt: settleAttemptBudget)

        XCTAssertEqual(step, .stop)
    }

    /// A strip shorter than the viewport cannot be positioned exactly — the scroll view runs
    /// out of content underneath it — so the loop walks to the top of the strip and then stops
    /// rather than re-issuing a scroll that cannot change anything.
    func testAStripShorterThanTheViewportWalksToItsTopAndStops() {
        let target = ReadingPosition(page: 3, fraction: 0.5)
        let short = strip(-600, 400)                                            // residual -400pt

        let first = settleStep(target: target, strip: short, viewport: viewport,
                               currentAim: StripAnchor(page: 3, slot: 25), attempt: 1)
        XCTAssertEqual(first, .scroll(StripAnchor(page: 3, slot: 0)))

        let second = settleStep(target: target, strip: short, viewport: viewport,
                                currentAim: StripAnchor(page: 3, slot: 0), attempt: 2)
        XCTAssertEqual(second, .stop)
    }

    // MARK: - Recording cadence

    private let window: TimeInterval = 1
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testTheFirstMeasurementRecordsImmediately() {
        XCTAssertEqual(recordAction(now: t0, lastFired: nil, window: window, trailingArmed: false),
                       .recordNow)
    }

    func testAMeasurementAfterTheWindowRecordsImmediately() {
        XCTAssertEqual(recordAction(now: t0.addingTimeInterval(1.5), lastFired: t0,
                                    window: window, trailingArmed: false),
                       .recordNow)
    }

    /// The bug decision 5 shipped in its first draft: with a leading edge only, the value at
    /// the *end* of a scroll — 62% down strip 5, read for two minutes, then backgrounded —
    /// is never written. Scroll-then-stop-then-leave is the normal shape of reading.
    func testAMeasurementInsideTheWindowArmsATrailingFireAtTheWindowEnd() {
        let action = recordAction(now: t0.addingTimeInterval(0.1), lastFired: t0,
                                  window: window, trailingArmed: false)

        XCTAssertEqual(action, .scheduleTrailing(at: t0.addingTimeInterval(window)))
    }

    /// And the property that keeps it a throttle rather than the idle-debounce this decision
    /// rejected: once armed, later measurements are ignored and the fire is **never pushed
    /// out**, so the maximum gap stays one window however long the scroll runs.
    func testAnArmedTrailingFireIsNeverPushedOut() {
        for elapsed in [0.2, 0.5, 0.9, 0.99] {
            XCTAssertEqual(recordAction(now: t0.addingTimeInterval(elapsed), lastFired: t0,
                                        window: window, trailingArmed: true),
                           .ignore,
                           "a measurement \(elapsed)s in should not re-arm")
        }
    }

    // MARK: Capture before the reader is positioned (ADR-0014 decision 10, #418)

    /// A PDF strip is measured and decoded at the top before restore starts. Capturing that as
    /// the live position would make it the restore target.
    func testAMeasurementBeforeTheReaderIsPositionedIsNotALivePosition() {
        let metrics = StripMetrics()
        metrics.frames = [0: StripFrame(rect: CGRect(x: 0, y: 0, width: 402, height: 603), isDecoded: true)]
        metrics.viewport = CGRect(x: 0, y: 0, width: 402, height: 874)

        XCTAssertFalse(metrics.capture(completedRequest: 1))
        XCTAssertNil(metrics.live)

        metrics.positionedRequest = 1
        XCTAssertTrue(metrics.capture(completedRequest: 1))
        XCTAssertEqual(metrics.live, ReadingPosition(page: 0, fraction: 0))
    }

    /// A completed load that hasn't been positioned yet keeps the position from before it.
    func testALaterLoadSuspendsCaptureUntilItIsPositioned() {
        let metrics = StripMetrics()
        metrics.frames = [3: StripFrame(rect: CGRect(x: 0, y: 0, width: 402, height: 603), isDecoded: true)]
        metrics.viewport = CGRect(x: 0, y: 0, width: 402, height: 874)
        metrics.positionedRequest = 1
        metrics.live = ReadingPosition(page: 1, fraction: 0.5)

        XCTAssertFalse(metrics.capture(completedRequest: 2))
        XCTAssertEqual(metrics.live, ReadingPosition(page: 1, fraction: 0.5))
    }
}
