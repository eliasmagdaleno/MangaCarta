# Updates Screen — Design Spec

Date: 2026-11-09
Slug: `updates-screen`

## Goal

Give a returning reader one durable place to answer “what changed in the titles I
follow?” The destination lists newly discovered chapters from the Work-level update
state, newest first, grouped by the local calendar day of each Work's newest
discovery and then by Work. A reader can open a chapter
directly in the reader or open the Work's detail/chapter list, refresh the same
source-aware pipeline used elsewhere, and explicitly mark the visible discoveries as
seen.

This resolves the deferral in ADR-0021's predecessor spec: real content now has
chapter-level ranges, several Works can update on the same day, and a title-only
Library filter cannot provide the triage task without another network fetch.

## Non-goals

- No change to chapter-frontier equivalence, refresh scheduling, notification
  authorization, muting, or adult lock-screen copy; ADR-0021 remains authoritative.
- No notification actions (“Mark read” or “Mute/Unmute”). A separate spec owns those
  actions; this screen only names their future interaction point in the Work row's
  trailing menu.
- No sixth top-level tab, cross-device sync, server polling, or new source capability.
- No use of `isRead` as acknowledgement. Newly discovered state and read state remain
  independent.

## Current code this builds on

The app currently has five native tabs (`Home`, `Library`, `History`, `Search`, and
`Settings`) in `MangaCarta/ContentView.swift:10-16` and `:41-67`. Navigation remains
native SwiftUI, consistent with DESIGN.md's navigation rule at `DESIGN.md:176-178`.
This spec keeps those tabs and makes Updates a pushed destination from Library/Home,
because a sixth peer tab would make a short-lived status surface compete with the
reader's durable destinations.

The existing Library Updates filter is in `MangaCarta/Views/BookmarksView.swift`:

- `:13-19` inject the Library, Work, History, update, and registry stores.
- `:255-290` puts an “Updates” chip beside “All” and user collections.
- `:335-355` computes the filter as a `Set` of `displayManga.id` for summaries whose
  `newlyDiscoveredCount > 0`, then filters `library.items` by that id.
- `:74-105` renders the result as an adaptive cover grid; each card navigates to
  `MangaDetailView` at `:78-84`.

The UI contract that created this filter is
`docs/superpowers/specs/2026-08-24-home-library-updates-design.md:29-32` and
`:60-71`: Home shows at most five Work summaries and Library exposes an Updates filter
beside All and collections. The original deferral is recorded at
`docs/superpowers/specs/2026-08-24-adr-0021-background-refresh-design.md:451-459`.

That filter cannot do the new job well:

1. It is Work/card-level, not chapter-level. It cannot tell a reader which newly
   discovered chapter to start, nor offer a direct chapter-to-reader action.
2. It is not a useful update timeline. It inherits Work summary ordering but has no
   day sections, Work grouping within those sections, or a stable “today/yesterday”
   scan of the newly discovered chapter ordinals.
3. It is a projection of Library listings. `displayedLibraryItems` matches IDs in
   `library.items`, so one Work with multiple Listings can produce a single grid card
   rather than a Work section with its discovered chapters. The Work-level identity
   requirement is explicit in `LibraryUpdatesPresentation.swift:61-85`.
4. It provides no dedicated acknowledgement affordance. Entering a detail/chapter
   list currently clears newly discovered state (`MangaCarta/Views/MangaDetailView.swift:119-122,
   :165-173`; `MangaCarta/Views/ChapterListView.swift:167-169, :206-209`), which makes
   “I saw this” inseparable from navigation and leaves no mark-all-seen operation.
5. It is subordinate to collection management and can be empty-looking while Home's
   compact summary is the only route explaining update freshness. It cannot serve as
   a notification landing surface with a focused Work/chapter context.

The existing state is sufficient to build this without inventing a second update
ledger. `WorkUpdateState.newlyDiscovered` is a `Set<ChapterOrdinal>` and is persisted
through `updates.json` (`MangaCarta/Services/UpdateStateStore.swift:10-18, :32-45`).
`absorb` adds only later frontier releases (`:48-75`), while
`clearNewlyDiscovered` clears only that set (`:92-98`). `LibraryUpdatesPresentation`
already keeps the counts separate: `unreadChapterCount` is frontier minus History
read ordinals, while `newlyDiscoveredCount` is the discovery set count
(`MangaCarta/Models/LibraryUpdatesPresentation.swift:61-85`).

`LibraryRefreshCoordinator.refreshLibrary()` is the foreground entry point
(`MangaCarta/Services/LibraryRefreshCoordinator.swift:141-143`), and Library already
uses it for pull-to-refresh (`MangaCarta/Views/BookmarksView.swift:106-108, :230-245`).
The new screen must call the injected coordinator through the existing Library
refresh seam, never a source directly.

Notifications currently carry a Work ID and route through `WorkNavigator`
(`MangaCarta/Services/UpdateNotifier.swift:133-139`), while `ContentView` selects
Library (`MangaCarta/ContentView.swift:101-105`) and the Library instance handles the
push (`MangaCarta/Views/BookmarksView.swift:175-185`). The new route will preserve the
Work ID but have Library push UpdatesScreen with that Work focused before the reader
or detail action is taken.

Visual treatment follows Ink & Seal: warm paper/near-black surfaces and one vermilion
status accent (`DESIGN.md:68-105`), serif identity titles and monospaced metadata
stamps (`DESIGN.md:107-128`), generous page/section rhythm and adaptive layouts
(`DESIGN.md:130-134`), and native navigation/controls (`DESIGN.md:176-178`).

## Design

### Destination and entry points

Add `UpdatesView` as a pushed `NavigationStack` destination, not a new AppTab.
There are three entry points, all opening the same screen:

1. Home's existing “View all N updates” link (`HomeView.swift:110-123`) becomes a
   navigation link to `UpdatesView`.
2. The Library Updates chip remains useful as a discoverable filter, but its selected
   content changes from the cover grid to a visible “Open Updates” action at the top
   (or tapping the chip itself pushes UpdatesView). The existing chip remains in the
   collection bar for continuity and its count becomes the number of Works with
   newly discovered chapters.
3. A notification tap selects Library and pushes `UpdatesView(focusedWork:)`. The
   focused Work is scrolled into view and visually/semantically announced; no chapter
   is opened merely because a notification was tapped.

Options considered:

- A sixth Updates tab: fastest to find, but adds a peer destination for a stateful
  inbox and changes the established five-tab contract on both iPhone and iPad.
- Keep only the Library filter: smallest change, but cannot express chapter rows,
  day grouping, or a notification-focused landing state.
- Dedicated pushed destination with Home/Library/notification entry points: chosen.
  It answers the proven content-range problem while preserving tab topology and
  gives one testable surface for all update flows.

### Screen anatomy

Use a large navigation title “Updates”. Below it:

- A compact status header with total newly discovered chapters, last successful check,
  refresh control, and a “Mark all seen” button. The refresh control uses the existing
  `UpdatesHeader` semantics as a starting point (`UpdatesHeader.swift:3-30`) but the
  count must say “N new chapters”, not unread chapters.
- A recoverable partial-failure notice naming the affected Sources, reusing the
  existing `recoverySummaries` contract. Known discoveries remain visible.
- A `ScrollView`/`LazyVStack` of day sections. The day label is “Today”, “Yesterday”,
  or a locale-formatted date derived from each Work's `newestDiscoveryAt`. Within a
  day, group by Work. A Work group includes its cover/title, “N new chapters”,
  optional source/freshness metadata, and its newly discovered chapter rows sorted by
  newest ordinal first. There is no per-chapter discovery date: `updates.json` stores
  only the Work-level `newestDiscoveryAt`.
- Each chapter row is a native `NavigationLink` to the existing reader path, carrying
  the resolved `Manga`, `Chapter`, source, current history position, and Work's
  chapter collection. The Work header/title is a separate link to the existing detail
  path. If chapter metadata cannot be resolved, show the Work row and a “View chapter
  list” action rather than dropping the discovery.

`Chapter.date` is optional release-date metadata, not discovery time; if shown, label
it as a release date. Grouping uses only the Work's `newestDiscoveryAt`, and there is
no “date unknown” per chapter. `newlyDiscovered` remains the durable membership set;
the screen may fetch current chapters to map ordinals to IDs/titles. No second
timestamp is persisted in v1.

### Empty/loading/error states

- No saved Works: “Keep your library current” with Browse Titles and Search Titles,
  matching Home's current copy at `HomeView.swift:314-329`.
- Saved Works, no newly discovered chapters: “You’re up to date” and a short line
  “New chapters will appear here when saved titles are checked.” Keep Refresh visible.
- Loading chapter metadata: preserve the day/Work shell where possible and expose one
  combined VoiceOver loading label; never show a blank screen after a successful update
  count exists.
- Refreshing: preserve rows, disable duplicate refresh actions, and use native
  pull-to-refresh plus the toolbar/header action. Completion announces “Updates
  refreshed”; partial failure announces the retryable Source names.
- A source unavailable after discovery: retain the row, show “Source unavailable”,
  and offer the existing Settings/repository route. Do not erase update state.

### Mark-all-seen semantics

“Mark all seen” calls a new bulk operation on `UpdateStateStore` that clears
`newlyDiscovered` for every displayed Work, persists once, and leaves `frontier`,
History, `isRead`, and notification mute state unchanged. A focused Work row may also
offer “Mark seen” with the same separation. The operation is idempotent and only
affects Works still in the Library.

Opening UpdatesScreen, tapping a Work row, and following its detail or chapter link do
not mark anything seen. Only the explicit screen-level or per-Work Mark seen action
clears discovery state. This is a deliberate change from the current detail/chapter
list appearance hooks; the implementation must remove or bypass those hooks for this
flow so a refresh or view redraw cannot acknowledge updates accidentally.

The Work-row trailing menu is the interaction point for Mark seen. The same menu is
reserved for the separate notification-actions spec's future Mute/Unmute item; this
spec does not design that action or its persistence behavior.

The separate notification-actions spec adds a future Mute/Unmute item to the Work-row
trailing menu. That action is not part of this PR; its interaction point is the same
menu, alongside (but distinct from) “Mark seen”.

## Data and persistence changes

1. Add a presentation model (for example `UpdateChapterGroup` and
   `UpdateDaySection`) derived from `LibraryUpdatesPresentation`, WorkStore,
   HistoryStore, UpdateStateStore, and the injected SourceRegistry. It must carry
   WorkID, ListingKey/Manga, ChapterOrdinal, resolved Chapter if available, the Work's
   `newestDiscoveryAt`/local-day grouping key, and a resolution/error state. Keep it
   pure enough for unit tests.
2. Add `UpdateStateStore.clearNewlyDiscovered(workIds:)` (or equivalent bulk method)
   that performs one dirty/save cycle and never calls HistoryStore. Do not change the
   JSON shape of `updates.json` unless implementation evidence requires migration.
3. Add a coordinator-facing chapter metadata loader that uses the Work's chosen
   Listing/source and existing chapter/detail seams. It must not mutate frontier or
   create a second baseline. Cache only in memory for the screen; a later refresh can
   replace chapter metadata.
4. Add `UpdatesView` under `MangaCarta/Views/` and any shared presentation model under
   `MangaCarta/Models/` or `Services/`. `Models/` and `Services/` are synchronized
   groups; a new `Views/UpdatesView.swift` is not. If tests add a new file under
   `MangaCartaTests/`, it is also not synchronized and must be registered with:

   ```sh
   xcp add-file "$PWD/MangaCarta.xcodeproj" \
     --file "$PWD/MangaCartaTests/UpdatesScreenTests.swift" --targets MangaCartaTests
   ```

   The implementation PR must check `project.pbxproj` immediately before staging,
   per CLAUDE.md's Xcode rewrite warning.

5. Extend `WorkNavigator`'s request handling only enough to carry a destination intent
   (Updates + focused Work). The persisted notification payload remains the Work ID;
   cold-launch routing still selects Library first, then the Library view consumes the
   request. No notification action payload is introduced here.

## Error and edge cases

- A Work has multiple Listings: render one Work group, select the existing fulfillment
  listing for metadata/reading, and never duplicate a discovery merely because two
  Listings reported it.
- A chapter ordinal is in `newlyDiscovered` but no current Chapter maps to it: retain
  a disabled/unknown chapter row with its ordinal and “Open chapter list” fallback.
- A source returns chapters in an order different from the frontier: sort by parsed
  chapter ordinal/date using existing chapter ordering rules; never treat view order as
  discovery order.
- A Work has no `newestDiscoveryAt`: place the whole Work in “Date unknown” after
  dated sections, with deterministic Work-title ordering. Never infer a discovery day
  from `Chapter.date`; that is the source's release date and may be absent or differ
  from local discovery time.
- A refresh fails for one Listing: keep known rows and show the recoverable Source
  notice; failed data is unknown, not evidence that a chapter disappeared.
- A Work is removed while Updates is open: drop it from the next presentation pass;
  `forget` already removes its persisted update state (`UpdateStateStore.swift:109-115`).
- A Work is merged: use the existing `reconcileMerges` behavior before deriving rows;
  do not create duplicate sections for aliases.
- A muted Work still appears in in-app Updates. Muting controls notification delivery,
  not refresh or in-app visibility.
- Adult/unavailable source details follow existing privacy and availability copy; do
  not reveal a title in a notification or add a new adult filter here.

## Accessibility

- The screen, refresh control, mark-seen control, day headings, Work headers, and
  chapter links have stable identifiers for UI tests and VoiceOver.
- Work rows expose one sentence containing title, new-chapter count, unread count when
  relevant, and muted state when present. Chapter rows speak number/title/date and
  whether read; the “NEW” visual stamp is never the only indication.
- “Mark all seen” has a label, hint, and confirmation-free idempotent action; announce
  “All updates marked seen” and retain focus on the control.
- Selected/focused Work state uses label, outline, and position—not vermilion alone.
- At accessibility Dynamic Type sizes, stack Work metadata and chapter details
  vertically; do not rely on a fixed horizontal cover layout. Keep every target at
  least 44 points, following DESIGN.md's button rule at `:150-155`.
- Reduce Motion uses opacity/no movement for focus and refresh status transitions.

## Acceptance criteria

Each criterion maps to a named Swift Testing unit test in `MangaCartaTests/` or a
hermetic XCTest in `MangaCartaUITests/`.

1. `UpdatesPresentationTests.groupsWorksByNewestDiscoveryLocalDayThenOrdinal`: two
   Works with three discovered ordinals produce deterministic sections based only on
   each Work's `newestDiscoveryAt` local day; within each Work, chapters are ordered
   newest ordinal first, and `Chapter.date` does not affect grouping.
2. `UpdatesPresentationTests.keepsUnknownChapterOrdinalVisible`: an ordinal missing
   from fetched chapter metadata remains visible with a fallback action.
3. `UpdatesPresentationTests.multipleListingsProduceOneWorkGroup`: two Listings for
   one Work never duplicate the group or count.
4. `UpdateStateStoreTests.bulkMarkSeenLeavesReadStateUntouched`: bulk clearing removes
   only `newlyDiscovered`; frontier and History `isRead` remain unchanged after reload.
5. `UpdatesScreenTests.markAllSeenIsIdempotentAndScopedToLibrary`: the action clears
   displayed Works once, does not clear a removed/non-Library Work, and updates the
   empty state.
6. `LibraryRefreshCoordinatorTests.updatesScreenRefreshUsesSharedCoordinator`: the
   screen's pull-to-refresh invokes the injected coordinator and new discoveries appear
   without a second refresh implementation.
7. `UpdatesUITests.testUpdatesDestinationShowsDayWorkAndChapterRows`: fixture launch
   opens Home's View all link, asserts Updates title/day/Work/chapter labels, and
   verifies a chapter tap reaches the reader without opening an unrelated source.
8. `UpdatesUITests.testLibraryUpdatesEntryOpensDedicatedDestination`: the Library
   Updates entry reaches the same destination and does not render the old cover-grid
   filter as its terminal surface.
9. `UpdatesUITests.testMarkAllSeenAnnouncesAndPreservesUnread`: mark-all-seen removes
   NEW labels, preserves unread chapter labels, and exposes the completion announcement.
10. `UpdatesUITests.testNotificationTapRoutesToFocusedUpdatesWork`: a hermetic
    notification payload selects Library, pushes Updates, focuses the matching Work,
    and leaves chapter choice to the reader/detail action.
11. `UpdatesUITests.testUpdatesAccessibilityAtLargeText`: accessibility-size fixture
    keeps day headings, mark-seen, refresh, and chapter links reachable with labels and
    no horizontal clipping.
12. `UpdatesUITests.testUpdatesEmptyStateAndRefreshFailure`: no discoveries and a
    partial Source failure show their respective copy, retain retry, and do not erase
    known rows.

The new UI test file, if created, needs `xcp add-file` because `MangaCartaUITests/`
is a plain project group; the same applies to a new unit-test file under
`MangaCartaTests/`. Existing test files may be extended instead to avoid project-file
churn.

## Implementation slices

1. Add pure grouped presentation and bulk mark-seen store API with unit tests.
2. Add UpdatesView, chapter metadata loading, reader/detail links, empty/error states,
   and refresh wiring; extend existing UI tests or add/register one UI test file.
3. Replace Home/Library “View all” terminal links and route notification focus through
   WorkNavigator; add accessibility and notification-route tests.

Each slice can merge independently after its tests pass; no schema migration is
expected.

## Owner decisions (2026-11-09)

1. **Mark-seen timing — decided:** use an explicit screen-level “Mark all seen” and a
   per-Work “Mark seen”; opening a Work row does not mark it seen. The Work-row trailing
   menu is where Mark seen lives, alongside the future Mute/Unmute item owned by the
   separate notification-actions spec.
2. **Notification landing — decided:** route a notification tap to Updates focused on
   the Work, then let the reader choose detail or a chapter. This preserves ADR-0021's
   “never open the newest chapter directly” rule and makes Updates the canonical inbox.
3. **Day timezone — decided:** group by the device's current calendar/time zone,
   because “Today” is a reader-facing local concept; keep the stored discovery
   timestamp absolute. Group Works by the local day of `newestDiscoveryAt`, never by
   `Chapter.date`.
4. **Metadata fetch scope — decided:** lazily fetch each Work's chapters when its group
   expands, fetching only updated Works and capping concurrent chapter requests at
   four. No change to the `updates.json` persistence shape.
