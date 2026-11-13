# Migrate: switching saved titles to another Source — Design

**Date:** 2026-11-12
**Status:** Accepted, owner sign-off 2026-11-12. Every fork was settled with the owner in conversation; the owner
accepted the four *(design's call)* items as recommended (see the end).
**Slug:** `library-migrate`

## Goal

Let the reader move many saved titles from one Source to another in one go. **Migrate** takes a
**From** Source (A) and a **To** Source (B). It finds each saved title that has a copy on A, looks for
it on B, and shows what it found. On the reader's say-so, it switches the confident matches over:
B's copy is added and pinned, and A's copy is kept as a backup or removed.

The owner named two reasons to migrate, and both are real:

- **A died or went bad.** The reader wants A gone. Keeping it means every Library refresh keeps asking
  a broken Source for chapters.
- **The reader prefers B's scans.** Keeping A as a backup is useful, one tap away in "Read from".

Without this, switching forty titles means opening forty detail pages and using Add a Source on each.

## How this relates to Paperback

Paperback has a Migrate flow: pick a source, search each title on another, review, then move. We take
the shape. Where we differ, it is because the per-title Sources work already gives us the pieces:

| | Paperback | MangaCarta |
|---|---|---|
| Reading progress | Asks whether to bring chapter markers | Nothing to bring. Read state belongs to the title, matched by chapter number (ADR-0027). A removed copy keeps its reads counting |
| Finding the match | One search per title | Same, but each result is graded (same MAL entry / likely / different entry), as Add a Source grades them |
| What gets switched | Every title it found | Only confident matches are pre-ticked. Everything else waits for the reader's pick |
| The old copy | Replaced | The reader chooses once per batch: keep A as a backup or remove it |

Nothing is copied: not the wording, the layout or the screen structure.

## Non-goals

- **Undo for a whole batch.** Decided by the owner, 2026-11-12. Each title can be reversed on its own:
  a re-pin or "Use best available" after a keep run, and Add a Source after a remove run. The confirm
  dialog says so.
- **Merging Works in bulk.** When B's match already belongs to *another* title in the Library, Add a
  Source asks "Combine the titles?". Migrate never does that in a batch. The title goes to "Needs your
  pick", and the reader is sent to its detail page.
- **Local copies.** Local is never a From or a To. Local-library matching owns Local links.
- **Legacy ids** (`mangadex`, bundled WeebCentral). They stay dormant until the reconnect prompt
  (`InstalledSourceIDMigration`, ADR-0003 Amendment 7). Migrate doesn't offer them as a From.
- **Resuming a run after the app quits.** Searching writes nothing, so a killed run loses nothing worth
  resuming. The reader starts it again.
- **An analytics event.** The analytics design owns its event list. Adding `migrate_*` is a change to
  that design, not this one.
- **Changing how matching works.** `MALTitleMatcher` keeps its threshold and ambiguity guard.

## Current code this builds on

Every line below was checked against `main` at `c722db7`.

- **Adding and removing copies:** `WorkStore.addListing(_:to:recordExternalIds:)` returns `.added`,
  `.alreadyLinked`, `.belongsToOtherWork(WorkID)` or `.workNotFound`. It refuses a copy whose MAL id
  another Work owns (`Services/WorkStore.swift:86`).
  `removeListing(_:from:keepingReadState:)` refuses Local and the last copy (`:119`). `moveCopy` and
  `merge` exist but Migrate doesn't use them.
- **Cleanup after a removal:** `WorkSourcesCoordinator.remove(_:from:keepingReadState:)`. It clears a pin
  on the removed copy, re-points the Library item to `chosenListing(for:)`, forgets a MAL-hub choice, and
  drops the copy's update check state (`Services/WorkSourcesCoordinator.swift:30-55`).
- **Pins:** `SourcePreferenceStore.choose(_:for:)` / `choice(for:)` (`:71`, `:63`). The detail page
  follows a pin when it opens (`MangaDetailView.applyPinnedSource`, `:94-105`). So a Library item or a
  Continue entry still pointing at A opens on B once B is pinned.
- **Searching one Source:** `SourceTitleSearch.search(spellings:sourceIDs:excluding:stopWhen:)`.
  `sourceIDs:` limits it to B. Results pass `registry.admitsForDiscovery`, which applies adult gating.
  Its limit of four in flight applies *per call*, so a batch needs its own outer limit (§3).
- **Grading:** `AddSourceModel.makeRow` (`Models/AddSourceModel.swift`) grades each result as
  `sameEntry`, `likely`, `differentEntry` or `ungraded`, using the Work's MAL id and
  `MALTitleMatcher.rankedScores` against `acceptanceThreshold`. It is private to the model today.
  Its spellings come from `spellingsForWork()`: the Work's display title, then its known titles.
- **The Library item:** `LibraryStore.repointItem(from:to:)` keeps the old item's **title and cover URL**,
  and clears `chapterNumbers` (`Services/LibraryStore.swift:127`). So a moved item shows A's cover, which
  stops loading once A is gone.
- **Library refresh:** it only refreshes a Work whose Listings include a saved one
  (`LibraryRefreshCoordinator.makeQueue`, `:221-226`), and it checks every Listing of that Work
  (`eligibleListings`, `:200`). So the Library item must end up on a Listing the Work still has. And a
  kept A keeps being checked.
- **Retained names:** a disabled or uninstalled Source keeps its `InstalledSourceRecord` in
  `RepositoryStore`, declaration included (`Services/RepositoryStore.swift:67`, `:145`). So A can be
  named even after it is uninstalled.
- **The Library toolbar** has three buttons: Import, Refresh Library, Manage Collections
  (`Views/BookmarksView.swift:148-170`). There is no menu.
- **`WorkStore.flush()`** (`:492`) writes immediately instead of waiting for the one-second debounce.

## Options considered

1. **A new migration model, plus a coordinator step per title.** *Chosen by the owner.*
   - Pull grading out of `AddSourceModel` into a shared `SourceMatchGrader`.
   - Add one `WorkSourcesCoordinator.migrate(…)` call that switches one title completely.
   - A new `LibraryMigrationModel` searches, sorts and applies.
   - Thin views on top.

   This matches how per-title Sources was built: the model does the work, the coordinator owns every
   cleanup, the view stays thin.
2. **Loop the existing `AddSourceModel` once per title.** Rejected. That model is built for one title on
   one screen: it searches every Source and asks its questions through dialogs. Bending it into a batch
   would tangle both features.
3. **A persistent background job that resumes across launches.** Rejected as more than the problem needs.
   Searching writes nothing, so nothing is lost by starting over.

## Design

### 1. Entry and choosing the Sources

The Library toolbar's Manage Collections button becomes a **More** menu (`ellipsis.circle`) holding
"Manage Collections" and **"Migrate Sources…"**. *(Design's call: a fourth toolbar button would crowd the
bar, and Settings is the wrong place for an action on the Library.)*

"Migrate Sources…" opens a sheet:

```
Migrate Sources
  From   [ Source A          ▾ ]   12 saved titles
  To     [ Source B          ▾ ]
                       [ Find titles on Source B ]
```

- **From** lists every non-Local Source that serves at least one saved title, with that count. This
  includes a disabled or uninstalled Source, named from its retained record and marked "Not installed".
  The dead-Source case is the main reason to migrate, so it must be pickable.
- **To** lists the visible, non-Local, installed Sources (`registry.visibleSources(includeAdult:)`)
  other than From.
- With nothing to offer (no saved remote titles, or no second Source), the sheet says so, with the
  Add-a-repository hint the hub uses.

### 2. Which titles

The candidates are saved titles (Library items) whose Work has at least one Listing on A. A saved item
with no Work gets one through `coordinator.ensureWork(for:)` when it is applied, not when it is
searched: searching must write nothing.

Before searching, each candidate is sorted:

- **Already on B:** the Work already has a copy on B. No search. It goes straight to **Ready**, labelled
  "Already on B".
- **Otherwise:** search B (§3).

### 3. Searching

- Each title is one `SourceTitleSearch.search(spellings:sourceIDs: [B])` call. The spellings are
  `spellingsForWork()`'s, and `stopWhen` stops early once a same-entry result appears.
- **At most four titles search at once.** This is an outer limit, because each call's own limit covers
  only itself. Within one title, spellings run one after another, so B never sees more than four
  requests from Migrate at a time.
- **Progress** reads "Searched 12 of 40", and VoiceOver announces it every ten titles and at the end.
- **Cloudflare challenges** pause the clock, as in Add a Source, and present over the sheet through
  `.challengeSheets(nested: true)`.
- **Cancel** is always safe, because searching writes nothing. Titles already searched stay on the
  review screen; the rest are listed as "Not searched". Leaving the sheet cancels the search too.

### 4. The review screen

Every title lands in one group. Each row shows the Work's cover and title, B's match (title, grade,
chapter count when known) and a tick.

| Group | When | Ticked by default |
|---|---|---|
| **Ready** | Exactly one result graded `sameEntry`. Or no `sameEntry`, exactly one `likely`, and no `differentEntry`. Or "Already on B" | Yes |
| **Needs your pick** | Anything else with results: several plausible results, only ungraded ones, a `differentEntry`. Also any result that is a copy this Work **removed earlier**, or that **belongs to another Work** | No |
| **Not found on B** | B answered with nothing usable | — |
| **Couldn't check** | B timed out or failed for this title. "Try again" retries it alone, and the result merges in | — |
| **Not searched** | The search was cancelled first | — |

- A result that belongs to another Work never counts as Ready. It shows "Also in your Library as
  <title>", and tapping it opens that title's detail page, where Add a Source offers to combine.
- A copy this Work removed earlier is never auto-ticked. It shows "Removed earlier".
- **Needs your pick:** tapping the row opens a picker that lists B's results with the same rows as Add a
  Source's sheet (grade, alternate title, count). Picking one ticks the row with that result. Picking a
  `differentEntry` result asks first, with Add a Source's wording. A result that belongs to another Work
  can't be picked here (above).
- **Counts:** the Ready rows' matches are counted through `MALHubChapterCountLoader`, at most four at a
  time, after the search finishes. "Chapter count unknown" means unknown, never zero (ADR-0004).
- The bottom bar reads **"Migrate N titles"**. It is disabled at zero.

### 5. Keep or remove, once per batch

Tapping "Migrate N titles" asks once:

> **Migrate 31 titles to Source B?**
> **Keep Source A as a backup:** you can still choose it from "Read from" on each title.
> **Remove Source A:** what you read there still counts. You can add Source A back to any title later.
> **Cancel**

The buttons carry the full sentence, as Remove a Source's do. *(The order, keep first, is the design's
call: it is the reversible one.)*

### 6. Applying one title

The new coordinator operation:

```swift
func migrate(_ work: WorkID, to target: Manga, from sourceId: String, removingOld: Bool) async -> MigrationOutcome
```

Done once per ticked title, in order, on the main actor:

1. **Add.** `works.addListing(target, to: work, recordExternalIds: true)`. If it returns
   `.belongsToOtherWork`, stop and report "skipped: now belongs to <title>". Things can change between
   search and apply. `.alreadyLinked` carries on.
2. **Pin.** `preferences.choose(ListingKey(target), for: work)`. There is one exception *(design's
   call)*: if the Work is pinned to a copy on a third Source, which is neither A nor B, that pin stays.
   A pin is a deliberate per-title decision (ADR-0004 Amendment 1), and a batch shouldn't overrule it.
   B is still added.
3. **Remove A** (only with "Remove"). Every Listing of the Work on A goes through
   `removeListing(_:from:keepingReadState: true)`, followed by the existing removal cleanup. The reader
   has confirmed the match, so this is always "same title". If A was the copy the Work was minted from,
   the display title stays (ADR-0007).
4. **Library item.** It is re-pointed to B's copy, **in both modes**, and takes **B's cover**. The title
   text stays. To do that, `repointItem` gains an optional `coverURL:`, which the removal cleanup passes
   as well. That also fixes the stale cover after a per-title Remove a Source.
5. Nothing is fetched here.

After the last title:

- `works.flush()`, so a quit right after Migrate can't leave a pin pointing at a copy `works.json` never
  recorded. (`chosenListing` ignores such a pin, but the Library item would point outside the Work and
  drop out of refresh.)
- A normal Library refresh is requested. The moved items' chapter numbers were cleared, so unread
  badges stay hidden until a refresh runs. *(Design's call.)*
- A summary: "Migrated 31 titles. 4 skipped.", with each skipped title and its reason.

### 7. What happens to everything else

- **Read state:** nothing changes. With Keep, A's copy is still on the Work. With Remove, it is a
  retired Listing, and `readOrdinals` still counts it (ADR-0027, ADR-0005 Amendment 2).
- **History and Continue:** entries stay recorded under A. Opening one goes to the detail page, which
  follows the pin to B (`applyPinnedSource`). If B numbers a chapter differently, that is ADR-0027's
  accepted risk.
- **Updates:** a removed copy's check state is dropped by the existing cleanup. The Work's frontier and
  "newly discovered" chapters are Work-level, so they stay.
- **MAL:** nothing is sent. Read state didn't change.
- **Removal is sticky:** a removed A copy is never re-linked automatically (ADR-0005 Amendment 2).

## Errors and edge cases

- **From and To are the same:** not offered.
- **No match on B:** the title is untouched, and it is listed under "Not found on B".
- **A Work with two copies on A:** with Remove, both go.
- **A Work whose only copy is on A, with Remove:** B is added first, so `removeListing` never meets the
  last-copy refusal. The order in §6 is load-bearing.
- **A is uninstalled:** search doesn't need A. Removal works, because the copy is still on the Work.
- **B is adult and adult content is hidden:** B isn't in To. Adult results on a mixed B are filtered by
  `admitsForDiscovery`.
- **Offline:** every title is "Couldn't check". Nothing is written.
- **A Library refresh runs during apply:** both run on the main actor, so they interleave between
  titles, never inside one.
- **The reader edits a title during the review** (removes B on its page, say): step 1 re-checks.
- **A large Library:** 500 titles at four at a time, with one to three spellings each, is roughly
  several minutes. The progress counter and Cancel cover it. No upper limit *(design's call)*. A
  Source's own rate limiting (Host API retry handling) still applies.

## Accessibility

- Each row reads "<title>, <group>, match <B's title>, <grade>[, also known as …][, N chapters]".
- The progress is a plain text element, announced as in §3.
- The keep/remove choices are full-sentence buttons.
- Everything stays 44 points or larger and doesn't truncate at the largest Dynamic Type. A UI test
  attaches a screenshot.

## Testing

Each acceptance item names the test that proves it.

**Unit — `SourceMatchGraderTests` (new):**
- `testSameMalIdIsSameEntry`, `testDifferentMalIdIsDifferentEntry`, `testThresholdTitleIsLikely`,
  `testOtherwiseUngraded`.
- `AddSourceModelTests` pass **unchanged** after the extraction. That proves Add a Source didn't move.

**Unit — `WorkSourcesCoordinatorMigrateTests` (new):**
- `testKeepAddsTargetAndPinsIt`
- `testRemoveRetiresEveryOldCopyKeepingReadState`
- `testRemoveWhenOldCopyIsTheOnlyOne`: B is added first, then A is removed.
- `testLibraryItemMovesToTargetWithTargetCover`, in both modes.
- `testPinOnThirdSourceIsKept`
- `testTargetOwnedByAnotherWorkIsSkipped`
- `testMigratedTitleStaysInRefreshQueue`: `makeQueue` still includes the Work.
- `testChapterReadOnOldSourceStillReadAfterRemove`: through `readOrdinals`.

**Unit — `LibraryMigrationModelTests` (new):**
- `testOffersOnlySavedTitlesWithACopyOnFrom`
- `testUninstalledFromIsOffered`
- `testAlreadyOnTargetSkipsSearchAndIsReady`
- `testOneSameEntryIsReady`, `testTwoSameEntriesNeedPick`, `testOneLikelyIsReady`,
  `testLikelyBesideDifferentEntryNeedsPick`
- `testRemovedEarlierIsNeverReady`, `testMatchOwnedByOtherWorkIsNeverReady`
- `testNoMoreThanFourTitlesSearchAtOnce`: a counting fake Source.
- `testCancelKeepsResultsAndWritesNothing`: `works.json`, pins and Library are unchanged.
- `testCouldNotCheckRetryMergesIn`
- `testApplyRechecksAndReportsSkips`
- `testApplyFlushesWorkStore`
- `testSummaryCounts`

**Hermetic UI — `LibraryMigrateUITests` (new):** a `-uitest-library-migrate` fixture with Sources A, B
and C and five saved titles. They cover: one same-entry on B, one likely, one ambiguous, one with no
match, and one already on B. Add the suite to CI's hermetic list in `.github/workflows/ci.yml`.
- `testMigrateKeepPinsTargetAndKeepsBackup`: after a keep run, "Read from" on a migrated title shows B
  ticked and A still listed.
- `testMigrateRemoveDropsOldSource`: after a remove run, A is gone from "Read from", and a chapter read
  on A shows as read.
- `testNeedsPickRowCanBePicked`
- `testCancelDuringSearchChangesNothing`
- `testLargeDynamicType`: with a screenshot attachment.

**Mutations to run** (each must turn a named test red):
- Drop the pin step: `testKeepAddsTargetAndPinsIt`.
- Pass `keepingReadState: false`: `testChapterReadOnOldSourceStillReadAfterRemove`.
- Skip the Library re-point: `testMigratedTitleStaysInRefreshQueue`.
- Let two same-entry results be Ready: `testTwoSameEntriesNeedPick`.
- Remove the outer limit: `testNoMoreThanFourTitlesSearchAtOnce`.
- Swap add and remove in §6: `testRemoveWhenOldCopyIsTheOnlyOne`.

The spec for each slice says "no `swiftlint:disable`", and it asks for both XCTest and Swift Testing
counts by name.

## Slices

Each slice is its own PR, never stacked.

1. **Model.** `SourceMatchGrader` extracted, with `AddSourceModel` using it. `repointItem(coverURL:)`.
   `WorkSourcesCoordinator.migrate`. Unit tests. No UI.
2. **Migration model.** `LibraryMigrationModel`: candidates, outer-limited search, progress, cancel,
   grouping, retry, apply, summary. Unit tests. No UI.
3. **UI.** The More menu, the From/To sheet, the review screen, the picker, the keep/remove dialog and
   the summary. The hermetic fixture and UI tests, plus the CI list entry.

## Open questions for the owner

All the forks were decided in conversation. These were the design's own calls. **Decided 2026-11-12 (owner):
all four as recommended.**

1. **The entry point is a More menu in the Library toolbar.** *Recommended:* yes. Settings → Sources is
   the alternative, but Migrate acts on the Library, not on a Source.
2. **A pin on a third Source survives a migration.** *Recommended:* yes, for the reason in §6 step 2.
   The cost: such a title isn't read from B after migrating, though B is added.
3. **A Library refresh runs after applying.** *Recommended:* yes. Otherwise the migrated titles show no
   unread badge until the next scheduled refresh.
4. **No cap on batch size.** *Recommended:* none. Progress and Cancel make a long run safe.

## Amendment 1 (2026-11-12): slice 1 rechecked against `main` at `382f82a`

The "Current code" claims slice 1 depends on still hold: `addListing`'s four results, `removeListing`'s refusals,
`WorkSourcesCoordinator`'s removal cleanup, `SourcePreferenceStore.choose`/`choice`, `repointItem` keeping the old
title and cover, `AddSourceModel.makeRow`'s grading, and `LibraryRefreshCoordinator.makeQueue`. Three points change
how slice 1 is built:

1. **The removal cleanup has no cover to pass.** A `Work` stores `ListingKey`s, not each copy's cover, so `cleanupAfterRemoval` doesn't know the replacement's cover. `repointItem(from:to:coverURL:)` takes an optional `coverURL` that defaults to `nil`, meaning "keep the item's cover". Only `migrate` passes one (B's, from the target `Manga`). The stale cover after a per-title Remove a Source is not fixed here; §6 step 4's "that also fixes" is withdrawn.
2. **`migrate` adds through `WorkStore.addListing`, not `WorkSourcesCoordinator.add`.** `add` calls `fulfillment.reconcile`, which fetches chapter counts, and §6 step 5 says nothing is fetched. The next Library
   refresh, and slice 2's count loader, supply counts.
3. **The Library item is re-pointed before A is removed.** §6 lists add, pin, remove, re-point. Done in that order,
   the removal cleanup re-points the item to `chosenListing(for:)` first, which is a third Source when such a pin
   survives (step 2), and the item would lose B's cover. So the order is add, pin, **re-point to B with B's cover**,
   then remove A's copies. The cleanup then finds no item on A and leaves it alone. Add still comes before remove, so
   the last-copy refusal is still never met.
