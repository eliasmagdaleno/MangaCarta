# ADR-0014 — Resuming a webtoon where the reader stopped

- **Status:** Accepted (2026-07-29); **amended 2026-07-30** during implementation — decisions 4, 5,
  8, 9 and 10 each carry a dated amendment below, and one new hazard. Two of those are *corrections*
  rather than refinements: decision 5 described one throttle shape for two layers, and the layer it
  got wrong is the one that loses data; decision 8 claimed to close ADR-0013's mode-switch hazard
  while closing half of it. **A second grilling session the same day** added five more, all in
  decisions 5, 8, 9 and 10 and all about capture: what a placeholder strip may report, how the
  measurement box is updated, and what the recorder does while restore is scrolling. They are
  labelled *(second grill)* to keep them apart from the first round's, which share their date.
- **Amends:** ADR-0013 — four of its decisions change here: the view-owned progress latch (its own
  "weakest of the eight decisions"), `pagerTarget`'s type, the fixed 50ms wait before `scrollTo`, and
  what the vertical restore aims at. It also closes three of its hazards — strip-granularity resume,
  the magic 50ms, and mode-switch position — all amended in place there.
- **Related:** ADR-0012 (load-then-commit, and the failure classification this does not touch),
  ADR-0007 (`WorkStore`'s debounced save + flush-on-background, the pattern the persistence half
  copies), ADR-0010 (`.inactive` is not a lifecycle signal)

## Context

ADR-0013 fixed the webtoon restore so that it *fires* — the observer had been mounted too late to
ever see a load complete. What it could not fix is where it lands: `ReadingEntry.page` is a page
index (`HistoryStore.swift:22`) and a webtoon page is a long strip, so a chapter of 8 strips offers
exactly 8 resume points. You reopen at the top of the strip you were partway down. ADR-0013's revisit
trigger named this as needing its own ADR because it "touches history, resume and the progress display
at once". This is that ADR.

**The instinct to add resume points is only right on the restore side.** As a *storage* model it
bakes the resolution into every saved entry; as a *rendering* model it is a constant that can be
turned up later without touching saved data. That split runs through the decisions below and is why
capture and restore end up asymmetric.

**Facts verified live 2026-07-29 (do not re-derive):**

- **`entry.page` is not just a resume pointer — it is the completion signal for three subsystems,
  one of which is the recommender.** `finished = entry.pageCount > 0 && entry.page >= entry.pageCount - 1`
  appears three times, computed independently: `ReadingResume.swift:68` (picks `.cont` vs `.reread`
  for Continue Reading), `TasteProfile.swift:99` (taste signals), and `ChapterRow.swift:23` as its
  inverse `inProgress` (the resume marker and the dimming rule). That is *why* `record` does
  `first.page = max(first.page, page)` (`HistoryStore.swift:67`): the monotonicity is **load-bearing,
  not incidental.** Repurposing `page` as a last-position pointer would let a backwards scroll
  un-finish a finished chapter, flip Continue Reading, resurrect a badge and alter a recommender
  input.
- **`HistoryStore.save()` re-encodes everything on every `record`.** The entire entries array —
  capped at 500 (`:45`) — *and* the read-marks array, both to JSON (`:167-174`). Nothing is
  incremental and nothing is coalesced.
- **Every `WebtoonPage` is 460pt tall until its image decodes.** `CachedAsyncImage.phase` starts
  `.empty` and only becomes `.success` after an `await`, even for a disk-cached image
  (`CachedAsyncImage.swift:20-33`); `.empty` renders `Screentone().frame(height: 460)`
  (`ReaderView.swift:461-462`) and the real height exists only once `scaledToFit()` has an image
  (`:459`). So at the moment restore fires, no strip has its true height.
- **A row's `onAppear` in the vertical reader fires no later than its top reaching the viewport
  *bottom*** (`ReaderView.swift:272`), and a `LazyVStack` may realize ahead of that. Recording the
  appeared index therefore records a page the reader has not reached.
- **`advanceProgress` is latched against same-page calls.** Its guard is
  `index > furthestPage || !hasRecordedProgress` (`ReaderView.swift:190`), so any position change
  *within* a page returns early and never reaches `record`.
- **Restore is guarded on `vm.pagerTarget > 0`** (`ReaderView.swift:305`), so a resume anywhere
  inside page 0 — the whole of a one- or two-strip chapter — skips restore entirely today.
- **Two of the four doors into the reader do not resume at all.** `ChapterListView.swift:34` and
  `MangaDetailView.swift:411` construct `ReaderView(manga:chapter:chapters:)` with no `initialPage`,
  so it defaults to 0 (`ReaderView.swift:56`) — while `ChapterRow.swift:23` renders a resume marker
  on that very row. Only the detail Continue button (`MangaDetailView.swift:219`) and the History tab
  (`HistoryView.swift:66`) pass a page.
- **The app already has a flush-on-background convention.** `Manga_ReaderApp.swift:68-85` calls
  `works.flush()` and `queue.flush()` on `.background`, because "`WorkStore` debounces its saves, and
  `mint` runs on every page turn — so a reading session that ends by backgrounding the app would
  otherwise lose whatever the pending timer hadn't written yet (ADR-0007)". `.inactive` is
  deliberately not a signal (ADR-0010).
- **`WorkStore`'s debounce is cancel-and-rearm** (`WorkStore.swift:384-393`) with an injected
  interval (`:32`) and a `flush()` that writes if dirty (`:348-352`). Its own comment warns that
  re-arming on every call "would defer the write for as long as the user keeps reading" (`:116-119`)
  — which is why a no-op mint does not re-arm.
- **`ScrollPosition.scrollTo(point:)` is iOS 18.0+** and clamps to content bounds. The deployment
  target is 17.5, so exact offset scrolling is an availability branch, not a replacement.
- **`mint` is safe on a hot path** (`WorkStore.swift:111-133`): it only marks the store dirty when it
  learns something.

## Decisions

### 1. `ReadingEntry` gains a flat `fraction`; `page` stays an `Int`

`var fraction: Double = 0`, meaning "how far down `page` the reader had scrolled". The field stays
**flat** alongside `page` rather than nesting a struct, so the persisted JSON grows one key instead of
changing shape.

> **Corrected 2026-07-29 during implementation.** This decision was written claiming "migration is
> free: the default fills in for every existing entry". **That is false, and a test caught it.** Swift's
> synthesized `init(from:)` ignores default values for non-optional properties and throws
> `keyNotFound`, so every pre-ADR-0014 entry failed to decode and the whole history read as empty.
> `sourceId` migrated for free only because `Optional` decodes via `decodeIfPresent`. The real cost is
> a hand-written `ReadingEntry.init(from:)` that uses `decodeIfPresent` for `fraction` and leaves every
> other key required — a missing `page` is corruption, not an older format.

**Beat:** making `page` a `Double` (`5.6` = 60% down strip 5). One field, and — as the correction above
makes clear — migration genuinely *would* have been free, since existing JSON's `"page":4` decodes into
a `Double` without help. Rejected anyway, because `page` is shared with the two *paged* modes, where it
is a `TabView` selection and a fraction is meaningless: widening it would make the field lie for two of
three reading modes to serve the third, and turn all three completion computations above into
floating-point comparisons against `pageCount - 1`. The decoder is a one-time cost paid in one file;
the lie would be paid at every read site forever.

**Accepted cost: two persisted fields that must stay consistent.** A `fraction` is only meaningful
against the `page` it was captured on, so anything writing one must write both; a stale pairing
resumes at a plausible-looking wrong place. The `Double` option is immune to this by construction.
Decision 4 contains the damage by making the pair a single type *in memory* — the flat pair exists
only at the persistence boundary.

### 2. Position is one pair, monotonic by lexicographic max

`record` takes a position and applies a **lexicographic max**: same page, keep the larger fraction;
higher page, take the new pair. Every completion consumer in the Context is untouched, because `page`
still only ever moves forward.

**Beat:** adding `resumePage` / `resumeFraction` as a true last-position pointer beside the
completion fields. Always exact, including the backwards-scroll case. Rejected for putting a second
notion of position into a persisted type — two fields that look like the same thing, plus a rule
about which one every future reader of `ReadingEntry` should consult, which is the kind of ambiguity
that gets resolved wrongly in six months.

**Accepted cost:** scroll back to re-read, then exit, and you resume at your furthest point rather
than where you were. **This is already true today in all three reading modes**, so it is a case left
unfixed rather than a regression.

### 3. `HistoryStore` owns monotonicity; the view's latch is deleted

`furthestPage` and `hasRecordedProgress` go away (`ReaderView.swift:190-192`). The view calls
`record` freely; the store applies the lexicographic max and **skips `save()` when nothing advanced**,
and a no-op does not bump `updatedAt` either — the entry is already the newest, so history ordering
is unaffected. `mint` still runs unconditionally; it is already self-guarding.

This is the revisit ADR-0013 asked for by name: it called the view-side latch "the weakest of the
eight decisions and the first one to revisit if progress recording misbehaves" — in the accepted cost
of its "post-load bookkeeping is one ordered handler" decision, and again in its revisit triggers.
Its stated reason for keeping the state in the view was that its "only consumer is a view-side guard".
That stopped being true the moment a fraction needed recording — the guard now actively *prevents*
the write, since a within-page change fails `index > furthestPage`.

**Beat:** making the view's guard lexicographic too, or adding a second entry point that bypasses it.
Both keep the write-suppression next to the caller, and both put one invariant in two places — the
store's `max` and the view's guard would each have to be right, forever, about the same rule.

**Beat also:** ADR-0013's own suggestion of moving the latch into `ReaderViewModel`. It would reset in
the same assignment that commits, but it puts persistence policy in the load-and-commit type and
still leaves two owners of monotonicity.

**Accepted cost:** `record` is now called on paths where it does nothing — every throttled tick and
every backwards scroll — so the store's no-op path has to stay genuinely cheap. `WorkStore.mint`
(`:116-133`) is the precedent that this is a workable bargain, not a new gamble.

### 4. `ReadingPosition` is one type, from the store to the pager target

`struct ReadingPosition { var page: Int; var fraction: Double }` is what `entry.position` computes,
what `ResumeAction.cont`/`.reread` carry, what `ReaderView` and `ReaderViewModel` take instead of
`initialPage`, and what `pagerTarget` becomes (`ReaderViewModel.swift:52`). `Landing.exact` carries
one. The restore guard becomes `page > 0 || fraction > 0`, which is what makes a page-0 resume work
at all.

**Beat:** adding a `fraction:` parameter to each of the five signatures on the resume path
(`ReadingResume.swift:69`, `MangaDetailView.swift:474`, `ReaderView.swift:56`,
`ReaderViewModel.swift:73`, `HistoryView.swift:66`). No new type, but five places where the two
halves can be passed inconsistently — decision 1's accepted cost, repeated per signature.

**This does not contradict decision 1.** Decision 1 rejected a `Double` *page* because the field
would lie for the paged modes. A struct does not lie: paged modes read `.page` and ignore `.fraction`,
and the model keeps integer comparisons.

**Accepted cost:** `pagerTarget` and a saved position now share a representation while remaining
different concepts — one is transient and may *retreat* on a failed advance (ADR-0013), the other is
persisted and monotonic. `docs/glossary.md:276` is amended to say so explicitly, because a shared type
invites the assumption that `pagerTarget` is monotonic too.

> **Amended 2026-07-30.** Two corrections to the list of things that carry a position.
>
> **`ResumeAction.reread` carries no position at all — just a chapter.** Its `page:` payload was
> already inert: `MangaDetailView.swift:473` maps `.reread` to page 0, nothing else reads it, and the
> label only names the chapter. The case has been documenting a "re-read the last page" behaviour the
> app has never had. **Beat:** converting it to a `ReadingPosition` for symmetry with `.cont` — one
> line, and it keeps the door open if Read Again ever means "back to where you finished". Rejected
> because it upgrades a dead field into a more convincing one, and the next reader would reasonably
> assume the payload is honoured. `.start` and `.next` already carry a chapter alone; `.reread`
> behaves exactly like them and now says so. If that behaviour is ever wanted, it should arrive as a
> deliberate change with a test.
>
> **`landingIndex` becomes `landingPosition(_:pageCount:) -> ReadingPosition`, and a clamp that moves
> the page zeroes the fraction.** A saved `(7, 0.6)` against a chapter that now returns 5 pages lands
> at `(4, 0)`, not `(4, 0.6)`; a negative page lands at `(0, 0)`. The fraction survives only when the
> page comes through untouched. **Beat:** carrying the fraction across the clamp, on the grounds that
> a re-uploaded chapter is usually the same content re-split, so 60% down the last strip may be
> nearer than its top. Rejected because a changed `pageCount` means the strips were re-cut, so the
> ratio maps to nothing — and this decision's own accepted cost (decision 1) already names a stale
> pair as resuming "at a plausible-looking wrong place", which is harder to notice than resuming at
> zero. Landing at the top of a strip is honest about not knowing.

### 5. Throttle at both layers, not debounce at one

The live position is fed to `record` **at most once per ~1s while scrolling**, and `HistoryStore`
coalesces disk writes with a **leading-edge throttle**: the first dirty schedules a write and later
dirties do not push it out. Both intervals are injected so tests set them to zero, mirroring
`WorkStore.saveDebounce` (`:32`). `Manga_ReaderApp`'s `.background` case gains `history.flush()`
beside `works.flush()` (`:79`); the reader view needs no `scenePhase` code of its own.

**Beat:** recording on scroll-*idle* with an immediate save — the original design. It fails outright
once decision 7 removes the `onAppear` writes: an idle debounce fires only when scrolling *stops*, a
cancel-and-rearm save defers while records keep arriving, and reading a webtoon is never quiet. Read
for twenty minutes without pausing, force-quit, lose the session — the exact failure the debounce was
chosen to prevent. `WorkStore`'s comment at `:116-119` is the same trap, found the same way.

**Beat also:** persisting only on disappear and background. Zero write amplification and no interval
to own, but a force-quit or crash loses the position, and this is the longest single-screen session in
the app with no other autosave anywhere.

**Beat also:** recording when the top-most strip changes. Today's write frequency, but it stores only
strip-boundary fractions — i.e. back to landing at the top of a strip.

**Accepted cost:** two intervals to tune instead of one, and a disk write every couple of seconds
during continuous reading where today's design writes only on page boundaries. The coalescing is what
makes the 500-entry re-encode survivable rather than fixed.

> **Corrected 2026-07-30. This decision described one throttle shape and applied it to two layers,
> and the layer it got wrong is the one that loses data.** The store's leading-edge, non-re-arming
> throttle is right — it is `WorkStore`'s lesson and it bounds the write rate. Copying that shape into
> the *view* drops the value that matters most:
>
> > Scroll for thirty seconds. The last tick fired 0.9s ago at 55% down strip 5. Stop at 62%, read
> > that screenful for two minutes, then background the app. `flush()` faithfully writes 55%. Nothing
> > ever writes 62%.
>
> Scroll-then-stop-then-leave is the normal shape of reading, so the trailing value is the one worth
> having. It also makes this decision's closing claim — "the reader view needs no `scenePhase` code of
> its own" — false as written, because `flush()` can only write what the store was told.
>
> **The view's throttle therefore has a trailing fire.** The leading edge records immediately; if more
> measurements arrive inside the window, **one** catch-up record is scheduled at the window's end with
> the latest value. This is **not** the idle-debounce beaten above: the trailing fire is pinned to a
> fixed window end and is never pushed out, so the maximum gap stays ~1s however long the scroll runs.
>
> **And the reader records on `onDisappear`**, guarded by the same
> `progressChapterID == vm.currentChapter.id` check the throttled path uses (decision 6). This is not
> belt-and-braces: a `.task`-scoped trailing timer dies with the view, so "stop scrolling, immediately
> tap ✕" is up to a second short without it. `onDisappear` fires on the pop and on a reading-mode
> switch, both of which are exits from the vertical reader.
>
> With the trailing fire in place the original claim becomes true again: ≥1s after the last scroll the
> store already holds the final position, so backgrounding needs nothing new in the reader.
>
> **Accepted cost:** one more moving part in the view, and a record that can fire while the view is
> being torn down.

> **Amended 2026-07-30 (second grill) — the recorder is silenced while the settle loop runs, and the
> throttle's *shape* is a pure function.**
>
> **`StripMetrics.isRestoring` gates the record path, not the measurement.** Capture and restore share
> one measurement stream, and decision 10's loop deliberately renders positions it then rejects: an
> overshoot never becomes a *landing*, but it does become a frame, `stripPosition` faithfully reports
> it, and `record`'s lexicographic max makes it permanent if a window ends there. The asymmetry is the
> whole argument — undershoot transients are discarded by the max, overshoot transients stick, so the
> loop's one rejected outcome is the only one that can reach disk. Timing does not save it: step zero
> waits up to ~1.5s for the target row to realize, which is the *normal* case on a cold cache, so the
> trailing fire lands mid-flight precisely when strips are still resizing. `onDisappear` is guarded by
> the same flag and is the sharper case — open a chapter, tap ✕ mid-flight, and the exit record writes
> a scroll the user never performed. Suppressed it writes nothing, which is correct: the store already
> holds the position restore is aiming at. **Beat:** clamping records to ≤ the restore target rather
> than suppressing them — more surgical, and it keeps real scrolling recordable during the loop's tail.
> Rejected for putting a second ceiling rule beside `record`'s max, which is decision 3's "one
> invariant in two places" again. **Accepted cost:** if the reader scrolls during restore (the "settle
> loop can fight the user" hazard) that scrolling is unrecorded until the loop exits — bounded by the
> same attempt budget at ~2s, and picked up by the next trailing fire. Commit 2 defines the field and
> the guard, commit 3 sets it: one commit holding an inert field beats one commit shipping a knowingly
> wrong recorder.
>
> **The throttle's shape is a pure function** — `recordAction(now:lastFired:window:trailingArmed:)`
> returning `.recordNow` / `.scheduleTrailing(at:)` / `.ignore` — and the view keeps the `Task`, the
> sleep and the call to `record`. The correction above was a *shape* bug found by writing out a
> scenario in prose, which is a fine way to find one bug and a bad way to be sure there is not a
> second. The two properties that make the corrected shape right are each one assertion, and neither is
> checkable by reading the view: a measurement arriving inside the window after a leading fire returns
> `.scheduleTrailing` rather than `.ignore` (the bug that was actually there), and an armed trailing
> fire is never pushed out (what separates this from the idle-debounce beaten above, and the property
> most likely to be broken later by someone "fixing" a missed update). It is also the third piece of
> tricky logic in this one view after `stripPosition` and `settleStep`; leaving it untested because its
> subject is time rather than geometry would be an accident of subject matter. **Beat:** a `Throttle`
> class owning its own timer with an injected `Clock`, tested end to end. It proves more — including
> that the trailing fire actually lands — but a fake clock is real machinery for fifteen lines, and
> `HistoryStore`'s injected-interval trick (set the interval near zero) cannot test a trailing fire at
> all, only that something eventually happens. **Placement:** its own file under `Models/`, with its
> tests sharing the one new test file `WebtoonGeometry`'s tests already need, so commit 2 crosses the
> `pbxproj` hazard once instead of twice.

### 6. A pending position update is dropped when the chapter changes, not flushed

`record` attributes to `vm.currentChapter` at call time (`ReaderView.swift:193`). A throttled tick
landing after an advance would therefore write the old chapter's position against the new one — or
worse, fail `record`'s "newest entry is the same manga + chapter" test (`HistoryStore.swift:66`) and
**prepend a whole new history entry** for a chapter the reader already left. `didCompleteLoad` already
detects the change via `progressChapterID` (`:134`), which is the surviving reason that property
exists after decision 3.

**Beat:** flushing the pending update against its captured chapter. More faithful, and it is the
option to reach for if the loss ever matters — but it means `record` growing an explicit chapter
argument and a rule for writing to an entry that is no longer `entries.first`.

**Accepted cost:** up to ~1s of fraction lost in the chapter you just scrolled off the end of, where
the fraction barely matters because the chapter is finished.

### 7. In vertical mode the viewport top is the only position feed

`.onAppear { advanceProgress(to: index) }` (`ReaderView.swift:272`) is removed for `.vertical`. The
capture measurement drives both the resume position and the completion signal. The paged modes keep
`onChange(of: currentPage)` (`:230`) exactly as they are.

**Beat:** keeping `onAppear`. It defeats the feature it is supposed to support. A row's `onAppear`
fires no later than its top reaching the viewport bottom, so while the reader is on the last screenful
of strip 5, page 6 is already recorded; lexicographic max then makes `(6, 0.0)` beat `(5, 0.9)`, and
resume lands a full viewport *past* where they stopped — skipping content, which is worse than
landing short. No amount of restore precision can recover a position that was recorded ahead of the
reader.

**Beat also:** letting `onAppear` feed completion while the measurement feeds resume. That is
decision 2's rejected second pointer arriving through a side door.

**Accepted cost: `finished` changes meaning for webtoons.** It now fires when the viewport top
*enters* the last strip rather than when that strip *appears* — later than today, still before the
strip has been read to the end, and it feeds Continue Reading (`ReadingResume.swift:68`), the
in-progress badge (`ChapterRow.swift:23`) and taste signals (`TasteProfile.swift:99`). This is the one
decision here with a blast radius outside the reader, and it is accepted because the new timing is
strictly the more honest of two approximations.

### 8. The live position lives in the view, and restore prefers it over the pager target

The vertical reader holds the live `ReadingPosition` as `@State` — the capture measurement writes it
and the throttle reads it, so it has to exist somewhere regardless. Restore aims at it when set and
at `vm.pagerTarget` otherwise; `didCompleteLoad` clears it on a chapter change, alongside the
`progressChapterID` bookkeeping it already does.

This closes ADR-0013's hazard at `:315-317`: switching reading mode mid-chapter re-runs the
`task(id:)` on mount and scrolled to the page the chapter was *entered* at. Consulting the live
position instead costs one `??`.

**Beat:** publishing the live position into `ReaderViewModel` so `pagerTarget` means "where the reader
is now". Closer to the glossary's wording, but it adds a third writer of position, makes a
`private(set) @Published` mutable from the view on every throttled tick, and mixes a continuously
changing value into the type whose whole job (ADR-0013) is event-driven commit arbitration.

**Accepted cost:** two possible restore sources, so "live wins when non-nil" is a rule someone has to
know. Paged → webtoon still lands at the top of the strip: the paged mode has no fraction to give,
which is an honest limit of a page index rather than something this decision drops.

> **Amended 2026-07-30 — the ownership stands, the *mechanism* changes. The live position is not
> `@State`; it lives in a non-observable box that `@State` merely holds.**
>
> ```swift
> final class StripMetrics {          // deliberately NOT ObservableObject
>     var frames: [Int: CGRect] = [:] // realized strips, in the reader's coordinate space
>     var viewport: CGRect = .zero
>     var live: ReadingPosition?
> }
> @State private var metrics = StripMetrics()   // the reference is never reassigned
> ```
>
> A `PreferenceKey` per realized row transports frames; `.onPreferenceChange` merges them into the box
> and recomputes `live`. **Nothing on screen renders the live position** — `pageIndicator` is
> `mode.isPaged`-only (`ReaderView.swift:116`) — so a `@State` write per scroll frame would
> re-evaluate the reader's body, with N anchor views on every realized strip (decision 9), to render
> nothing new. Preference callbacks fire outside the update cycle, so there is no "modifying state
> during view update"; because the box publishes nothing, a scroll costs zero body evaluations; and
> the settle loop and the throttled `record` both read it directly and always see the newest
> measurement.
>
> **Beat:** plain `@State`, as this decision originally said. It is the sanctioned channel and it
> keeps the value visible to Previews and Instruments as state — and reading it from the settle loop
> does work, because the storage box outlives the captured view struct. Rejected on cost and on
> fragility: the per-frame invalidation is real, and "this works because `@State` is reference-backed"
> is a fact about the implementation that a refactor is entitled to break.
>
> **Beat:** `onGeometryChange`, which is the tidy modern answer to all of this and is iOS 18. The
> deployment target is 17.5, so `GeometryReader` + preference is the available path — see the revisit
> trigger below, which already gathers the iOS 18 work.
>
> **Accepted cost:** a mutable reference smuggled through `@State`, which is exactly the pattern
> SwiftUI discourages. The defence is that this is a *measurement cache*, not view state, and what
> makes it allowed to be a reference is precisely that nothing renders from it — so if anything ever
> does need to render from it, this decision has to be reopened rather than worked around.
>
> `StripMetrics` is held by `ReaderView`, not by `verticalReader`, so it survives a reading-mode
> switch — which the amendment below depends on.

> **Corrected 2026-07-30 — this decision claimed to close ADR-0013's mode-switch hazard, and it
> closed half of it. The restore fallback is `currentPage`, not `pagerTarget`, and the paged modes
> read the live position on the way in.**
>
> The live position is only ever written by the vertical capture, so **in a paged mode it is `nil`**
> and restore falls through to `pagerTarget` — which is where the chapter was *entered*, not where the
> pager is now: it is assigned only on a completed load (`ReaderViewModel.swift:165`). Swipe to page
> 5, switch to Webtoon, and the reader lands back at page 0. This decision's accepted cost said that
> case "lands at the top of the strip", which quietly assumed the page was right. It is not. The
> reverse is the same story from the other side: `currentPage` is assigned only in `didCompleteLoad`
> (`ReaderView.swift:139`), so switching to a paged mode after scrolling five strips puts the pager on
> the page the chapter was opened at.
>
> - Restore aims at `metrics.live ?? ReadingPosition(page: currentPage)`. `currentPage` is the pager's
>   live truth and equals `pagerTarget` immediately after a load, so nothing about a normal chapter
>   open changes.
> - Switching *to* a paged mode sets `currentPage = metrics.live?.page ?? currentPage`.
>
> Both cases predate this ADR — neither is a regression — but this is the first design in which the
> reader holds the information to fix them, and each fix is one line. What makes it worth doing here
> rather than deferring is that the two directions become symmetrical: **each mode reads the other's
> live notion of position**, instead of one of them consulting a stale load-time value.
>
> **Beat:** leaving both, on the grounds that mid-chapter mode switching is rare. Rejected because
> "rare, and lands you somewhere you have never been" is the same shape as the bug this whole ADR
> exists to fix.

> **Amended 2026-07-30 (second grill) — how the box is *updated*: `frames` is replaced wholesale, and
> `live` is last-known-good.**
>
> The amendment above says `.onPreferenceChange` "merges" frames into the box. Merge is wrong, for a
> reason specific to the coordinate space: frames are viewport-relative, so **every frame is valid only
> at the scroll offset it was measured at.** A `LazyVStack` derealizes rows a screen or two away, and a
> merged dictionary would keep their rects forever, frozen thousands of points ago.
>
> - **`frames` is replaced by each preference value.** The value *is* the set of realized rows; a row
>   that fell out of it has no frame, not an old one. Two failures go away. A stale rect can test as
>   containing the viewport top and report the wrong `page` — and under the max a wrong *high* page
>   sticks forever while a wrong low one is silently discarded, so the error only ever compounds in the
>   damaging direction. And `settleStep`'s "target row not realized" case — one of the four decision 10
>   demands tests for — stops being answerable with fiction, which is what makes decision 10's step
>   zero ("wait until the target row is realized and measured at all") implementable rather than
>   vacuous. **Beat:** merging, so the loop has something to aim at before its target realizes. That
>   something is exactly the lie above, and step zero is the designed answer to the case it covers.
> - **`didCompleteLoad` clears `frames`** on a chapter change, alongside `live`. Replacement mostly
>   self-corrects on the next layout pass, but strip indices overlap across chapters, so there is a
>   window in which the old chapter's strip 3 answers for the new one's.
> - **A `nil` capture never clears `live`; only a non-nil capture replaces it.** `nil` has three
>   producers — nothing measured yet, overscroll above the first strip, and (decision 9's fourth hole)
>   an undecoded covering strip — and wholesale replacement adds a fourth: `verticalReader` leaving the
>   hierarchy emits the preference's empty default. That last one fires at exactly the moment the
>   correction above reads `metrics.live?.page` on the way into a paged mode, so a self-clearing `live`
>   would nil itself precisely when the mode-switch fix depends on it. Holding `StripMetrics` on
>   `ReaderView` keeps the *box* alive across the switch; only stickiness keeps the *value* alive. It
>   also removes a race that is otherwise unresolvable: SwiftUI does not order `onDisappear` against
>   the preference change from the same teardown, so decision 5's exit-path record would be a coin
>   flip.
>
> **Accepted cost:** `live` can be stale — up to a throttle window of scrolling, or a strip's worth if
> the covering strip was still decoding. All three consumers (the exit record, the mode switch, the
> restore fallback) prefer a slightly stale real position to `nil`, which means "start at the top":
> landing short beats landing nowhere. The one case where stale is genuinely wrong is a chapter change,
> and that is the case that clears it explicitly.

### 9. Restore is an anchor grid plus a settle loop — one path on both OS versions

**Capture:** one `GeometryReader` per *realized* row, reporting the strip's frame in a named
coordinate space; the strip covering the viewport top and the distance into it give
`fraction = (viewportTop − stripTop) / stripHeight`, clamped to `[0, 1)`. A ratio rather than points
is what makes the value survive rotation and transfer between devices — the strip's height scales
with width, the ratio does not. iOS 17's `.scrollPosition(id:)` gives the top visible strip more
cleanly but no fraction, so it does not remove the need.

**Restore:** overlay each `WebtoonPage` with a `VStack` of N `Color.clear` views carrying ids:

```swift
.overlay {
    VStack(spacing: 0) {
        ForEach(0..<slotCount, id: \.self) { slot in
            Color.clear.id(StripAnchor(page: index, slot: slot))
        }
    }
    .allowsHitTesting(false)
}
```

The overlay inherits the strip's measured height and `Color` is infinitely flexible, so the `VStack`
divides it into N equal slices **with no height arithmetic**. `scrollTo(StripAnchor(page: 5, slot: Int(f * N)), anchor: .top)`
is then exact to 1/N of a strip. N = 50 (a 3000pt strip resolves to ~60pt) and it is a **rendering
constant, never persisted**, so it can be raised later without touching saved data.
`allowsHitTesting(false)` is not optional: the chrome-toggle tap is a gesture on an ancestor
(`ReaderView.swift:288-289`), and ADR-0013 already recorded that overlays in this view have to be
deliberate about winning or losing taps — its Context records that `PageRetry` is a `Button` precisely
so its tap beats the chrome toggle (`ReaderView.swift:480-481`).

**Then a settle loop, because the grid alone is not enough.** No strip has its real height when
restore fires — every one is a 460pt placeholder until its image decodes — so a one-shot scroll aims
at 62% of 460pt for a strip that becomes 3000pt, and every strip above it grows too. That error
dwarfs the 60pt the grid buys. So restore scrolls, re-reads the capture measurement, and scrolls
again until the target strip's measured frame sits where it should relative to the viewport, bounded
by an attempt budget. The fixed 50ms wait ADR-0013 accepted is **replaced**, not joined:
the loop's first step is "wait until the target row is realized and measured".

**Beat:** compensated anchor arithmetic — `anchor: UnitPoint(x: 0, y: f')` with
`f' = f·pageH / (pageH − viewportH)`, from the fact that `scrollTo` aligns the *same* unit point on
item and container. No extra views, and `pageH` is already available from the capture. Rejected
because the denominator goes to zero for any strip shorter than the viewport and `f'` exceeds 1
whenever `f > (pageH − viewportH)/pageH` — at pageH 2000, viewportH 800, f 0.9 it is 1.5, and what
`scrollTo` does with an out-of-range unit point is unspecified. Clamping silently reintroduces "closer
but not exact", which is the bug being fixed.

**Beat:** an exact `ScrollPosition.scrollTo(point:)` path on iOS 18 with the grid as the 17.5
fallback. It removes quantization entirely and the settle loop makes it usable — measure the strip's
frame, compute `stripTop + f · stripHeight`, scroll there. Rejected on test surface, not API quality:
everything else in this ADR is unit-testable, and restore is the one part whose correctness is
established by a human scrolling a real chapter and looking. Two mechanisms means every restore bug
starts with "which path was I on?", the answer depends on the simulator's OS version, and hand-checks
run one destination at a time. The precision at stake is also smaller than it looks — with the loop
measuring real frames the residual is one slot, and the residual lands *behind* the reader, which
re-reads a little rather than skipping.

**Accepted cost:** capture and restore deliberately use *different* mechanisms — measuring is cheap
and wants precision, addressing wants stable identity — so the two halves are not symmetrical and a
reader has to understand both. Restore precision is quantized at 1/N, and the grid adds N views per
realized row.

> **Amended 2026-07-30 — what capture reports when the viewport top is not inside a strip.** The rule
> above ("the strip covering the viewport top") has three holes, and because capture feeds `record`,
> they decide what gets *persisted*. All three live in the pure function
> `stripPosition(frames:viewport:) -> ReadingPosition?`, so they are unit-testable without a scroll
> view.
>
> - **Past the last strip** — the top is in the interstitial, the end mark, or the 50pt loader
>   (`ReaderView.swift:274-286`), and no strip covers it. **Fall back to the last measured strip,
>   fraction clamped just under 1.** This changes nothing about completion — `finished` asks
>   `page >= pageCount - 1`, which entering the last strip already satisfied (decision 7) — but it
>   keeps the recorded value moving as the reader scrolls off the end instead of freezing partway
>   down the final strip.
> - **Overscroll above the first strip** — rubber-banding gives a negative offset. **Clamp to
>   `(0, 0)`.** A bounce is not a position.
> - **Nothing measured yet** — restore fires before any row has reported a frame. **Return `nil` and
>   record nothing.** **Beat:** returning `(0, 0)`, which is harmless because `record` is monotonic.
>   Rejected: that makes the capture function correct for a reason that lives in another type. An
>   unmeasured strip is *unknown*, and a function whose job is to say where the reader is should be
>   able to say it does not know.
>
> `[0, 1)` is enforced where the value is **made**, because restore computes `slot = Int(f · N)` and
> `f == 1.0` addresses slot N in a `0..<N` grid. Restore clamps as well, as a cheap backstop.

> **Amended 2026-07-30 (second grill) — a fourth hole: a strip that has not decoded cannot report a
> position.** The three holes above are all about the *viewport* being outside every strip. This one is
> about the *strip* being a lie. `CachedAsyncImage.phase` starts `.empty` even for a disk hit
> (`CachedAsyncImage.swift:22-24`) and `.empty` renders `Screentone().frame(height: 460)`
> (`ReaderView.swift:465-468`), so until its image lands a strip's height is a placeholder. This ADR
> already leans on that fact to justify the settle loop — but **capture reads the same heights, and
> capture writes to disk.**
>
> Cold cache, the reader flicks down 3300pt. Seven 460pt placeholders put the viewport top 60% into
> strip 7, `record` persists `(7, 0.6)`, and the next open lands 1800pt into a real 3000pt strip 7 —
> content they have never seen. That is decision 7's rejected failure ("resume lands a full viewport
> *past* where they stopped — skipping content, which is worse than landing short") arriving through
> capture rather than through `onAppear`. Because `page` is monotonic and feeds `TasteProfile.swift:99`,
> the same flick can mark the chapter finished as well.
>
> - The per-row preference payload is **`(frame, isDecoded)`**, not a bare frame. `WebtoonPage` already
>   switches on its phase (`ReaderView.swift:458-477`), so the flag costs nothing to produce.
> - If the strip covering the viewport top has **not** decoded, `stripPosition` returns `nil` — the same
>   "it does not know" the third hole established.
> - The past-the-last-strip fallback picks the highest **realized and decoded** strip, or placeholder
>   fractions come back in through that door.
>
> Gating on the *covering* strip alone is exactly sufficient: the fraction is a ratio inside that one
> strip, so undecoded strips above it change which strip is on top but cannot distort the ratio — and
> at that instant, that genuinely is the strip on screen.
>
> **Beat:** accept it, and widen the existing hazard ("restore correctness rests on measurements taken
> while images are still decoding") to cover capture too. One less field on the payload, and the reader
> really was looking at that pixel. Rejected because the restore hazard self-corrects on the next
> scroll, while a wrong *persisted* value outlives the session that made it and is then defended by the
> max.
>
> **Accepted cost:** a chapter read on a cold, slow connection records only what `didCompleteLoad` wrote
> at open, until images start landing.

### 10. The settle loop's stopping rule is a pure function

A free function — given the target position, the target strip's measured frame, the viewport, and the
attempt number, return the next anchor to scroll to or `nil` for "stop" — holds the closeness
threshold, the attempt budget and the convergence test. It is unit-tested against the pathological
cases: a strip shorter than the viewport, a target at fraction 0.99, a measurement that never
stabilizes, and a target strip that is not realized at all.

This is ADR-0013's `ReaderPresentation` move again, and for a sharper reason: a settle loop that
cannot decide when to *stop* is how you get an infinite scroll-fight with the user, and "stop" is the
part that is pure logic.

**Beat:** hand-checking the loop only, on the grounds that testing geometry math risks asserting my
own arithmetic back at me. Rejected because the constants would then live inline with no documented
home, and the termination cases are exactly the ones a hand-check will not think to try.

**Beat also:** a live UI test driving a real chapter — flaky against the network, and one red UI test
here is known to be no signal.

**Accepted cost:** the geometry *feeding* the function is still untested view code; the tests prove the
decision, not the measurement.

> **Amended 2026-07-30 — the stopping rule, concretely. Its threshold is the grid's own resolution,
> not a chosen constant.** With `residual = (stripTop + f · stripHeight) − viewportTop`:
>
> - **Stop when `0 ≤ residual < slotHeight`**, where `slotHeight = stripHeight / N`. **Beat:** a fixed
>   point threshold (8pt, 12pt — "close enough to look right"). Rejected because the grid can only
>   address multiples of `slotHeight` — ~60pt on a 3000pt strip at N = 50 — so any tighter threshold is
>   unsatisfiable, and the loop would burn its whole budget on every single restore and then stop
>   anyway, having achieved exactly the same landing.
> - **Overshoot is never accepted.** `residual < 0` means content was skipped, so it always gets
>   another attempt aiming one slot earlier. This is what makes decision 9's claim that "the residual
>   lands *behind* the reader" true by construction rather than by luck.
> - **Budget: 10 attempts.** Per attempt, poll until the target strip's measured frame changes or
>   ~50ms elapses. Step zero is "wait until the target row is realized and measured at all", capped at
>   ~1.5s — this is what **replaces** ADR-0013's fixed 50ms sleep, rather than sitting beside it.
>
> Deriving the threshold from `N` keeps the two constants from drifting: raise `N` for finer restore
> and the stopping rule tightens automatically, with no second edit to remember.
>
> **Placement:** `Models/WebtoonGeometry.swift` holds `StripAnchor`, `stripPosition(frames:viewport:)`
> from decision 9's amendment, and `settleStep(…) -> StripAnchor?`. `Models/` is a synchronized group
> so the file needs no `project.pbxproj` edit; its test file does, via `xcp`. The precedent is
> `Models/ReaderPresentation.swift` (ADR-0012) — the reader's pure pieces, lifted out of the view so
> they can be tested.

> **Amended 2026-07-30 (second grill).** The loop raises `StripMetrics.isRestoring` for its whole
> duration and clears it in a `defer`; that is what silences the recorder while the loop renders — and
> then rejects — its overshoots. The argument is in decision 5's second amendment. The pure-function
> list for `Models/WebtoonGeometry.swift` is otherwise unchanged: the throttle's `recordAction`
> deliberately does **not** live there, because it is timing rather than geometry, but its tests share
> this file's test file so commit 2 touches the pbxproj once.
>
> **Written 2026-07-30 as `SettleStep`, not `StripAnchor?`.** This decision sketched the signature as
> "return the next anchor to scroll to or `nil` for stop". The implementation returns a three-case enum
> — `.realize(page:)` / `.scroll(StripAnchor)` / `.stop` — because "the target row is not realized" is a
> different *instruction* (aim at the row, which is what forces a `LazyVStack` to build it) rather than
> a reason to stop, and folding it into `nil` would have hidden one of the four cases this decision
> demands tests for from the function under test. The loop also passes its **current aim** in, so the
> overshoot rule ("aim one slot earlier") corrects the aim that actually overshot rather than
> recomputing the same slot from the fraction and oscillating against it.

> **Amended 2026-11-25 — a lost scroll is not a landing error.** A vector PDF strip has its height on the
> first layout, so step zero's wait ended before the scroll view could obey a scroll, with the viewport still
> measured as 0×0. The loop read "still 1,144pt below" as an error to correct by slices, clamped the aim to the
> strip's last slice, and stopped about 100ms in, at the top of the chapter. It failed twice on CI (#418) and
> never on a faster machine. Two changes: step zero also waits for a measured **viewport**, and a target still
> wholly below the viewport after an aim is re-aimed **by row** (`.realize`). That re-aim spends time, not
> attempts, until step zero's 1.5s deadline. A visible strip keeps every earlier rule, including the stop when
> the content runs out underneath it. Checked by ignoring every scroll for the first 0.8s of a restore: it
> failed without the viewport wait and passes with both changes.

> **Amended 2026-11-25 (second) — nothing is live until the reader has been positioned.** CI failed a third time
> with the changes above, so a lost scroll was not the cause there. Decision 8 lets `live` outrank the saved
> position, and a measurement could arrive **before** the restore task started. An undecoded image strip captures
> `nil`, which hid this. A PDF strip is decoded from its first layout, so it captured "strip 0, top"; restore then
> read that as its target and left the reader at the top. A slow machine only widens the gap. `StripMetrics` now
> ignores a measurement until its restore task has finished for the current load (`positionedRequest`), and again
> from each later load, or remount, until that one is positioned. This also covers a chapter advance and a return
> from a paged mode. Checked by delaying the restore task 0.8s: it failed with CI's exact page frames before the
> change and passes after it. The lost-scroll rules above stay; the probe that justified them still holds.

### 11. Every door into the reader carries the position

`ChapterListView.swift:34` and `MangaDetailView.swift:411` pass
`history.entry(forChapter: chapter.id)?.position`. Without this, the app renders a resume marker on a
chapter row (`ChapterRow.swift:23`) and then drops the reader at the top when that row is tapped —
so the exactness the rest of this ADR buys would be invisible at two of the four entry points, and
the two most-used ones.

**Beat:** leaving it, on the grounds that a row tap means "start this chapter". It does not: the row
advertises a saved position in the same breath.

### 12. The progress display counts the fraction

`continueProgress` (`MangaDetailView.swift:211-215`) becomes `(page + fraction) / pageCount`. An
8-strip webtoon's Continue rule now moves while reading a strip instead of jumping once per strip.

**Accepted cost:** a paged entry always has `fraction == 0`, so the rule treats that as "page seen"
to avoid shifting paged progress down by a full page. A webtoon position at the exact top of a strip
is therefore reported as one strip further along than it is — under a strip of error, in the display
only.

## Hazards

- **`finished`'s new webtoon timing feeds the recommender.** `TasteProfile.swift:99` reads it, so a
  behaviour change in the reader alters a scoring input. Nothing will fail loudly; the effect shows up
  as different For You output weeks later.
- **The completion rule is computed independently in three places** (`ReadingResume.swift:68`,
  `TasteProfile.swift:99`, `ChapterRow.swift:23`). Any future change to what "finished" means has to
  find all three, and the third is spelled as its own inverse.
- **The two persisted fields can drift.** `record` is the only writer today, but nothing in the type
  prevents a future writer from setting `page` without `fraction`. A stale pair resumes somewhere
  plausible and wrong, which is harder to notice than resuming at zero.
- **The Continue bar jumps backwards when a webtoon chapter is opened and then scrolled.** Decision
  12's rule reads `fraction == 0` as "page seen", so a freshly opened 8-strip chapter — entry
  `(0, 0)` — shows 12.5%, and the first scroll to `(0, 0.1)` drops it to 1.25%. This is that
  decision's accepted "under a strip of error" in its perceptible form, and it is unavoidable while
  the entry does not record which *mode* it was read in: `fraction == 0` is genuinely ambiguous
  between a paged reader on this page and a webtoon reader at this strip's top. A `max(f, ε)` at
  capture would not fix it either — `didCompleteLoad` writes a real `(0, 0)` on chapter open from the
  vertical reader too. The real fix is a persisted mode, which is a lot to spend on a 2pt hairline.
- **A paged read leaves a stale fraction behind.** Reading page 5 in a paged mode records `(5, 0)`,
  and the lexicographic max keeps an earlier `(5, 0.8)` from a webtoon session. Switching back to
  webtoon then resumes 80% down strip 5 even though the paged reader was at its top. Harmless in
  practice, invisible in the model.
- **The exit-path record rests on `onDisappear` firing** (decision 5's amendment). SwiftUI does not
  promise it on every teardown, and the case it covers — leaving within a second of the last scroll —
  is silent when it fails: the reader simply resumes a screenful early. The trailing fire bounds the
  damage to that one second.
- **The settle loop can fight the user.** If the reader starts scrolling while it is still converging,
  it will keep pulling them back. The attempt budget bounds the fight, but nothing detects user
  interaction mid-restore, and there is no clean SwiftUI signal for "the user touched the scroll view"
  in iOS 17.
- **Restore correctness rests on measurements taken while images are still decoding.** The loop
  converges on whatever the frames say at the time; a strip whose image arrives late shifts content
  after the loop has already stopped. Capture is *not* exposed to this — decision 9's second amendment
  gates it on the covering strip having decoded — which is the asymmetry to remember: restore may act
  on a placeholder, capture may not persist one.
- **A cold, slow session records almost nothing.** With the decoded gate, a chapter scrolled faster
  than its images arrive holds only the position `didCompleteLoad` wrote at open. Nothing is wrong and
  nothing is lost that was ever known — but "I read for a minute and it resumed at the top" is a real
  user-visible shape, and its cause is invisible in the model.
- **Real scrolling during a restore is dropped.** `isRestoring` silences the recorder for the loop's
  duration (~2s worst case), so a reader who starts scrolling while the loop is still converging has
  that movement recorded only by the next trailing fire. It compounds with the "settle loop can fight
  the user" hazard above: the same window in which the loop pulls them back is the window in which
  their own scrolling does not count.
- **`live` is deliberately stale-tolerant.** A `nil` capture never clears it (decision 8's second
  amendment), so the mode switch and the exit record can read a position up to a throttle window old.
  The failure mode is landing a screenful short, never landing ahead — but anyone adding a *fourth*
  consumer has to check that "slightly stale beats nil" still holds for it.
- **The anchor grid multiplies view count** — N `Color.clear` per realized row, and it must keep
  `allowsHitTesting(false)` or it swallows the chrome-toggle tap.
- **`HistoryStore.save()` is still an all-or-nothing re-encode** of 500 entries plus read-marks
  (`:167-174`). Decision 5 coalesces the writes; it does not make one cheaper.
- **Carried from ADR-0013:** `requestGeneration` and `lastCompletedRequest` remain one concept in two
  properties, and `.task` cancellation is still unaddressed.

## Revisit triggers

- **When the deployment target moves to iOS 18**, replace the anchor grid with
  `ScrollPosition.scrollTo(point:)` and *delete* N — the grid becomes dead weight rather than a
  fallback worth maintaining. The same move retires the other half: `onGeometryChange` replaces the
  `GeometryReader` + `PreferenceKey` capture of decision 8's amendment, and with the per-frame
  invalidation gone, `StripMetrics` may no longer need to be a non-observable box.
- If resume still misses after the settle loop, go `UIScrollView` via `UIViewRepresentable`, where
  `contentOffset` is exact — the same shape of problem `Components/ZoomableContainer.swift` already
  solved for zoom physics. It means owning the lazy loading too: a `LazyVStack` does not stay lazy
  inside a `UIScrollView`.
- If the backwards-scroll case ever actually bothers anyone, decision 2's rejected second pointer is
  the answer, and it should arrive as an explicit "last position" concept in the glossary rather than
  as a quiet extra field.
- If a fourth consumer of `finished` appears, extract it onto `ReadingEntry` first; three independent
  copies is already one too many.
- If write volume shows up in a profile, make `save()` incremental before shortening either throttle
  interval.
- If paged modes ever need sub-page resume (deep zoom, tall pages), the fraction has a source there
  too — the `UIScrollView` offset inside `ZoomableContainer` — and decision 1's "a fraction is
  meaningless for the paged modes" is the claim to re-examine.
