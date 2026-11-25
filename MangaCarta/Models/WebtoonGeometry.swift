//
//  WebtoonGeometry.swift
//  MangaCarta
//
//  The vertical reader's pure geometry: turning measured strip frames into a
//  `ReadingPosition` (capture), and — from commit 3 — deciding where the settle loop
//  should scroll next (restore).
//
//  Lifted out of `ReaderView` for the same reason `ReaderPresentation` was (ADR-0012):
//  the parts that are decidable without a scroll view should be decidable in a test.
//  See ADR-0014 decisions 9 and 10, and their 2026-07-30 amendments.
//

import Foundation
import CoreGraphics

// MARK: - Constants

/// The highest fraction capture will ever report.
///
/// `[0, 1)` is enforced where the value is *made*, because restore addresses
/// `slot = Int(fraction * stripAnchorSlots)` and `1.0` would name a slot that does not
/// exist in a `0..<N` grid (ADR-0014 decision 9).
let maxStripFraction = 0.999

/// Slots per strip in the restore anchor grid — decision 9's `N`. A **rendering**
/// constant, never persisted, so it can be raised later without touching saved data.
let stripAnchorSlots = 50

// MARK: - A measured strip

/// One realized strip as the view measured it: its frame in the reader's scroll
/// coordinate space, plus whether that frame is *real*.
///
/// `isDecoded` is not bookkeeping. Until its image lands, a `WebtoonPage` renders a
/// 460pt `Screentone` placeholder, so a fraction measured against it describes a layout
/// that is about to be replaced — and capture *persists* what it measures (ADR-0014
/// decision 9, second amendment).
struct StripFrame: Equatable {
    var rect: CGRect
    var isDecoded: Bool
}

// MARK: - Capture

/// Where the reader is, given every realized strip's frame and the viewport, or `nil`
/// when that cannot be said.
///
/// Frames are **viewport-relative** — the reader names a coordinate space on its
/// `ScrollView`, so a strip's `minY` goes negative as it scrolls above the top edge.
/// That is also why the caller must *replace* its frame dictionary on every measurement
/// rather than merging: a frame from a derealized row is only valid at the scroll offset
/// it was taken at (ADR-0014 decision 8, second amendment).
///
/// `nil` means "unknown", and there are three ways to get it: nothing is measured yet,
/// nothing measured has a real height yet, or the strip under the viewport top has not
/// decoded. A caller must not read `nil` as "the top" — `record` would forgive it, but
/// only because of monotonicity, which is the wrong reason for this function to be right.
func stripPosition(frames: [Int: StripFrame], viewport: CGRect) -> ReadingPosition? {
    // A realized row that has not been laid out yet has no height, and a ratio into it is a
    // division by zero. Drop those before anything else asks a question about them.
    let measured = frames.filter { $0.value.rect.height > 0 }.sorted { $0.key < $1.key }
    guard !measured.isEmpty else { return nil }

    let top = viewport.minY

    // The ordinary case: the reader is inside a strip.
    if let (index, strip) = measured.first(where: { $0.value.rect.minY <= top && top < $0.value.rect.maxY }) {
        guard strip.isDecoded else { return nil }
        let raw = (top - strip.rect.minY) / strip.rect.height
        return ReadingPosition(page: index, fraction: min(max(0, Double(raw)), maxStripFraction))
    }

    // Above everything realized: rubber-banding at the top of the chapter. Reported as the
    // top of the first strip, whose *own* height is irrelevant to a fraction of zero — so
    // this path is deliberately not gated on decoding.
    if let first = measured.first, top < first.value.rect.minY {
        return ReadingPosition(page: first.key, fraction: 0)
    }

    // Below the strip the reader was last inside: the interstitial, the end mark or the
    // loader. Hold the last strip that is both above the viewport top and real, just under
    // 1, so the value keeps moving as the reader scrolls off the end.
    guard let (index, _) = measured.last(where: { $0.value.rect.maxY <= top && $0.value.isDecoded })
    else { return nil }
    return ReadingPosition(page: index, fraction: maxStripFraction)
}

// MARK: - Restore

/// A slice of a strip, and the only thing restore can actually address.
///
/// Each realized strip is overlaid with `stripAnchorSlots` equal `Color.clear` views
/// carrying these ids, so `scrollTo` lands within 1/N of a strip with no height
/// arithmetic — the overlay inherits the strip's measured height whatever it turns out
/// to be (ADR-0014 decision 9).
struct StripAnchor: Hashable {
    var page: Int
    var slot: Int
}

/// How many corrections the settle loop may make before it gives up and leaves the reader
/// where it is. A loop that cannot stop is how you get a scroll-fight with the user.
let settleAttemptBudget = 10

/// What the settle loop should do next.
enum SettleStep: Equatable {
    /// The target row is not realized or not measured — aim at the row itself, which is
    /// what forces a `LazyVStack` to build it. Decision 10's "step zero", and the reason
    /// ADR-0013's fixed 50ms sleep is replaced rather than joined.
    case realize(page: Int)
    /// Aim at this slice.
    case scroll(StripAnchor)
    /// Close enough, out of budget, or as close as the grid can get.
    case stop
}

/// What a completed load asks of the vertical reader's scroll position.
enum RestorePlan: Equatable {
    /// Nothing to do — the reader is already where it belongs.
    case none
    /// Put the reader at the top of the chapter.
    case top
    /// Run the settle loop at this position.
    case settle(ReadingPosition)
}

/// Whether a completed load should scroll the vertical reader, and where.
///
/// The case that matters is `.top`, and it is not cosmetic. A `ScrollView` keeps its raw
/// content offset when the pages underneath it are replaced, so arriving in a new chapter
/// with "no saved position" is **not** the same as arriving at its top: the reader is still
/// tens of thousands of points down the chapter they just left, which clamps to the bottom
/// of the new one. That is what makes the end-of-chapter auto-advance chain — the loader at
/// the bottom is immediately on screen again, and requests the chapter after.
///
/// A reload of the *same* chapter with nothing saved is left alone, because there the reader
/// is exactly where they were and a scroll would be a yank.
func restorePlan(target: ReadingPosition, isNewChapter: Bool) -> RestorePlan {
    if target.page > 0 || target.fraction > 0 { return .settle(target) }
    return isNewChapter ? .top : .none
}

/// One correction of the settle loop: where to aim next, given what the last one achieved.
///
/// No strip has its real height when restore fires — every one is a 460pt placeholder
/// until its image decodes — so a single scroll aims at 62% of the wrong number. The loop
/// scrolls, re-measures, and corrects; this function holds the part that is pure logic,
/// including the part a hand-check will not think to try: when to **stop**.
///
/// The threshold is the grid's own resolution rather than a chosen constant. Anything
/// tighter than one slot is unsatisfiable — the grid only addresses multiples of
/// `slotHeight` — so the loop would burn its whole budget on every restore and then stop
/// anyway, having achieved the same landing (ADR-0014 decision 10's amendment).
///
/// **Overshoot is never accepted.** A residual below zero means content was skipped, so it
/// always earns another attempt aiming earlier. That is what makes the leftover error land
/// *behind* the reader — re-reading a little — by construction rather than by luck.
func settleStep(target: ReadingPosition, strip: StripFrame?, viewport: CGRect,
                currentAim: StripAnchor?, attempt: Int,
                slots: Int = stripAnchorSlots,
                budget: Int = settleAttemptBudget) -> SettleStep {
    guard attempt < budget else { return .stop }
    guard let strip, strip.rect.height > 0 else { return .realize(page: target.page) }

    let slotHeight = strip.rect.height / Double(slots)
    guard slotHeight > 0 else { return .stop }

    // Still wholly below the viewport after aiming at it: the scroll never took effect, so
    // there is no error to correct by slices. Walking the aim to the strip's last slice would
    // end the loop at the top of the chapter (ADR-0014 decision 10's third amendment).
    if currentAim != nil, viewport.height > 0, strip.rect.minY >= viewport.maxY {
        return .realize(page: target.page)
    }

    // The slice at or just before the target. `floor` is deliberate: it can only land the
    // reader early, never past the position they saved.
    let base = min(max(Int(target.fraction * Double(slots)), 0), slots - 1)
    guard let aim = currentAim else { return .scroll(StripAnchor(page: target.page, slot: base)) }

    let desired = strip.rect.minY + target.fraction * strip.rect.height
    let residual = desired - viewport.minY

    if residual >= 0 && residual < slotHeight { return .stop }

    let corrected: Int
    if residual < 0 {
        // Past the target: come back by at least one slice.
        corrected = aim.slot - max(1, Int((-residual / slotHeight).rounded(.up)))
    } else {
        // Short of it — the layout grew above us between the scroll and the measurement.
        corrected = aim.slot + max(1, Int(residual / slotHeight))
    }

    let next = min(max(corrected, 0), slots - 1)
    // Nowhere left to go inside this strip: stop rather than re-issue a scroll that cannot
    // change anything.
    guard next != aim.slot else { return .stop }
    return .scroll(StripAnchor(page: target.page, slot: next))
}

// MARK: - Recording cadence

/// What the reader should do with a fresh measurement.
enum RecordAction: Equatable {
    /// Leading edge: record this measurement now.
    case recordNow
    /// Inside the window: record the newest value once, at the window's end.
    case scheduleTrailing(at: Date)
    /// Inside the window with a trailing fire already armed — the arming is what makes
    /// this a throttle rather than a debounce.
    case ignore
}

/// The shape of the view's record throttle, as a pure function (ADR-0014 decision 5,
/// second amendment).
///
/// Two properties matter, and neither is checkable by reading the view: a measurement
/// arriving inside the window after a leading fire *arms a trailing fire* — the bug this
/// decision already had once, which loses the value at the end of every scroll — and an
/// armed trailing fire is **never pushed out**, which is what bounds the gap at one
/// window however long the reader keeps scrolling.
func recordAction(now: Date, lastFired: Date?, window: TimeInterval,
                  trailingArmed: Bool) -> RecordAction {
    guard let lastFired else { return .recordNow }
    let windowEnd = lastFired.addingTimeInterval(window)
    if now >= windowEnd { return .recordNow }
    // The window end is pinned to the *last fire*, never to `now`, which is the whole
    // difference between this and a debounce that a continuous scroll defers forever.
    return trailingArmed ? .ignore : .scheduleTrailing(at: windowEnd)
}
