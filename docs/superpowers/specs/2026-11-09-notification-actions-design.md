# New-chapter notification actions design

**Date:** 2026-11-09  
**Status:** Accepted — owner sign-off 2026-11-10.  
**Slug:** `notification-actions`

## Goal

Add two actions to the delivered Work-level new-chapter notification:

- **Mark read** marks exactly the chapters represented by that notification as read through the
  normal per-Work read path. It is a manual mark and deliberately produces no MAL progress event.
- **Mute** suppresses future notifications for that Work while leaving refresh, in-app Updates,
  the frontier, and unread state intact.

The action must be safe when the app is backgrounded or has not been running, and must be testable
without a network or a real notification tap.

## Non-goals

- No server push, cross-device synchronization, or notification delivery guarantee.
- No “mark every unread chapter in this title” action. This is deliberately narrower than a bulk
  read control in the chapter list.
- No change to chapter-frontier/release detection, notification grouping, adult-copy policy, or
  the existing global notification toggle.
- No automatic unmute, timeout, or clearing of read state when an action is performed.

## Current code this builds on

The following facts were checked in the current worktree.

- `UpdateEvent` is one event per `WorkID` and carries the title, capped notification count, and
  adult flag (`MangaCarta/Services/LibraryRefreshCoordinator.swift:8-14`). The coordinator absorbs
  all released ordinals into `UpdateStateStore` and only caps the displayed count
  (`MangaCarta/Services/LibraryRefreshCoordinator.swift:112-138`).
- `UpdateStateStore` persists one `WorkUpdateState` per Work in `updates.json`, including the
  frontier, `newlyDiscovered`, and the existing indefinite `isMuted` flag
  (`MangaCarta/Services/UpdateStateStore.swift:10-18`, `:32-41`). `setMuted` changes only that
  flag and debounces persistence (`:100-107`); `clearNewlyDiscovered` changes only its presentation
  set (`:92-98`).
- `UpdateNotifier` currently creates one request per event, with a stable Work identifier, a shared
  `library-updates` thread, and `userInfo["workId"]` (`MangaCarta/Services/UpdateNotifier.swift:75-90`).
  It skips muted Works (`:79`) and removes a Work's pending request when the Work leaves the
  Library (`:128-131`).
- The response delegate currently forwards only a tap's `userInfo` and completes immediately
  (`MangaCarta/Services/UpdateNotificationDelegate.swift:17-29`). `UpdateNotifier.handleResponse`
  resolves aliases and opens the Work's chapter list; it never opens a chapter
  (`MangaCarta/Services/UpdateNotifier.swift:133-139`).
- Composition constructs one shared `HistoryStore`, `UpdateStateStore`, `UpdateNotifier`, and
  `UpdateNotificationDelegate` (`MangaCarta/Services/AppComposition.swift:313-341`). The app sets
  the notification delegate before launch finishes and registers the scheduler
  (`MangaCarta/MangaCartaApp.swift:135-166`). Stores load synchronously during composition, so a
  cold-start action has the same graph as a foreground action.
- Read state is already Work-wide but storage remains Listing-keyed. `HistoryStore.markRead(manga:
  chapter:)` writes a manual mark (`MangaCarta/Services/HistoryStore.swift:299-304`), while the
  multi-chapter overload writes all supplied chapters in one save (`:325-333`). The Work-wide
  lookup matches chapter ordinals across Listings (`:290-297`). ADR-0027 explicitly requires marks
  to use the active Listing (`docs/adr/0027-read-state-is-per-work.md:25-45`).
- The completion callback used by the normal reader path is in `HistoryStore.record`: when a
  chapter first becomes complete it calls `chapterCompleted` (`MangaCarta/Services/HistoryStore.swift:
  146-151`, `:194-199`). App composition connects that callback to `MALProgressCoordinator`
  (`MangaCarta/Services/AppComposition.swift:311-316`). The MAL progress design explicitly says
  that single/batch manual marks produce no MAL event (`docs/superpowers/specs/2026-08-21-mal-oauth-
  progress-design.md:28`, `:266`), and the existing chapter-list/detail manual marks call
  `HistoryStore.markRead` directly (`MangaCarta/Views/ChapterListView.swift:68,186,203`,
  `MangaCarta/Views/MangaDetailView.swift:625,640`). The notification action follows that same
  rule: it calls `HistoryStore.markRead(manga:chapters:)`, full stop, and does not extract or invoke
  a MAL enqueue sink.
- `MangaSource` can fetch the source's Listing and chapter list (`MangaCarta/Models/MangaSource.swift:
  57-64`). `FulfillmentCoordinator.chosenListing` applies the same pin/ranking choice the detail
  page uses (`MangaCarta/Services/FulfillmentCoordinator.swift:37-51`). A `LibraryItem` stores only
  chapter numbers, not source chapter ids (`MangaCarta/Services/LibraryStore.swift:12-18`), so an
  action cannot safely mark chapters from cached numbers alone.
- Existing tests already inject notification scheduling and route a synthetic response through the
  composed graph (`MangaCartaTests/UpdateNotifierTests.swift:302-328`,
  `MangaCartaTests/AppCompositionTests.swift:365-395`). There is currently no notification category,
  action identifier, or `simctl push`/`.apns` harness anywhere in the repository (verified with a
  repo-wide search).

## Design

### Payload and grouping

Keep one notification request per Work. Several Works remain separate requests in the existing
`library-updates` thread; therefore an action always has exactly one target Work, never an implicit
batch across the thread.

Every scheduled request adds:

- `workId`: the canonical UUID string already used for deep linking;
- `actionVersion`: an integer version for future payload migration;
- `discoveredOrdinals`: the released `ChapterOrdinal` values represented by this event, encoded as
  property-list-safe canonical strings.

`UpdateEvent` should carry the released ordinals (the coordinator already has them before the
notification cap), so the notification captures the event snapshot rather than reading a mutable
state set later. `discoveredOrdinals` is not a second read-state store: it is action context only.
If a legacy request or a hermetic payload omits it, the handler falls back to the Work's current
`newlyDiscovered` set and treats all of that set as the target. A malformed or empty list is a
no-op, never “mark all unread.”

When a later refresh discovers more chapters before an older notification is acted on, the original
action marks only its captured ordinals. The later ordinals remain newly discovered and unread. This
is the only behavior that makes a delayed action deterministic.

### Category and delegate actions

Register one `UNNotificationCategory` at launch, before any request can be delivered:

- identifier `library-update-actions`;
- `UNNotificationAction` identifier `library-update-mark-read`, title “Mark Read”, options
  `.background`;
- `UNNotificationAction` identifier `library-update-mute`, title “Mute”, options `.background`;
- category options `.customDismissAction` only if the implementation needs dismissal telemetry;
  otherwise omit it.

Both actions are background actions. They must not use `.foreground`: neither action needs a view,
and waking the app into the reader would make the action slower and less reliable. The system still
invokes the notification-center delegate in the app process, including a cold launch; the delegate
must call its completion handler only after the bounded state operation has finished.

Change the delegate seam to pass `actionIdentifier`, `userInfo`, and a completion closure to an
async-capable handler. Preserve a synchronous `receive(userInfo:)` test seam for ordinary taps, and
add an explicit `receive(actionIdentifier:userInfo:completion:)` seam because constructing a real
`UNNotificationResponse` is not practical in unit tests. Unknown actions and invalid Work IDs call
completion without mutating state.

### Mark read semantics and the normal path

The action targets one Work and its captured ordinals. The handler:

1. Resolves the payload Work through `WorkStore.work(_:)`, so a merged-away id reaches the surviving
   Work just as a normal notification tap does.
2. Selects the same `FulfillmentCoordinator.chosenListing(for:)` that the detail/reader uses. If
   no registered Listing is available, it completes without changing state.
3. Asks that Listing's `MangaSource` for `manga(id:)` and `chapters(mangaId:)`. This is necessary
   because `HistoryStore` needs source chapter ids and the saved Library item stores numbers only.
4. Filters fetched chapters by the captured `ChapterOrdinal` values. Unparseable ordinals match only
   by an explicit chapter id; because the notification currently carries ordinals, such chapters
   are not silently guessed. They remain unmarked and are reported as an action failure in logs.
5. Calls the existing multi-chapter manual-read operation
   `HistoryStore.markRead(manga:chapters:)` on the active Listing's `Manga`, never directly edits
   `readMarks`, `ReadingEntry`, or `UpdateStateStore` read-like fields.
6. Removes those exact ordinals from `newlyDiscovered`, via a new targeted store method. It must not
   call `clearNewlyDiscovered` because that would erase discoveries from later notifications. This
   operation is presentation cleanup after the read mark; it never creates read state.

If fetching fails, the source is unavailable, or only some chapters can be resolved, the handler
does not partially mark the Work. It calls completion after recording a diagnostic outcome; the
notification can be opened normally and retried from the app. The bounded action budget is more
important than forcing a WebView/Cloudflare interaction.

**Fork considered:** mark only the newest `newChapterCount`; mark all current unread chapters; or
capture and mark the event's ordinals. Capture-and-mark is selected because the count is intentionally
capped, current state can include later releases, and ordinal identity is the existing Work-level
update/read seam.

### Mute semantics and undo

Mute is scoped to the payload Work, is indefinite, and is persisted in the existing
`UpdateStateStore` record as `isMuted`. It suppresses only future system notification delivery:

- refresh continues to run and advances the frontier;
- `newlyDiscovered` and unread/read state are retained;
- in-app Updates continue to show the Work and its “Muted” state;
- already delivered notifications are not retroactively changed, but the pending request for this
  Work is removed after the action succeeds.

The existing `setMuted(_:workId:)` is the persistence seam, but there is no mute UI today: a repo-wide
search found no caller of `setMuted`, and `WorkUpdateRow` currently has no action menu
(`MangaCarta/Views/Components/WorkUpdateRow.swift:3-51`). The app must add new UI in both the Home
`WorkUpdateRow` (`MangaCarta/Views/HomeView.swift:92-114`) and the Library Updates card/context-menu
surface (`MangaCarta/Views/BookmarksView.swift:265-269,335-347`). Each gets “Mute notifications”
or, when muted, “Unmute notifications.” The separate Updates-screen design being revised in parallel
will put the same item in its Work-row trailing menu. Settings may mirror the control, but the row
menus are the primary route. Unmute is explicit and takes effect for the next release only; it does
not replay old `newlyDiscovered` chapters.

**Fork considered:** mute for one week, mute until the current backlog is read, or mute indefinitely.
Indefinite is selected because the shipped model already persists a Boolean, existing copy says
“per-title mute,” and automatic expiry would surprise readers and require a new date/migration.

### Composition, lifetime, and bounded work

Add a small `NotificationActionHandler` owned by `AppComposition`, injected with the shared
`WorkStore`, `HistoryStore`, `UpdateStateStore`, `LibraryStore`, `FulfillmentCoordinator`, and
`SourceRegistry`. `UpdateNotifier` remains responsible
for request construction; the delegate forwards action responses to the handler.

Composition construction remains synchronous and main-actor-owned. The action handler may create a
single structured `Task` for source fetches, but it must retain no detached task after completion and
must honor cancellation. On a cold launch, all stores are loaded before the delegate is assigned;
the delegate closure captures the handler held by `AppComposition`, not a new singleton or a second
store. The completion callback is guaranteed on every branch, including malformed payload, missing
Work, source failure, cancellation, and success.

The handler must finish within the notification action's system window. It may fetch one selected
Listing and its chapter list; it must not run a Library refresh, start `UpdateScheduler`, present a
WebView challenge, or drain unrelated MAL network work. Manual marks write only through
`HistoryStore.markRead(manga:chapters:)`; they do not enqueue MAL progress, as required by the MAL
progress design.

The system can terminate the process after the action window. Therefore the handler flushes
`HistoryStore` and `UpdateStateStore` before calling completion. A successful mark is durable even
if the process ends immediately afterward; an unsuccessful fetch leaves state unchanged.

### Hermetic test drive

Unit tests use the current injected `NotificationScheduling` fake and direct delegate seams. They
  assert the category/action identifiers, captured ordinals, alias resolution, exact Work scoping,
  mute persistence, no-op failure behavior, targeted `newlyDiscovered` cleanup, and that no MAL
  outbox row was written by the manual mark.

The cold/background path is a hermetic UI test on the iPhone 17 Pro simulator:

1. Seed one saved Work and a deterministic source chapter list, with a known `workId`.
2. Write a temporary `.apns` payload containing `Simulator Target Bundle`, `aps.alert`,
   `aps.category: "library-update-actions"`, `workId`, and (for the end-to-end case)
   `discoveredOrdinals`.
3. Deliver it with `xcrun simctl push <device-or-booted> <payload.apns>` while the app is
   backgrounded; repeat after force-quitting to exercise cold composition. The action is selected
   through the simulator notification UI (or the project's existing simulator-driving harness).
4. Relaunch/open Updates and assert that the targeted chapter is read, later discoveries remain
   unread/new, or the Work is visibly muted. The app must not require a network.

The payload may carry only `workId` in the minimal regression fixture, exercising the legacy/fallback
path; the scheduled-request fixture carries ordinals and proves delayed-action scoping. No test
uses `Task.immediate`, isolated conformances, `nonisolated(nonsending)`, or `@concurrent`, so the
design remains buildable by CI's Xcode 16.4 / Swift 6.0 toolchain.

## Data and persistence changes

- Add `discoveredOrdinals` and `actionVersion` to scheduled notification `userInfo` only; do not
  persist a second notification database.
- Add a targeted `UpdateStateStore` operation such as
  `clearNewlyDiscovered(_ ordinals: Set<ChapterOrdinal>, workId:)`. It removes only the supplied
  ordinals, debounces `updates.json`, and leaves `frontier`, `hasBaseline`, `lastSuccessfulCheck`,
  and `isMuted` unchanged.
- Keep `WorkUpdateState.isMuted` as the indefinite per-Work preference in `updates.json`. Existing
  JSON without the new action fields decodes unchanged.
- Persist read marks through `HistoryStore`; no MAL outbox row is written by this action. Never
  encode `isRead` or a notification acknowledgement into `UpdateStateStore`.
- No schema migration is needed beyond Codable defaults; if a future mute duration is accepted,
  add a new optional expiry date and an explicit migration rather than repurposing the Boolean.

## Error and edge cases

- **Several new chapters:** one Work action marks every ordinal captured by that notification, not
  just the displayed count. The cap affects copy only.
- **Several Works:** each notification carries one Work ID; an action never marks or mutes siblings
  in the thread.
- **Later discovery before action:** later ordinals are not in the captured list and remain pending.
- **Merged Work:** resolve aliases before choosing a Listing; the surviving Work receives the action.
- **Removed Work or Listing:** complete without mutation; a stale notification must not recreate a
  Work or mark a different title.
- **Source unavailable/Cloudflare:** do not show an interactive challenge from a background action;
  leave state unchanged and let the user retry in-app.
- **Unread but not newly discovered:** “Mark read” does not touch it. “Mute” does not touch it.
- **Adult title:** action labels contain no title or chapter details; the existing adult-copy policy
  remains unchanged.
- **Duplicate delivery/retry:** manual marking is idempotent, targeted discovery removal is
  idempotent, and mute is idempotent. A repeated action cannot enqueue duplicate read marks.
- **Malformed payload/action identifier:** no crash, no state mutation, completion is called.
- **Process termination:** flush before completion on success; no partial mark on fetch failure.

## Accessibility

Use the system notification action titles “Mark Read” and “Mute”; they are spoken automatically and
must not rely on color. The new mute/unmute controls in Home `WorkUpdateRow` and the Library Updates
card/context menu, plus the parallel Updates-screen trailing menu, are native controls with 44pt
targets and labels that include the Work title and state. The row continues to include “Muted” in
its accessibility value, matching the existing `WorkUpdateSummary.accessibilityLabel` contract
(`MangaCarta/Models/LibraryUpdatesPresentation.swift:23-37`). If the action cannot complete, the app's next visible Updates row should state that the
chapter remains unread and offer the normal chapter-list route; do not announce failure using a
notification containing adult title details.

## Acceptance criteria and tests

1. Scheduled requests register `library-update-actions`, expose both background actions, and carry
   one Work ID plus the event's ordinals. Test: `UpdateNotifierTests.notificationCategoryAndPayload`.
2. One Work with multiple new chapters marks all captured chapters, including a count above the
   notification cap, while a later discovery remains untouched. Test:
   `NotificationActionTests.markReadIsScopedToCapturedOrdinals` in `MangaCartaTests/`.
3. A grouped notification action affects only its payload Work. Test:
   `NotificationActionTests.groupedNotificationsNeverCrossWorkBoundaries`.
4. Mark read uses `HistoryStore.markRead(manga:chapters:)` through the active fulfillment Listing,
   preserves Work-wide ordinal matching, and writes no MAL outbox row, matching the explicit manual-
   mark rule (`docs/superpowers/specs/2026-08-21-mal-oauth-progress-design.md:28,266`). Test:
   `NotificationActionTests.markReadUsesNormalReadPathWithoutMALProgress`.
5. A failed source fetch, missing Work, unavailable Listing, malformed action, or cancellation
   leaves read and newly discovered state unchanged and calls completion. Test:
   `NotificationActionTests.failuresAreNoOpsAndComplete`.
6. Mute persists indefinitely for that Work, suppresses later scheduling, removes its pending
   request, and does not change frontier, newly discovered, unread, or refresh behavior. Test:
   `UpdateStateStoreTests.muteRoundTripsAndRetainsDiscovery` and
   `UpdateNotifierTests.muteActionCancelsPendingRequest`.
7. The new Home `WorkUpdateRow` and Library Updates card/context menu expose accessible mute/unmute
   actions (and the parallel Updates-screen Work-row trailing menu does the same); unmute allows the
   next event and does not replay old events. Hermetic UI test:
   `UpdatesUITests.unmuteRestoresFutureNotifications`.
8. Alias resolution, cold launch, and background delivery use the same composed stores and do not
   create a second registry/store. Test: `AppCompositionTests.coldNotificationActionUsesComposedGraph`.
9. A force-quit/background simulator run driven by an `.apns` payload carrying `workId` proves the
   delegate calls the action and completion without opening a foreground reader. Hermetic UI test:
   `UpdatesUITests.simctlPushMarkReadAction`.
10. VoiceOver announces the muted state and the unmute control; no action depends on color or title
    visibility. Test: `AccessibilityAuditUITests.notificationMuteControlsAreAccessible`.

`MangaCarta/Services/NotificationActionHandler.swift` is under the synchronized `Services` group
and needs no project-file edit. If the implementation creates a new
`MangaCartaTests/NotificationActionTests.swift` or `MangaCartaUITests/NotificationActionsUITests.swift`,
both directories are plain Xcode groups and each new file must be added with `xcp add-file` to its
target; otherwise extend the existing test files and avoid new project entries.

## Owner decisions (2026-11-09)

1. **Mute duration:** “Mute” is indefinite until explicit “Unmute notifications,” matching the
   existing persisted Boolean and per-title mute. No expiry date is added.
2. **Unmute placement:** the primary undo lives in the Home `WorkUpdateRow` and Library Updates card
   context menus, with the same item in the separate Updates-screen Work-row trailing menu; a Settings
   mirror is optional.
3. **Missing ordinals:** an action whose payload lacks `discoveredOrdinals` falls back to the Work's
   current `newlyDiscovered` set, preserving backward compatibility and the requested `workId`-only
   simulator fixture.

## Amendment 1 (2026-11-12): rechecked against `main` at `c722db7`

The design was written before the MAL hub, per-title Sources (#390–#394), detail sections
(#396) and analytics slice 1 (#399) merged. Every claim in "Current code" was grepped again on
`c722db7`. The goal, non-goals and owner decisions all stand. What changes is *how* it is built,
in seven places. Line numbers in "Current code" have drifted; the files and symbols are right
except where listed here.

1. **Don't fetch the `Manga`; build it from the Listing.** `MangaSource.manga(id:)` has a default
   implementation that returns `nil` (`Models/MangaSource.swift:138`). Every Source that doesn't
   override it would make Mark Read a no-op. `HistoryStore.markRead(manga:chapters:)` reads only
   `manga.id` and `manga.sourceId`. So the handler builds the `Manga` from the chosen
   `ListingKey`, the same way `LibraryUpdatesPresentation.summaries` already does, and fetches
   only `chapters(mangaId:)`. One network call, not two.
2. **The completion sink now has two consumers.** `HistoryStore`'s `chapterCompleted` feeds both
   `MALProgressCoordinator` and `AnalyticsRecorder` (`AppComposition.swift:384-389`). A manual mark
   never calls it, so Mark Read writes **no MAL outbox row and no analytics event**. That matches
   chapter-list marks today. AC 4's test asserts both: the outbox is empty and so is the analytics
   buffer.
3. **Composition order.** `UpdateNotificationDelegate` is built at `AppComposition.swift:417`, but
   `fulfillment` doesn't exist until `:542`. The delegate must be built *after* `makeFulfillment`,
   so that it captures a handler holding the composed `FulfillmentCoordinator` and registry.
   Separately, `UpdateNotifier` is constructed **without** `registry:` and falls back to
   `SourceRegistry.shared` (the bug class `CLAUDE.md` names). In production that's the same
   object; under an injected registry (every UI-test fixture), the adult-copy check reads the
   wrong one. This PR passes `resolvedRegistry`, since the notifier is in scope.
4. **Unmute had nowhere to live.** The Home rows show only Works with `newlyDiscoveredCount > 0`
   (`HomeView.swift:100`). The Library "Updates" filter is a chip over the cover grid with the
   same filter (`BookmarksView.swift:342-346`). Opening a title clears `newlyDiscovered`
   (`MangaDetailView.swift:181`, `ChapterListView.swift:208`). So a muted Work vanishes from
   both surfaces as soon as it's opened, and its Unmute goes with it. Decision 2 asks for undo
   from the rows, so:
   - The Home `WorkUpdateRow` gets a context menu with "Mute notifications" / "Unmute
     notifications". It also gets the same item as a named accessibility action, because the
     row is one combined element (`.accessibilityElement(children: .ignore)`).
   - The Library cover card's existing `.contextMenu` (`BookmarksView.swift:87`) gets the same
     item on **every non-Local saved card, under every filter**, not only "Updates". That makes
     Unmute always reachable. Local is excluded from update surfaces, so a Local card shows no
     item.
   - The Updates-screen design isn't built. Its trailing-menu item is out of scope here, and AC 7
     and AC 10 cover only Home and Library.
   - The in-app control writes through `UpdateStateStore.setMuted`. It doesn't touch pending
     requests: muting stops *future* scheduling, which is the promise.
5. **Category registration goes through the scheduling seam.** `NotificationScheduling` gains
   `setCategories(_:)`, so AC 1 can assert the registered category through the existing fake.
   `UpdateNotifier.registerCategories()` is called in `MangaCartaApp.init`, next to the
   delegate assignment, before the scheduler registers.
6. **The background UI test can't use `simctl push`, and the cold path can't be hermetic.** An
   XCUITest runs on the device side and has no host shell, so it can't call `xcrun simctl`. A
   cold background launch also starts the app with **no** launch arguments, so the
   `-uitest-updates-state` fixture wouldn't apply. The action would run against the simulator's
   real stores. So:
   - **AC 9** (`UpdatesUITests.testDeliveredNotificationMarkReadAction`) uses a new fixture state,
     `notification-actions`. It seeds one Work with chapters 1–3 and discovered {2, 3}, then
     schedules a real local notification through `UpdateNotifier.schedule` with a short
     time-interval trigger, carrying captured ordinal {2}. The test sends the app to the
     background, finds the banner through SpringBoard, expands it and taps "Mark Read". It
     asserts the app never came to the foreground. Then it activates the app (same process, no
     relaunch) and asserts chapter 2 is read and 3 is still new. If permission hasn't been
     decided, the test taps the system "Allow" alert. That's always true on CI's fresh simulator.
   - **Cold composition** is proven by the unit test of AC 8
     (`AppCompositionTests.testColdNotificationActionUsesComposedGraph`). It builds a fresh
     `AppComposition` over stores persisted by an earlier one, drives the action through
     `notificationDelegate.receive(actionIdentifier:userInfo:completion:)`, and asserts the
     effect landed in the composed stores and on disk.
   - A manual `simctl push` cold-launch check on the seeded simulator joins the deferred testing
     list in the handoff. It uses the payload in the handoff's 2026-10-07 note, plus
     `aps.category`.
   - The time-trigger fixture is `#if DEBUG` and runs only under `-uitest-updates-state
     notification-actions`.
7. **Test names follow each framework.** The unit suites named in the ACs are Swift Testing
   (`UpdateNotifierTests`, `UpdateStateStoreTests`) and keep their names exactly.
   `NotificationActionTests` is a new Swift Testing suite in a new file (added with `xcp`).
   `AppCompositionTests`, `UpdatesUITests` and `AccessibilityAuditUITests` are XCTest, so their
   names get the `test` prefix: `testColdNotificationActionUsesComposedGraph`,
   `testUnmuteRestoresFutureNotifications`, `testDeliveredNotificationMarkReadAction`,
   `testNotificationMuteControlsAreAccessible`. AC 7's "the next event is scheduled and old ones
   are not replayed" can't be observed from a UI test, so it also gets a unit test,
   `UpdateNotifierTests.unmuteSchedulesNextEventWithoutReplay`. The UI test proves the control
   toggles the row's persisted "Muted" state from both surfaces.

Unchanged and confirmed: `UpdateEvent` is still built in `LibraryRefreshCoordinator.step()` with
the uncapped `released` set in hand; `setMuted`, `clearNewlyDiscovered(workId:)`, `forget`, and
`flush()` exist as described; `FulfillmentCoordinator.chosenListing(for:)` is cache-only and
honors the pin; `HistoryStore.markRead(manga:chapters:)` is one save and idempotent; there is
still no `setNotificationCategories`, action identifier, or `.apns` file in the repository.
