# Home Screen widgets (and why no Live Activity) — Design

- **Status:** Draft for owner review (2026-11-09). Handoff feature queue item 5.
- **Builds on:** ADR-0001 (Work identity), ADR-0021 (background refresh + notifications), ADR-0022
  (adult content), ADR-0027 (read state is per Work), the background-refresh design
  (`2026-08-24-adr-0021-background-refresh-design.md`), which deferred "Widgets and Live
  Activities" at its "Explicitly deferred" list (line 459).

## Goal

Two Home Screen widgets that turn the app's existing reading and update state into something the
reader sees without opening the app:

1. **Continue Reading** — the saved Works the reader touched most recently, with where they are.
2. **New Chapters** — saved Works with newly discovered chapters (ADR-0021's `newlyDiscovered`).

Both in `systemSmall` and `systemMedium`. Tapping one opens that Work's detail page through the
same route a new-chapter notification uses (`WorkNavigator`).

The widget is a **reader of a small snapshot file** the app writes into an App Group container. It
never opens the app's stores, never touches the network, and never runs a refresh of its own.

## Non-goals

- **No Live Activity.** Reasoned in §8; the conclusion is "no", with a named revisit trigger.
- No lock-screen accessory families (`accessoryRectangular` / `accessoryCircular` /
  `accessoryInline`), no `systemLarge`, no iPad `systemExtraLarge`. See open question 3.
- No configurable widget (`AppIntentConfiguration` / choosing which Works). Both widgets are
  `StaticConfiguration`. Configurable selection is a later decision once the static ones are used.
- No interactive widget buttons ("Mark read" on the widget, iOS 17 `Button(intent:)`). A write
  from the extension would need the app's stores, which this design deliberately keeps out of it.
- No widget-driven refresh. The widget does not fetch; its freshness is exactly the app's
  (ADR-0021's best-effort background refresh plus activation).
- No cross-device anything (there is no sync).
- No change to `HistoryStore`'s persistence or to `UpdateStateStore`'s format.

## Current code this builds on

Every reference below was opened for this spec.

**Identity and routing**

- `WorkID` is a `UUID` box (`MangaCarta/Models/Work.swift:15-19`); a `Work` has `displayTitle`,
  `listings` and an optional `snapshot` (`Work.swift:112-127`).
- `WorkNavigator` is the notification route: one `@Published var requestedWork: WorkID?` and
  `open(_:)` (`MangaCarta/Services/WorkNavigator.swift:7-14`). `ContentView` switches to the
  Library tab when it is set (`MangaCarta/ContentView.swift:101-105`), and `BookmarksView` pushes
  `MangaDetailView` for it (`MangaCarta/Views/BookmarksView.swift:175-179`, binding at `:323-333`).
- **`BookmarksView` only answers for a Work that is still saved.** The binding resolves the Work
  through `LibraryUpdatesPresentation.summaries`, which is built from `library.items`
  (`BookmarksView.swift:336-341`; `MangaCarta/Models/LibraryUpdatesPresentation.swift:49-64`), and
  a request for an unsaved Work is dropped (comment at `BookmarksView.swift:180-181`). This is the
  constraint that makes both widgets **saved-Works-only** (§2).
- The notifier resolves a possibly-merged Work id before opening it:
  `works.work(WorkID(raw: uuid))?.id` (`MangaCarta/Services/UpdateNotifier.swift:133-140`). The
  widget link must do the same.
- `ContentView.onOpenURL` currently hands **every** URL to the local importer
  (`ContentView.swift:110-112`), which ignores non-file URLs (`MangaCarta/Models/LocalImportViewModel.swift:128-132`).
- The registered URL scheme is `mangareader` (`MangaCarta/Info.plist:32-42`), used today only as
  the MAL OAuth redirect `mangareader://oauth/mal` (`MangaCarta/Services/AppComposition.swift:179`),
  which `ASWebAuthenticationSession` consumes itself (`MALAccountStore.swift:408`).

**State the snapshot is built from**

- `HistoryStore.entries` is newest-first `[ReadingEntry]` (`MangaCarta/Services/HistoryStore.swift:118`;
  `latestEntry(forMangaIds:)` relies on that ordering, `:207-212`). A `ReadingEntry` carries
  `mangaId`, `mangaTitle`, `coverURL`, `chapterNumber`, `page`, `pageCount`, `updatedAt`, `sourceId`
  (`:15-36`) and `isComplete` (`:51`). `unreadCount(for: LibraryItem)` is the Library badge's count,
  per Work (`:267-273`).
- Reading positions are **throttled**: `record` calls `saveSoon()` (`:192`, `:423-430`), and the
  app flushes on `.background` (`MangaCarta/MangaCartaApp.swift:296`).
- `WorkUpdateState` has `newlyDiscovered: Set<ChapterOrdinal>`, `newestDiscoveryAt`, `isMuted`
  (`MangaCarta/Services/UpdateStateStore.swift:10-17`). `WorkUpdateSummary` already joins Works,
  Library, history and update state into a per-Work row with `unreadChapterCount`,
  `newlyDiscoveredCount`, `newestDiscoveryAt`, `isMuted` and `displayManga`
  (`LibraryUpdatesPresentation.swift:11-20`, `:49-90`). **The New Chapters snapshot is built from
  these summaries**, not from a second join.
- `LibraryItem` has `id`, `title`, `coverURL`, `sourceId` (`MangaCarta/Services/LibraryStore.swift:12-18`).

**When state changes**

- `LibraryRefreshCoordinator.run(budget:)` is the one pipeline for foreground, pull-to-refresh and
  background runs (`MangaCarta/Services/LibraryRefreshCoordinator.swift:66-88`); it already takes a
  per-Work hook, `didProcessWork` (`:40`, `:56`, `:83`). Foreground runs are started from
  `startForeground` (`:145-159`); background runs from `UpdateScheduler.handle`, which flushes
  stores and then calls `setTaskCompleted` (`MangaCarta/Services/UpdateScheduler.swift:113-128`).
- The `.background` scene phase already stops refresh and flushes `works`, `updates` and `history`
  (`MangaCartaApp.swift:277-298`), then calls `scheduler.scheduleNext`.

**Adult-content policy**

- Notification copy: `UpdateNotifier.body(for:hidesAdultDetails:)` returns the generic
  **"A followed title has new chapters"** when details are hidden (`UpdateNotifier.swift:94-99`).
  `hidesAdultDetails(for:)` hides when the "Show adult content" switch is **off** and **any** linked
  Listing's Source is `isNSFW || declaresAdultTitles` — "deliberately over-suppress"
  (`:141-152`). The switch is `AdultContentSetting.key = "settings.showAdultSources"`
  (`MangaCarta/Models/AdultContentFilter.swift:25-30`).
- ADR-0021 states the reason: "the lock screen is a shared surface" (§"Notification permission is
  contextual"). ADR-0022 Amendments 1–2 put adult Sources behind a default-off gate and a
  declared-age confirmation.
- Observed while reading: `AppComposition` constructs `UpdateNotifier` **without** passing the
  injected registry (`AppComposition.swift:326-330`), so its adult check reads `SourceRegistry.shared`
  (`UpdateNotifier.swift:70`). In production that is the same object (`resolvedRegistry = registry ?? .shared`,
  `AppComposition.swift:296`), but it is the pattern CLAUDE.md calls a bug. The widget builder takes
  the injected registry, and slice 2 passes it to the notifier too (one-line fix, same PR).

**Covers**

- `ImageCache` keeps a memory tier, a disk tier under `Caches/PageImageCache`, and the network
  (`MangaCarta/Services/ImageCache.swift:144-165`, `loadImage` at `:224-262`); file URLs (local
  imports' covers) are read directly (`:226-230`). It lives in the **app's** sandbox, so the widget
  extension cannot read it. The graph's instance is `AppComposition.imageCache` (`:101-103`, `:448`).
- `LocalLibraryStore` already renders thumbnails with `UIGraphicsImageRenderer` +
  `jpegData(compressionQuality:)` (`MangaCarta/Services/LocalLibraryStore.swift:330-331`) — the
  same technique the cover renderer uses.

**Project**

- Three targets today — app, unit tests, UI tests (`MangaCarta.xcodeproj/project.pbxproj:494-549`),
  `objectVersion = 70` (`:6`). The app target's synchronized groups are `Components`, `Services`,
  `Models` (`:505-509`). App bundle id `Elias-Magdaleno.Manga-Reader`, team `V2BG9SHQYS`, automatic
  signing, `SWIFT_VERSION = 5.0`, `TARGETED_DEVICE_FAMILY = "1,2"`, iOS 17.5 (`:817`, `:892-913`).
- **There is no entitlements file in the repository** (`find . -name '*.entitlements'` is empty)
  and no `CODE_SIGN_ENTITLEMENTS` setting. Nothing in `MangaCarta/`, the tests or `docs/` mentions
  `WidgetKit`, `ActivityKit` or `containerURL(forSecurityApplicationGroupIdentifier:)` (grepped; the
  one hit is an archived handoff).
- `xcp` 1.2.1 has no "add target" command (`xcp --help`: targets are list/set only), so the new
  target is created in Xcode.
- The design tokens live in `MangaCarta/Views/Components/Theme.swift` (`Ink` at `:39-60`), which
  imports only SwiftUI and UIKit and depends on nothing else in the app.
- CI builds and tests on `macos-15` (Xcode 16.4) with plain `xcodebuild -scheme MangaCarta`
  against a simulator, no signing overrides (`.github/workflows/ci.yml:175-179`, `:241-250`).

## Design

### 1. Shape: a snapshot file, two widget kinds, one extension

```
App (main actor)                         App Group container
───────────────────                      group.Elias-Magdaleno.Manga-Reader/
LibraryRefreshCoordinator ─┐               Library/Application Support/Widgets/
scenePhase .background ────┼─► WidgetSnapshotPublisher ──► snapshot.json
                           │     builds from stores,            covers/<work>-<hash>.jpg
                           │     renders covers, writes,
                           │     WidgetCenter.reloadTimelines
                                                                   ▲ read-only
                                         MangaCartaWidgets.appex ──┘
                                           ContinueReadingWidget, NewChaptersWidget
```

Options considered for how the widget gets data:

- **(a) Snapshot file in the group container — chosen.** The app decides what is shown (including
  the privacy redaction) and the extension renders it. Small, versioned, testable from the app's
  unit tests.
- (b) Move `works.json`, `updates.json` and history into the group container and let the widget
  read the real stores. Rejected: the widget would need to compile and run `WorkStore`,
  `HistoryStore`, `UpdateStateStore` and `SourceRegistry` (the adult check needs the registry); it
  migrates every store's location for a read-only consumer; and the privacy decision would run in a
  process that can't see the Settings switch's effect on installed Sources.
- (c) A shared `UserDefaults(suiteName:)`. Rejected: same content as (a) without atomic file
  replacement, and `UserDefaults` is a required-reason API that would need a privacy manifest in the
  extension too. Files don't.

### 2. What the widgets show

Both lists contain **saved Works only** — a Work with at least one Listing in `library.items`. This
is not a taste choice: `WorkNavigator`'s only consumer drops requests for unsaved Works (above), so
an unsaved Work in the widget would be a tap that silently goes nowhere. (Open question 1 offers
the alternative.)

**Continue Reading.** Saved Works ordered by their newest `ReadingEntry.updatedAt` across the Work's
Listings (newest first), up to 4. Each row:

- title (`Work.displayTitle`), cover;
- if the newest entry is not `isComplete`: "Ch. 12 · p. 8/20" (`page + 1` of `pageCount`; page
  omitted when `pageCount == 0`);
- if it is complete: "Ch. 12 read · 3 unread" from `history.unreadCount(for:)`, or "Ch. 12 read ·
  caught up" at 0;
- last-read time as `Text(date, style: .relative)` (updates itself, costs no reload).

Saved Works the reader never opened are not in this list — "continue" needs a place to continue
from.

**New Chapters.** `LibraryUpdatesPresentation.summaries` filtered to `newlyDiscoveredCount > 0` and
`!isMuted`, ordered by `newestDiscoveryAt` descending, up to 4, plus the total count of such Works.
Row: title, cover, "2 new chapters", discovery time relative. Muted Works are excluded because mute
means "don't tell me outside the app" (ADR-0021 §"Notification permission"); the in-app Updates
filter still shows them. (Open question 2.)

**Sizes.**

| | systemSmall | systemMedium |
|---|---|---|
| Continue Reading | the top Work: cover left third, title (2 lines), progress line | up to 3 rows: cover thumbnail, title, progress |
| New Chapters | the top Work's cover + title + "N new", footer "+3 more" if total > 1 | up to 3 rows; footer "N titles have new chapters" |

Empty states (Ink & Seal, `InkEmptyState` voice): "Nothing in progress — open a saved title to see
it here" and "No new chapters yet". A snapshot that is missing or unreadable renders the empty
state, never a crash or stale fake data. `placeholder(in:)` uses redacted (`.redacted(reason: .placeholder)`)
dummy rows.

**Visual system.** `containerBackground(Ink.background, for: .widget)` (required on iOS 17),
`Ink.primary` titles in the display serif, metadata in SF Mono per `DESIGN.md` typography,
`Ink.seal` used once per widget — the "N new" stamp in New Chapters, nothing in Continue Reading
except the progress hairline. Covers clip at `rounded.cover` (8pt). `Theme.swift` moves into the
shared folder (§4) so the widget uses the same tokens rather than copies.

**Tap targets.** `systemSmall`: `.widgetURL(link)` for the shown Work (the whole widget is one
target — iOS gives small widgets no per-row links). `systemMedium`: one `Link(destination:)` per
row; the footer and empty state use `widgetURL` to `mangareader://widget/library` (opens the
Library tab, §5).

### 3. The snapshot

**App Group id:** `group.Elias-Magdaleno.Manga-Reader`. It follows the bundle id, which is
deliberately **not** renamed with the app (ADR-0023; memory note "App named MangaCarta"). Using
`group.com.mangacarta…` or similar would be a second identity scheme for one app.

**Location:** `<group container>/Library/Application Support/Widgets/snapshot.json`, covers in
`…/Widgets/covers/`. Written with `.atomic` and file protection
`.completeUntilFirstUserAuthentication` — **not** `.complete`, because the widget is rendered while
the device is locked (StandBy, and the system's background re-render), and `.complete` would make
the file unreadable exactly then.

**Format (version 1)** — `MangaCartaShared/WidgetSnapshot.swift`, compiled into both targets:

```swift
struct WidgetSnapshot: Codable, Equatable {
    static let currentVersion = 1
    let version: Int
    let generatedAt: Date
    let continueReading: [WidgetWorkRow]   // ≤ 4
    let newChapters: [WidgetWorkRow]       // ≤ 4
    let newChaptersTotal: Int              // Works with new chapters, incl. ones past the cap
}

struct WidgetWorkRow: Codable, Equatable, Identifiable {
    let workId: UUID
    /// nil when redacted (§6). The widget never sees a hidden title.
    let title: String?
    let isRedacted: Bool
    let progress: Progress?                // Continue Reading only
    let newChapterCount: Int               // New Chapters only, 0 otherwise
    let date: Date                         // last read, or newest discovery
    /// File name inside covers/, or nil (no cover, not yet rendered, or redacted).
    let coverFile: String?
    var id: UUID { workId }

    enum Progress: Codable, Equatable {
        case inChapter(chapter: String, page: Int, pageCount: Int)   // page is 1-based here
        case finishedChapter(chapter: String, unread: Int)
    }
}
```

Only the fields drawn on screen. No Listing keys, source ids, URLs or chapter ids leave the app.
A decoder that sees `version > currentVersion` treats the file as missing (empty state) — an
older extension never misreads a newer app's file; in practice both ship in one bundle.

Size: ≤ 8 rows of short strings — under 4 KB.

**Builder** — `MangaCarta/Services/WidgetSnapshotBuilder.swift` (synchronized group; no `xcp`): a
`@MainActor` value with one function, `build(now:) -> WidgetSnapshot` plus the list of covers it
wants, reading `WorkStore`, `LibraryStore`, `HistoryStore`, `UpdateStateStore`, the injected
`SourceRegistry` and the injected `UserDefaults` (for the adult switch). Pure apart from reading
those stores, so the unit tests drive it with the stores they already construct.

### 4. Covers

The extension cannot use `ImageCache` — it is the app's sandbox and the app's process — and a widget
must not do network work of its own. So the app pre-renders thumbnails into the group container.

- **Source of pixels:** `AppComposition.imageCache.loadImage(for:)` with **no** `reportTarget`
  (covers never report — CLAUDE.md "Image-load reports"). In practice the cover is in the disk tier
  because the reader just saw it in Library/History; a local import's cover is a file URL. If the
  load fails, the row has `coverFile = nil` and renders the `Ink.surfaceAlt` placeholder with the
  book symbol. **The renderer must not be the reason for a network request during a background
  run**: in a `.background(...)` budget it first asks `imageCache.image(for:)` and the disk tier
  only; a cover that would need the network waits for the next foreground publish. (This needs a
  small `ImageCache` addition, `cachedImage(for:) async -> UIImage?` = memory → disk/file, no
  network, which the renderer uses in background runs.)
- **Size:** fit within **240 × 360 px** (2:3, the cover aspect), JPEG quality 0.7. Target ≤ 48 KB
  per file; if over, re-encode at 0.5; if still over, drop the cover. Reasoning: the largest row
  thumbnail is ~56×84 pt and the small widget's cover ~110×165 pt; 240×360 covers both at 2× and
  the row at 3×. Decoded, 240×360×4 B ≈ 340 KB per image, ≤ 8 images ≈ 2.7 MB — far inside a widget
  extension's memory limit (about 30 MB), which is the real constraint: oversized images in a
  widget fail to render with no error.
- **At most 8 files** (4 + 4, de-duplicated when a Work is in both lists); total ≤ 384 KB.
- **Name:** `<workId>-<first 12 hex of SHA256(coverURL)>.jpg`. A file whose name already exists is
  not re-rendered — the name changes exactly when the Work or its cover URL does.
- **Garbage collection:** after `snapshot.json` is written, delete every file in `covers/` the new
  snapshot does not reference.
- **Redacted rows never get a cover file**, and an existing one for that Work is deleted by the GC
  above on the same publish (§6).

Rendering runs off the main actor: the builder hands `(URL, fileName)` pairs to a nonisolated
`WidgetCoverRenderer` that uses `UIGraphicsImageRenderer` exactly as `LocalLibraryStore.swift:330`
does, inside a plain `Task.detached(priority: .utility)`. No isolated conformances,
`nonisolated(nonsending)`, `@concurrent` or `Task.immediate` — all unavailable on CI's Swift 6.0.

### 5. Publishing and reloads

`WidgetSnapshotPublisher` (`MangaCarta/Services/WidgetSnapshotPublisher.swift`, `@MainActor`, one
instance in `AppComposition`, exposed as `composition.widgetSnapshots`):

```swift
@MainActor protocol WidgetReloading { func reloadAllTimelines() }   // WidgetCenter adapter
```

`publish(budget: RefreshBudget)`:

1. `let snapshot = builder.build(now:)`.
2. Encode. **If the bytes equal the last written bytes, stop** — no write, no reload.
3. Write `snapshot.json` atomically; reload timelines (`WidgetCenter.shared.reloadAllTimelines()`
   via the adapter — two kinds, both read the same file, so "all" is exact).
4. Render missing covers; GC; if any cover was added, write the snapshot again with the new
   `coverFile`s and reload once more. Step 3 comes first so text is current even if the cover pass
   is cut short by a background deadline.

The container URL comes from `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`.
**If it is `nil`** (entitlement missing, a misconfigured build), `publish` is a no-op that logs once
in DEBUG — the app never fails because the widget can't be fed. Tests inject a directory instead.

**Triggers — exactly two:**

1. **End of every refresh run.** `LibraryRefreshCoordinator` gains `didFinishRun: (RefreshBudget) -> Void`,
   nil-defaulted beside `didProcessWork` (`LibraryRefreshCoordinator.swift:40`, `:56`), called at
   the end of `run(budget:)` **unless** the task was cancelled. Composition wires it to
   `publisher.publish(budget:)`. This is the trigger that matters most: a background run happens
   while the reader is on the Home Screen. It runs before `UpdateScheduler.handle` calls
   `setTaskCompleted` because `run` returns first (`UpdateScheduler.swift:117-124`), and step 3's
   JSON write is synchronous, so it lands inside the background window.
2. **Scene `.background`**, after the existing `history.flush()` / `updates.flush()`
   (`MangaCartaApp.swift:290-296`): `widgetSnapshots.publish(budget: .foreground)`.

That second trigger is how **reading** reaches the widget, and it is deliberately the only way.
`HistoryStore.record` runs on every throttled page turn; publishing from it would rewrite the file
and request a reload every couple of seconds while the reader is reading — when the widget isn't on
screen. Everything else that changes the widgets' content also happens with the app in the
foreground and is picked up by the same trigger: marking read/unread, deleting history, viewing a
chapter list (which clears `newlyDiscovered`), saving or removing a Work, muting, toggling the adult
switch. **So `HistoryStore` needs no change**, and there is no second, competing "after reading"
hook. The one gap is iPad multitasking, where the Home Screen can't be seen beside the app anyway.

**Reload budget.** WidgetKit gives an app a daily reload budget (Apple documents it as roughly
40–70) and does not count reloads requested while the app is in the foreground. Background runs
are "a few per day" (ADR-0021) and each causes at most two reloads, and only when the bytes changed.

**Timeline.** Each provider returns one entry from the file with policy `.never`; the app is the
only thing that knows when data changed. Relative dates tick on their own.

**Deep links.** `MangaCartaShared/WidgetDeepLink.swift`:

- `mangareader://widget/work/<uuid>` — open that Work.
- `mangareader://widget/library` — open the Library tab.

Reusing the `mangareader` scheme with a `widget` host avoids registering a second scheme; the OAuth
redirect uses host `oauth` and never reaches `onOpenURL`. `ContentView.onOpenURL` checks
`WidgetDeepLink.parse(url)` first and falls through to the importer for everything else:

```swift
.onOpenURL { url in
    switch WidgetDeepLink.parse(url) {
    case .work(let raw):  if let id = works.work(WorkID(raw: raw))?.id { workNavigator.open(id) }
                          else { selectedTab = .bookmarks }
    case .library:        selectedTab = .bookmarks
    case nil:             localImporter.importOpenedURL(url)
    }
}
```

`works.work(_:)` resolves a merged id exactly as `UpdateNotifier.handleResponse` does
(`UpdateNotifier.swift:136`). `ContentView` adds `@EnvironmentObject works: WorkStore` (already in
the environment, `MangaCartaApp.swift:190`). From `workNavigator.open` the path is the shipped
notification path, unchanged. A Work that was unsaved after the snapshot was written lands on the
Library tab, which is `BookmarksView`'s existing behaviour for a stale request.

### 6. Adult-content privacy

A widget is a shared surface, more so than a notification: it sits on the Home Screen for days, and
on iOS 17 a `systemSmall` widget also appears in **StandBy, on a locked phone**. So the widget
follows the notification policy exactly, and is stricter where a widget shows more.

- **One predicate.** Extract `UpdateNotifier.hidesAdultDetails(for:)` (`UpdateNotifier.swift:141-152`)
  into `AdultSurfacePrivacy.hidesDetails(for work: Work, registry: SourceRegistry, defaults: UserDefaults) -> Bool`
  in `MangaCarta/Models/`, unchanged in behaviour (switch off **and** any Listing's Source
  `isNSFW || declaresAdultTitles`). The notifier and the builder both call it, so the two surfaces
  cannot drift.
- **Additionally**, the builder redacts a row whose displayed Listing has an adult
  `contentRating` (`AdultContentFilter.adultRatings`, `AdultContentFilter.swift:14`) — a `none`
  Source can still label one Listing `erotica` (ADR-0022 Amendment 1). The notifier doesn't have the
  rating at hand; the builder does, via `displayManga.contentRating`. Over-suppressing is the
  existing stance.
- **A redacted row** carries `title = nil`, `progress = nil`, `coverFile = nil`, `isRedacted = true`
  and renders as the generic book symbol with **"A followed title"** (Continue Reading) or
  **"A followed title has new chapters"** (New Chapters — the notification's exact string). The
  count is kept (it reveals nothing) and the deep link is kept (opening requires unlocking the app,
  as with a notification tap).
- **With the "Show adult content" switch on**, rows show details, as notifications do. Note the
  switch is reachable only after the declared-age gate (ADR-0022 Amendment 2).
- **Defense in depth:** titles and covers carry `.privacySensitive()`, so the system redacts them
  when the reader has turned off widget data on the lock screen or StandBy.
- **Turning the switch off** is picked up at the next `.background` publish, which also deletes the
  now-redacted Work's cover file via GC.

### 7. Project and target work

This is the part `xcp` cannot do. Slice 1 is only this, so a broken target never ships with
logic in it.

1. **Create the target in Xcode 26** (File ▸ New ▸ Target ▸ Widget Extension): product name
   `MangaCartaWidgets`, **uncheck "Include Live Activity" and "Include Configuration App Intent"**,
   embed in `MangaCarta`. This writes the `PBXNativeTarget` (`com.apple.product-type.app-extension`),
   the **Embed Foundation Extensions** copy-files phase on the app target, the target dependency,
   and a synchronized folder `MangaCartaWidgets/`. Then set by hand:
   - bundle id `Elias-Magdaleno.Manga-Reader.Widgets`; team `V2BG9SHQYS`; automatic signing;
   - `IPHONEOS_DEPLOYMENT_TARGET = 17.5`, `SWIFT_VERSION = 5.0`, `TARGETED_DEVICE_FAMILY = "1,2"`,
     `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` equal to the app's (App Store validation
     rejects a mismatch);
   - no `Secrets.xcconfig` base configuration — the extension needs no secrets.
2. **App Group capability on both targets** (Signing & Capabilities ▸ + App Groups ▸
   `group.Elias-Magdaleno.Manga-Reader`). This creates the first entitlements files in the repo:
   `MangaCarta/MangaCarta.entitlements` and `MangaCartaWidgets/MangaCartaWidgets.entitlements`,
   each containing only `com.apple.security.application-groups`, and sets `CODE_SIGN_ENTITLEMENTS`
   for both configurations of both targets. Automatic signing registers the group under the team.
3. **Shared folder** `MangaCartaShared/` added as a synchronized folder whose membership is **both**
   targets (it appears in both `fileSystemSynchronizedGroups` lists). It holds `WidgetSnapshot.swift`,
   `WidgetDeepLink.swift`, `WidgetRowPresentation.swift` (the strings and accessibility labels, §9),
   and `Theme.swift` moved with `git mv` from `MangaCarta/Views/Components/` (it imports only
   SwiftUI/UIKit). Everything in it must compile without the app's other types.
4. **Delete the template's sample code** (the generated `SimpleEntry` / emoji widget and any
   `…Control.swift` / `…LiveActivity.swift` the template adds despite the checkboxes).
5. **Check the diff before `git add`.** Xcode 26 may raise `objectVersion` (currently 70). CI's
   Xcode 16.4 reads up to 77; anything higher fails on CI only. If it was raised, set it back to 70
   (or 77) and confirm Xcode still opens the project. Expect the synchronized-group reformat churn
   CLAUDE.md describes; keep or revert it deliberately.

**How CI builds it.** Nothing in `ci.yml` changes: the extension is a dependency of the `MangaCarta`
scheme's app target, so `xcodebuild -scheme MangaCarta … test` builds and embeds it. Simulator
builds sign locally without provisioning profiles, and the simulator honours the App Group
entitlement. That is the expectation, **not yet verified on this CI** — which is why slice 1's
acceptance is a green CI run and a unit test that the container resolves on the simulator (AC 1). If
CI's unsigned simulator build turns out not to provide the container, the design still holds
(`publish` is a no-op on `nil`) and only AC 1 moves from CI to local.

**Files that need `xcp add-file`** (non-synchronized groups): every new file in `MangaCartaTests/`
and `MangaCartaUITests/` (§10). New files in `Models/`, `Services/`, `MangaCartaShared/` and
`MangaCartaWidgets/` need nothing. `ContentView.swift` and `MangaCartaApp.swift` are edits, not new
files. No new file in `Views/`.

### 8. Live Activity: no

A Live Activity is for an ongoing, time-bounded event the reader is waiting on while away from the
app. Candidates in this app, today:

- **A background refresh run.** Up to ~30 s, scheduled by iOS, invisible by design (ADR-0021: no
  cadence promise). ActivityKit activities can only be **started** from the foreground; a run the
  reader didn't start and can't see begin is not something to follow. The result is already
  surfaced — as a notification and, now, the New Chapters widget.
- **A foreground refresh.** Seconds long, and the reader is looking at the app while it runs.
- **A long local import.** The only real candidate. It already has an in-app banner with cancel
  (`ContentView.swift:106-109`, `LocalImportViewModel`), it is reader-started in the foreground, and
  it is CPU-bound copying/unzipping that iOS suspends shortly after backgrounding — there is no
  `beginBackgroundTask` around it (grep finds none). A Live Activity showing progress that stops when
  the app is suspended would be a progress bar that lies.
- **Reading session / chapter progress.** Not an event anyone waits on.

Cost if built anyway: `NSSupportsLiveActivities` in the app's Info.plist, an `ActivityConfiguration`
in the extension, Dynamic Island layouts, push-token plumbing for remote updates or none at all, and
another lock-screen surface to run the §6 privacy rules over.

**Revisit trigger:** offline chapter downloads that continue in a background `URLSession` (nothing
like it exists today — no download feature in `MangaCarta/` or the ADRs). That is a long,
reader-started, genuinely-continuing event, and the right moment to reopen this.

## Data and persistence changes

- **New:** `group.Elias-Magdaleno.Manga-Reader` container; `Widgets/snapshot.json` (format v1,
  above) and `Widgets/covers/*.jpg`. Both are **derived caches**: deleting them loses nothing and the
  next publish recreates them. No migration, no backup significance.
- **Unchanged:** `works.json`, `updates.json`, history in `UserDefaults.standard`, the app's
  `ImageCache` directories. Nothing moves into the group container.
- **New entitlements files** (first in the repo), as §7.
- **Code changes:** `LibraryRefreshCoordinator` gains `didFinishRun`; `UpdateNotifier` uses the
  extracted predicate and receives the injected registry; `ImageCache` gains a cache-only lookup;
  `ContentView.onOpenURL` routes widget links; `MangaCartaApp`'s `.background` case calls publish;
  `AppComposition` builds and wires the publisher.

## Errors and edge cases

| Case | Behaviour |
|---|---|
| Group container `nil` | `publish` is a no-op; widgets show their empty state. App unaffected. |
| `snapshot.json` missing, corrupt, or newer `version` | Widget renders the empty state. |
| Cover file missing (GC race, failed render) | Placeholder cover. The widget never reads a URL. |
| Background deadline hits during the cover pass | JSON was already written (step 3); covers come next publish. |
| Refresh run cancelled (scene backgrounding) | `didFinishRun` not called; the `.background` publish right after covers it. |
| Work merged after the snapshot was written | Link resolves through `works.work(_:)` to the surviving Work. |
| Work unsaved, or deleted, after the snapshot | Link lands on the Library tab; next publish drops the row. |
| Library empty / nothing read | Both empty states; New Chapters footer hidden. |
| A Work in both lists | Appears in both; one cover file serves both. |
| Adult switch toggled | Next publish re-redacts or un-redacts and GCs covers. |
| Title very long | 2-line limit, tail truncation; full title in the accessibility label. |
| Local-import Work | Cover from its file URL; counts as saved like any other. |
| Device locked, before first unlock after reboot | File unreadable (`completeUntilFirstUserAuthentication`); system shows the last render or placeholder. Acceptable. |
| A Listing's Source uninstalled/disabled | Row still shows (history and state are kept, per CLAUDE.md); the detail page then shows the existing "unavailable" handling. |

## Accessibility

- Each row is one accessibility element (`.accessibilityElement(children: .combine)`) with a label
  from `WidgetRowPresentation`, one spoken sentence like the History row's
  (`HistoryView.swift:180`): "Dandadan, chapter 12, page 8 of 20, read 2 hours ago" /
  "Dandadan, 2 new chapters". A redacted row: "A followed title has new chapters". No "CH·", dots or
  slashes in spoken text.
- Dynamic Type: widgets scale within system limits; layouts use `ViewThatFits` to drop the
  relative-date line before truncating the title, and the medium widget drops to 2 rows at
  accessibility sizes.
- Colour: only `Ink` tokens, which already meet contrast in both appearances (DESIGN.md); the "new"
  stamp is not colour-only (it has the count as text).
- `.widgetAccentable()` on titles so the tinted/clear Home Screen modes keep hierarchy, and covers
  use `.widgetAccentedRenderingMode(.fullColor)` behind `#available(iOS 18.0, *)`, like the app's
  existing iOS 18 branches.
- Each `Link` has an accessibility hint "Opens in MangaCarta".

## Acceptance criteria → tests

Unit tests go in `MangaCartaTests/` (new files need `xcp add-file … --targets MangaCartaTests`). The
widget extension itself can't be `@testable import`ed from a test bundle hosted in the app, which is
why every decision lives in the app module or `MangaCartaShared/` (compiled into the app too) and
the extension is thin views.

| # | Criterion | Test |
|---|---|---|
| 1 | On the iPhone 17 Pro simulator, the app resolves the App Group container. | `WidgetSnapshotStoreTests.testAppGroupContainerResolves` |
| 2 | Continue Reading lists saved Works only, newest read first, at most 4. | `WidgetSnapshotBuilderTests.testContinueReadingIsSavedWorksByRecency` |
| 3 | Progress is "in chapter" with 1-based page for an incomplete entry, "finished · N unread" for a complete one, and reads across a Work's Listings. | `WidgetSnapshotBuilderTests.testProgressReflectsNewestEntryAcrossListings` |
| 4 | New Chapters lists Works with `newlyDiscovered`, excludes muted, sorts by discovery, caps at 4 and reports the true total. | `WidgetSnapshotBuilderTests.testNewChaptersFromUpdateSummaries` |
| 5 | With the adult switch off, a Work on an adult-declaring Source is redacted: no title, no progress, no cover file; with it on, details show. | `WidgetSnapshotBuilderTests.testAdultSourceWorkIsRedactedUnlessSwitchOn` |
| 6 | A Listing rated `erotica`/`pornographic` on a `none` Source is redacted too. | `WidgetSnapshotBuilderTests.testAdultRatedListingIsRedacted` |
| 7 | Notifier and builder share one predicate; existing notifier behaviour is unchanged. | `AdultSurfacePrivacyTests` + existing `UpdateNotifierTests` unchanged and green |
| 8 | Publish writes `snapshot.json` that round-trips, then requests one reload. | `WidgetSnapshotPublisherTests.testPublishWritesAndReloads` (spy `WidgetReloading`, temp dir) |
| 9 | Publishing identical content writes nothing and does not reload. | `WidgetSnapshotPublisherTests.testUnchangedSnapshotDoesNotReload` |
| 10 | A `nil` container makes publish a no-op without throwing. | `WidgetSnapshotPublisherTests.testMissingContainerIsNoOp` |
| 11 | Covers fit 240×360 px and ≤ 48 KB; unreferenced cover files are deleted; redacted rows get none. | `WidgetCoverRendererTests.testCoverSizeLimits`, `WidgetSnapshotPublisherTests.testCoverGarbageCollection` |
| 12 | A background-budget publish never requests a cover from the network. | `WidgetCoverRendererTests.testBackgroundPublishUsesCacheOnly` (fetch spy on an injected `ImageCache`) |
| 13 | A decoder treats a newer-version file as absent. | `WidgetSnapshotTests.testNewerVersionDecodesAsEmpty` |
| 14 | `didFinishRun` fires once per completed run, with its budget, and not for a cancelled run. | `LibraryRefreshCoordinatorTests.testDidFinishRunFiresOnCompletionOnly` |
| 15 | The composition builds one publisher and wires the refresh hook to it. | `AppCompositionTests.testWidgetPublisherIsWiredOnce` |
| 16 | Widget links round-trip; the OAuth URL, file URLs and malformed UUIDs parse as `nil`. | `WidgetDeepLinkTests` |
| 17 | Spoken labels for each row shape, including redacted, contain no glyph abbreviations. | `WidgetRowPresentationTests` |
| 18 | A widget link for a saved Work opens its detail page; a link for an unknown Work lands on Library without crashing. | **Hermetic UI:** `WidgetDeepLinkUITests` (below) |

**What replaces a widget UI test.** XCUITest cannot drive the Home Screen to add or tap a widget,
so no hermetic test renders one. In its place:

- **The deep-link half is tested hermetically.** `MangaCartaUITests/WidgetDeepLinkUITests.swift`
  (needs `xcp add-file … --targets MangaCartaUITests`) uses a new `UpdatesUITestFixture` state
  `widget-link` that seeds the existing fixture Work and then calls the **same** routing function
  `onOpenURL` calls with `WidgetDeepLink.url(for:)` — the Work id is minted at launch, so the test
  can't know it. The negative case uses `XCUIApplication.open(_:)` with a random UUID. Both are
  hermetic (`UpdatesUITestSource`), so the class joins CI's hermetic list in `ci.yml:246-250` —
  the one CI file change, in slice 3.
- **Rendering is covered by previews and a manual pass.** `#Preview(as: .systemSmall)` /
  `.systemMedium` for every state (empty, one row, full, redacted, long title, no cover) live in
  the extension; they compile on CI, so a broken view fails the build. Before merging slice 3, a
  manual run on the iPhone 17 Pro simulator via Device Hub adds both widgets in both sizes, in light,
  dark and tinted modes and in StandBy, and attaches screenshots to the PR — the repo's
  screenshot-attachment convention, done by hand because no tool can do it.

## Slices

Each merges on its own and leaves `main` shippable.

1. **Target + App Group, no behaviour.** §7 steps 1–5; the extension contains one placeholder
   widget showing the empty state. `MangaCartaShared/` with `Theme.swift` moved in. Proof: green CI
   and AC 1. Risk concentrated here on purpose (pbxproj, signing, CI toolchain).
2. **Snapshot pipeline.** `WidgetSnapshot`, builder, publisher, cover renderer,
   `AdultSurfacePrivacy` extraction (+ notifier registry injection), `ImageCache` cache-only lookup,
   `didFinishRun`, `.background` trigger, composition wiring. ACs 2–15. The widget still shows the
   placeholder, but the file is being written — inspectable in the simulator's group container.
3. **Widgets and links.** The two real widgets, `WidgetRowPresentation`, `WidgetDeepLink`,
   `ContentView.onOpenURL` routing, the UI test and its fixture state, the `ci.yml` hermetic-list
   line, and the manual screenshot pass. ACs 16–18.

## Open questions for the owner

1. **Saved Works only?** `WorkNavigator`'s route only opens saved Works, so the design shows only
   saved Works in both widgets. The alternative is to let Continue Reading include unsaved titles
   you've been reading and teach the link route to open them from History (a second route, more
   code). **Recommendation: saved only for v1.**
2. **Muted Works in New Chapters?** Mute today means "no notifications"; the in-app Updates list
   still shows them. **Recommendation: exclude muted Works from the widget**, since the Home Screen
   is outside the app the same way a notification is.
3. **Lock-screen accessory widgets?** A one-line `accessoryRectangular` ("Dandadan · 2 new") is
   cheap once the snapshot exists, but it is the most public surface there is.
   **Recommendation: not in v1; add after the Home Screen widgets have been lived with**, and only
   with redaction on by default.
4. **Adult titles: redact or omit?** The design follows the notification policy — a generic "A
   followed title has new chapters" row. Omitting adult Works entirely would hide even that a
   followed title exists. **Recommendation: redact, matching notifications**, so the two surfaces
   behave the same.
5. **Live Activity.** **Recommendation: none**, revisit only if background offline downloads are
   built (§8).
