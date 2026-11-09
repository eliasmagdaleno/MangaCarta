# Detail page sections — Design

**Date:** 2026-11-09
**Status:** Draft for owner review. The owner questions are at the end, each with a recommended answer.
**Evidence baseline:** `main` at `b57c356`. Two parallel specs that are not on `main` yet are
read from their branches: `eliasmagdaleno/spec-related-mal-cache` (`a26903c`, the Related rail)
and `eliasmagdaleno/spec-local-matching` (`f5de6c3`, the local "Metadata and sync" section).
**Handoff queue item:** 6. Deferred by
[`2026-07-21-more-like-this-design.md`](2026-07-21-more-like-this-design.md) ("Explicitly
deferred": "A tab / segmented-control treatment of the detail page (v1 is a bottom section).").

Terms **Work**, **Listing**, **Listing key**, **Source** and **Pin** are the glossary's
(`docs/glossary.md:8`, `:17`, `:31`) and are used here without being redefined.

## Goal

Give each of the detail page's three lists a clear place: **Chapters**, **Related** (the
parallel spec's MAL series relations) and **More Like This** (MAL recommendations). Today they
are stacked one above the other at the bottom of a single scroll. A reader should reach any of
the three with one tap from the top of the page. Lists with no content are not shown, and
nothing already on the page should change behaviour.

## A correction to the premise

The task brief says the page stacks "the full chapter list" and that the rails are "effectively
unreachable" on a long series. **That has not been true since the chapter preview shipped.**
`MangaDetailView.swift:596` renders `chapterPreview(vm.chapters, limit: 5)`, which takes the
five newest chapters (`MangaCarta/Models/ReadingResume.swift:33-38`, unit-tested at
`MangaCartaTests/MangaCartaTests.swift:3439` and `:3453`). The full list is a separate pushed
screen, opened from "Show all N chapters" (`MangaDetailView.swift:646-664`, `ChapterListView`).
A live test asserts the rail is reachable: `testChapterPreviewKeepsRailReachable`
(`MangaCartaUITests/MangaCartaUITests.swift:449-487`) allows at most eight swipes.

The problem that remains is smaller but still real:

- **Distance, worst at accessibility text sizes.** Above the rail sit the hero, the action row,
  tags, a four-line synopsis, the Chapters header, a hint line, five rows and the Show-all row
  (`MangaDetailView.swift:144-173`). At AX sizes the hero turns vertical (`:223-227`), every row
  wraps, and the rail ends up several screens down.
- **A second rail is coming.** The Related spec puts its rail *before* More Like This, again at
  the bottom (Related spec §5, "Place **Related before the existing More Like This rail** at
  the bottom of the page"). Stacking two rails makes the second one twice as far away.
- **Nothing at the top says the rails exist.** They load in the background (`:182`). A reader
  who never scrolls to the bottom never learns that the page has discovery content.

This changes the case for the design, but the feature still makes sense. Open question 1 asks
the owner to confirm it should go ahead on these terms.

## Non-goals

- **Putting the full chapter list inline.** The Chapters segment keeps the five-row preview and
  "Show all". Sorting and multi-select stay on `ChapterListView` (`MangaCarta/Views/ChapterListView.swift:12`).
- **Changing what Related or More Like This contain**, how they load, or how they are cached.
  That belongs to the More Like This spec and the Related spec.
- **A two-column iPad layout.** See §6.
- **Restoring the chosen segment across app launches.** See §4.
- **Moving the hero, the action row, tags, synopsis or the source picker.** They stay above the
  sections, unchanged.
- **New persistence.** This feature writes nothing to disk.

## Current code this builds on

Every line reference below was opened on `b57c356`.

- **`MangaCarta/Views/MangaDetailView.swift:144-173`:** `body` is one `ScrollView` holding a
  `VStack(spacing: Gutter.section)` in this order: `hero`, `actionRow`, `tags` (when present),
  `description` (when present or loading), `chapters`, then `moreLikeThisRail` when
  `!moreLikeThis.items.isEmpty`, *else* `UnmatchedTitleNotice()` when `isUnmatchable`.
- **`:176-182`:** `.onAppear` runs `applyPinnedSource()` and `vm.load()`. A non-blocking
  `.task { await moreLikeThis.load(for: manga) }` loads the rail. `MoreLikeThisViewModel.load`
  only does work once per manga id (`MangaCarta/Models/MoreLikeThisViewModel.swift:31-41`), so
  appearing again after the reader closes does not refetch.
- **`:128-132`:** `isUnmatchable` returns false when the title has no Work, and otherwise asks
  `engine.isUnmatchable(work)`.
- **`:556-564`:** `moreLikeThisRail` is `InkSectionHeader("More Like This", eyebrow: "Similar
  titles")` over `MangaRail(items:)`, tagged `.accessibilityIdentifier("moreLikeThisSection")`.
- **`:568-667`:** `chapters` contains:
  - the header `InkSectionHeader("Chapters", eyebrow: "\(vm.chapters.count) available")`;
  - the hint "Press and hold a chapter for read actions" (`:572-577`);
  - the error-and-retry branch (`:579-587`) and the loading/empty branch (`:588-592`);
  - preview rows, each a `NavigationLink` to `ReaderView` (`:596-611`);
  - per-row context menus and VoiceOver actions (`:613-640`) — "Mark as read/unread" and "Mark
    all below as read". The bulk action sorts **`vm.chapters`, the full list**, not the
    preview (`:622`, `:635`);
  - the `showAllChaptersButton` row (`:646-664`).
- **`:368-373`, `:597-603`:** the reader is **pushed** with `NavigationLink`, not presented.
  There is no `fullScreenCover` anywhere in `MangaCarta/` (grepped). So `MangaDetailView` stays
  in the navigation stack while the reader is open, and its `@State` survives the round trip.
- **`MangaCarta/Views/Components/UnmatchedTitleNotice.swift:25-70`:** draws its own
  `InkSectionHeader("More Like This", eyebrow: "Nothing to compare")` and the identifier
  `unmatchedTitleNotice`. Its header comment (`:13-15`) says the notice takes the More Like This
  slot because "an empty section is the question the placement is answering". This is the
  visible-failure requirement of ADR-0005 (`docs/adr/0005-manual-link-override.md:95-97`) at the
  scale of one title.
- **`MangaCarta/Views/Components/InkComponents.swift:101-131`:** `InkSectionHeader` draws the
  seal tick, an optional mono eyebrow and a serif title, padded to `Gutter.page`.
- **`MangaCarta/Views/Components/MangaRail.swift:11-37`:** the horizontal rail of cover cards.
  Each card pushes another `MangaDetailView`.
- **`MangaCarta/Services/MoreLikeThisProvider.swift:39-43`:** has **no gate for local titles**.
  `MALEntityResolver.malId(for:)` (`MangaCarta/Services/MALEntityResolver.swift:271-296`) falls
  through to a MAL title search for any `Manga`, a `local` one included. So "local Works have no
  MAL rails" is not something the code enforces today. A local import whose title happens to
  match MAL can show More Like This. The design below does not depend on either answer (§5.4).
- **Detail views do not read size class.** `rg horizontalSizeClass MangaCarta` returns nothing.
  The detail page has one layout for every width.
- **The only `Picker`s** in the app are `ReaderView.swift:644` (reading mode menu) and
  `SettingsView.swift:99`. Neither is segmented, so this would be the first segmented control
  in the app.

### UI tests that touch the detail page

The hermetic suites CI requires are listed at `.github/workflows/ci.yml:246-250`: `UpdatesUITests`,
`SourcePreferenceUITests`, `RepositorySettingsUITests`, `LocalImportUITests` and
`AccessibilityAuditUITests`. These are the ones that open a detail page:

| Test | What it finds on the detail page | Affected? |
|---|---|---|
| `SourcePreferenceUITests.testDetailPageOffersTheWorksOtherListing` (`:92`), `testThePickerNamesBothSourcesAndTheirChapterCounts` (`:109`), `testThePickerMenuSaysWhichSourceIsAlreadyInUse` (`:138`) | `buttons["sourcePicker"]` in the hero | No, the hero is above the sections |
| `LocalImportUITests.testImportReadAndDelete` (`:11`), `testReaderModeIsPerTitle` (`:87`) | "Start Reading"/"Continue" and "Delete from Device", both in the action row | No, the action row is above the sections |
| `AccessibilityAuditUITests.testCoreScreensPassTheAccessibilityAudit` (`:24`) | Audits the whole detail screen of a local import | The audit passes because no picker appears for the fixture (§5.1). It also means the audit **never sees the picker**, so AC 9 adds a fixture that does show it |

**No hermetic test finds a chapter row on the detail page.** Chapter rows are found by label
predicate, not by identifier. `chapterRow(number:)` (`MangaCartaUITests.swift:741-746`) matches
`label BEGINSWITH "Chapter N,"`. Every caller is in the **live** file `MangaCartaUITests.swift`
(`:271`, `:782`, `:811`, `:1447`), which is run by name and is not a merge gate
(`MangaCartaUITests.swift:10-33`). Chapters is the default segment, so those queries keep
matching without any change. Three more live tests depend on the current layout:

- `testMoreLikeThisDetailRailLiveVerification` (`:396`) and `testChapterPreviewKeepsRailReachable`
  (`:449`) swipe until `staticTexts["More Like This"]` exists. **Both break**, because that
  header now only exists after "Similar" is selected. They must tap the segment instead (AC 11).
- `testShowAllChaptersOpensFullListWithSortAndSelect` (`:490`) swipes to `showAllChaptersButton`.
  The button is still in the default segment, so this test is unaffected.

## Design

### 1. Options

**A. A segmented control below the synopsis: `Chapters | Related | Similar`.** The page above the
control stays as it is. Below it, only the selected segment's content is shown.
*For:* every list is one tap from the top. The control itself tells the reader that discovery
content exists. It is a native `Picker` with `.segmentedPickerStyle`, which DESIGN.md asks for:
"Native interaction structure with branded details rather than custom platform replacements";
"Do retain native controls, navigation, focus, gestures". VoiceOver gets selection semantics for
free, which matters because DESIGN.md says "Never rely on color alone to communicate selection".
*Against:* content in an unselected segment is out of sight. The control can also change
shape when a rail finishes loading late (handled in §3).

**B. A pinned section index.** The single scroll stays. A strip of jump buttons pins below the
navigation bar and scrolls the page with `ScrollViewReader` (Chapters · Related · Similar).
*For:* everything stays visible in one continuous scroll.
*Against:* it is a custom control, so selection semantics have to be built by hand. Which button
is "current" has to be computed from scroll position. A pinned strip over a paper surface needs
its own background and hairline, which is surface chrome that DESIGN.md's Printed Surface Rule
discourages. It also does not shorten anything: at AX sizes the reader still scrolls past every
list.

**C. One scroll with the order changed.** Put Related and More Like This above Chapters, or
collapse Chapters to one "Continue / Show all" row.
*For:* the smallest change.
*Against:* it makes chapters, the page's main job, harder to reach in order to make discovery
easier to reach. That is the wrong trade on a reading app's detail page.

**Chosen: A.** It is the only option that gives each list a home without making another one
harder to reach, and it is the only one built entirely from a native control. B's continuous
scroll is the one thing A gives up. With a five-row preview, B saves very little scrolling for
the custom state it adds.

### 2. Layout

```
ScrollView
  hero                       (unchanged, :223-283)
  actionRow                  (unchanged)
  tags                       (unchanged, when present)
  description                (unchanged, when present or loading)
  [local-matching's "Metadata and sync" section, if that spec lands — stays here, see §5.4]
  DetailSectionPicker        (new; hidden when only Chapters is available)
  selected pane:
    .chapters  → chaptersPane    (the existing `chapters` view, moved verbatim)
                 + UnmatchedTitleNotice when Similar is absent and isUnmatchable (§5.2)
    .related   → relatedPane     (the Related spec's rail, header included)
    .similar   → moreLikeThisPane (the existing `moreLikeThisRail`, header included)
```

- **Position.** The picker goes under the synopsis, not right under the hero. Tags and synopsis
  describe the title, and they apply equally to all three lists below. Putting the control
  between them would wrongly suggest that switching segments changes the synopsis.
- **Each pane keeps its `InkSectionHeader`.** The Chapters header's eyebrow, "N available",
  carries the count, which the segment label does not. The More Like This header keeps its
  title, so the live tests can still find the "More Like This" text once they have selected the
  segment. Keeping the headers keeps the moved code unchanged.
- **Spacing.** The picker is one more item in the existing `VStack(spacing: Gutter.section)`,
  with horizontal padding of `Gutter.page`. The pane follows it at the same spacing.
- **Styling.** Tint only. Apply `.tint(Ink.seal)` to the picker, and nothing else. A native
  segmented control draws its selected segment with the system thumb, not with the tint, so
  this changes almost nothing visually. That is intended. The One Seal Rule keeps vermilion
  scarce, and the seal tick in each pane's header already carries the accent. Do not
  restyle the control with `UISegmentedControl.appearance()`, because that global appearance
  would leak into every future segmented control.
- **Switching.** Switching panes is not animated beyond SwiftUI's default for an `if`. There is
  no slide or matched geometry. When the pane is shorter than the space below it, the scroll view
  keeps its offset clamped to the content. That is native behaviour and needs no handling.

### 3. Which segments exist, and the default

A pure value type in `Models/` makes this testable without SwiftUI:

```swift
enum DetailSection: String, CaseIterable, Identifiable {
    case chapters, related, similar
    var id: String { rawValue }
    var title: String { … }  // "Chapters", "Related", "Similar"
}

struct DetailSectionAvailability: Equatable {
    var hasRelated: Bool
    var hasSimilar: Bool

    /// Always starts with `.chapters`; the others appear only when they have content.
    var sections: [DetailSection] { … }

    /// The picker is drawn only when there is a choice to make.
    var showsPicker: Bool { sections.count > 1 }

    /// `requested` if it is still available, else `.chapters`.
    func resolve(_ requested: DetailSection) -> DetailSection { … }
}
```

- **Chapters is always present and is the default.** The page exists to read the title. Chapters
  is listed even while chapters are loading, when they failed to load, or when there are zero.
  Its pane already handles all three states (`MangaDetailView.swift:579-592`), and a reader on
  any of them must still find the retry.
- **Related and Similar appear only once they have content.** `hasSimilar` is
  `!moreLikeThis.items.isEmpty`. `hasRelated` is the Related spec's `!relatedTitles.isEmpty`.
  While they load, their segments do not exist, so there is no spinner tab. This follows the
  Related spec's rule that a missing section is "an omission, not an error" (§5) and matches
  how the rail behaves today.
- **Late arrival does not move the reader.** Both rails load after the page appears. When one
  arrives, its segment is added to the control, and the selection stays where it was: the
  reader keeps their place in Chapters. The control appears (or gains a segment) without
  animation, so the content below it does not slide.
- **A segment that disappears falls back to Chapters.** Under this design the rails only ever
  go from empty to full once per manga, so this should not happen. But if a future reload
  empties the selected list, `resolve(_:)` selects Chapters. The page never shows a selected
  segment that no longer exists.
- **Order is fixed: Chapters, Related, Similar.** It follows the Related spec's decision to put
  series continuity before recommendations ("Related before More Like This"). Related comes
  before Similar whether or not both are present.

### 4. Remembering the selection

- The selection is `@State private var section: DetailSection = .chapters` on
  `MangaDetailView`. Opening a chapter **pushes** `ReaderView` (`:371`, `:601`), and closing it
  pops back to the same view instance with its `@State` intact. A reader who opened a chapter
  from Chapters returns to Chapters. A reader who tapped a Similar card to open another title,
  then came back, returns to Similar. That second case is what makes Similar worth having as a
  segment.
- Each `MangaDetailView` keeps its own selection. A detail page pushed from a rail is a new view
  with its own `@State`, so it starts on Chapters. That is correct: it is a different title.
- **The selection is not saved across launches, and not per title.** `@SceneStorage` would be
  the native tool for that, but it stores one value per scene, not one per title, so it would
  carry title A's choice over to title B. The app restores no navigation path across launches
  either (`rg SceneStorage MangaCarta` finds nothing), so a remembered segment would have no
  page to restore onto.
- **Switching source keeps the selection.** `vm.retarget(to:using:)` (`:103`, `:109`) changes the
  chapters and leaves the segment alone. This follows ADR-0001's identity rule: the page is
  about the Work, not about one Listing of it.

### 5. Edge cases

#### 5.1 Only Chapters available

`showsPicker` is false, so no control is drawn. The page then looks exactly like today's page
without a rail: the Chapters header, its rows and Show all. This covers:

- every title whose rails are empty;
- every title before its rails load;
- the hermetic local-import fixture, which is why `LocalImportUITests` and the current
  accessibility audit stay green without changes.

A one-segment control would be a control that offers no choice, which is the same thing the
source stamp already refuses to do (`MangaDetailView.swift:93-94`: "One Listing is not a
choice").

#### 5.2 The unmatched-title notice (ADR-0005)

The notice exists so that a title's missing recommendations are visible rather than silent. The
task's rule is "hide the segment, not show an empty tab". Followed alone, that rule would hide
the notice together with the Similar segment, and that would break ADR-0005's implied
requirement.

Options:

1. **Make Similar a segment whose only content is the notice.** This keeps the notice's "the
   slot explains itself" argument. But it creates a segment the reader taps only to be told it
   has nothing, which is the empty tab the brief rules out.
2. **Put the notice at the bottom of the Chapters pane when Similar is absent.** This is where it
   sits today, after the chapter list. With no Similar segment, the bottom of the page is still
   where More Like This would have been.
3. **Drop the notice.** Not acceptable: it breaks ADR-0005.

**Chosen: 2.** The rule today is `else if isUnmatchable` after the rail check (`:153-160`). It
becomes: when `!availability.hasSimilar && isUnmatchable`, the Chapters pane ends with
`UnmatchedTitleNotice()`. The precedence is the same, so a title that somehow has both shows the
rail and never the notice. The notice keeps its own "More Like This" header and its
`unmatchedTitleNotice` identifier. This is open question 3.

The notice is **about recommendations only**. It never stands in for an empty Related, and no
Related notice is added: the Related spec treats a missing relation as an omission, not a failure.

#### 5.3 Chapter context menus and bulk mark actions

`chaptersPane` is the current `chapters` property moved as it is (`:568-667`). That includes:

- the context menu, with "Mark as read/unread" and "Mark all below as read" (`:613-630`);
- the VoiceOver actions "Mark as read/unread" and "Mark this and all below as read" (`:631-640`);
- the long-press hint (`:572-577`);
- the full-list push.

None of these depends on page position. The bulk action works on the sorted **full**
`vm.chapters` from the tapped row downward (`:622`, `:635`), not on the five-row preview, and
that does not change. The context menu opens from the row inside the scroll view as it does
today. The control sits above the pane, so nothing overlaps the row's long-press area.

When a chapter is marked read from Chapters, the segment does not change. The action row's
"Continue" label, above the picker, updates as it does today. It reads `history`
(`MangaDetailView.swift:288-291`), which is unaffected.

#### 5.4 Local Works

- **No special case in this spec.** Whether a local Work shows a segment depends only on whether
  its rails have content.
- **Today**, as §"Current code" shows, a local title can get a More Like This result through MAL
  title search. If it does, it shows Similar, just as it shows the bottom rail now. Usually it
  does not, and then the page has no picker, the same as the local fixture.
- **Related** has no local path. The Related spec resolves relations only into installed
  external-id Sources, and Local is not one.
- **The local-matching spec's "Metadata and sync" section** (its §1) is about the title itself,
  like the synopsis. It belongs **above** the picker, not in a segment, so that Match… stays
  visible on a local Work without a tap.
- If the owner wants local Works never to query MAL until matched, that gate belongs in
  `MoreLikeThisProvider` or the local-matching spec, not in this layout. This spec's empty-segment
  rule handles the result either way.

#### 5.5 Other cases

- **A pinned or retargeted source with zero chapters.** Chapters stays the default and shows
  "No chapters yet." (`:588-592`). Related and Similar come from the Work's MAL id, not from the
  Listing, so they can still appear. That is useful, because the reader can still find
  something to read.
- **Error banner.** `vm.errorMessage` with no chapters shows the existing retry inside the
  Chapters pane (`:579-587`). The picker is unaffected.
- **Rotation and multitasking.** The view and its `@State` persist, and the selection survives.

### 6. iPad and regular width

DESIGN.md: "iPad surfaces use readable maximum widths… Don't preserve a fixed phone composition
on iPad".

- The picker is limited to a readable width: `.frame(maxWidth: 420, alignment: .leading)`
  inside `Gutter.page`. A three-segment control does not stretch across a 1,000-point iPad
  width. The limit is a cap, not a fixed size, so the control still fills a compact width.
- The panes are unchanged. Rails scroll horizontally and show more cards on a wider screen.
  Chapter rows already fill the width, as they do today.
- **Not in this slice:** a regular-width layout that drops the control and puts Chapters beside
  a Related/Similar column. It is the better iPad page, but it is a different layout with its
  own tests. It also needs `horizontalSizeClass`, which no detail screen reads today. Recorded
  as open question 4 so it is not lost.

### 7. Data and persistence changes

**None.** This adds no store, no `UserDefaults` key and no file, and changes no Codable shape.
The selection lives in view `@State` only. The two lists' contents come from their existing view
models: `MoreLikeThisViewModel.items` today, and the Related spec's projection.

**One test seam is needed** for the hermetic UI tests (AC 9, AC 10). Today the detail page builds
`MoreLikeThisViewModel` with the live provider inside `init` (`MangaDetailView.swift:37`), and
there is no launch argument that stubs it. Grepped: the `-uitest-*` flags in `MangaCarta/` are
`import-fixture`, `install-repository`, `local-import`, `mal-offline`, `mal-reset-outbox`,
`mal-signed-out`, `mal-state`, `notification-explainer`, `repository-reports`,
`repository-settings`, `source`, `updates-state` and `zero-sources`. None of them touches
More Like This.

Add a new `UpdatesUITestState` case `detail-discovery`, reached through the existing
`-uitest-updates-state` argument (`MangaCarta/MangaCartaApp.swift:340-351`). The two-listings
fixture set this precedent: "one seeding path with isolated storage is worth more than a tidier
spelling" (`:340-342`). This case seeds:

- a saved fixture title with seven chapters, so Show all also appears;
- a `SimilarTitlesProviding` stub, `MoreLikeThisProvider.swift:66-70`, which already exists for
  tests, returning one other fixture title.

The stub is injected through the graph. `MoreLikeThisViewModel.init(registry:provider:)` already
accepts a provider (`MoreLikeThisViewModel.swift:24-28`). What is missing is the path from
`AppComposition` into the view. Add an environment value, `\.similarTitlesProvider`, whose
default is `nil`, meaning the live provider. The view passes it into `moreLikeThis.load(for:)`
in its `.task`. A `StateObject` cannot read the environment during `init`, which is why
`applyPinnedSource()` adopts the registry late (`:72-77`); this follows that pattern. If the
Related spec's PR 3 lands first, its hermetic `MangaDetailRelatedUITests` needs the same seam,
and this spec should reuse whatever that PR adds instead of adding a second one.

### 8. Accessibility

- **VoiceOver.** The control is
  `Picker("Sections", selection: $section) { ForEach(available) { Text($0.title).tag($0) } }`
  with `.pickerStyle(.segmented)`. SwiftUI exposes each segment as a button, says which one is
  selected, and announces the position ("2 of 3"). Do not add custom accessibility traits.
  `SourcePreferenceUITests.testThePickerMenuSaysWhichSourceIsAlreadyInUse` (`:138-157`) shows
  that this repo relies on native selection semantics and tests that they arrive. AC 8 does the
  same for this control. Give it `.accessibilityIdentifier("detailSectionPicker")`.
- **Reading order.** hero → action row → tags → synopsis → picker → pane. VoiceOver reaches the
  control before any section's content, so a VoiceOver user learns the other lists exist before
  hearing the chapters. Changing segments does not move focus; focus stays on the segment just
  activated. The pane's content changes, and the pane's own `InkSectionHeader` is the first
  element after the picker.
- **Segment titles are plain words**, not icons or stamps, because the Stamp Is Metadata Rule
  keeps the mono uppercase voice for terse facts. "Similar" is spoken as "Similar". The pane's
  header then says "More Like This", so the reader hears both names. That is acceptable, and
  open question 2 covers the naming.
- **Dynamic Type.** A segmented control does not grow its segments with text size: at
  accessibility sizes, three labels in an iPhone-width control get truncated. When
  `dynamicTypeSize.isAccessibilitySize`, the view (which already reads it, `MangaDetailView.swift:23`)
  draws the **same `Picker`, with the same selection binding and identifier, in `.menu`
  style**. That is a native button that reads "Chapters" with a disclosure glyph and opens a
  menu listing the available sections. It grows with the text size and never truncates. It
  follows DESIGN.md's direction that "horizontal hero compositions become vertical" at those
  sizes: the composition changes so the control keeps working. The two styles are two branches
  of an `if`, sharing one `ForEach` content builder.
- **Touch target.** The native segmented control is at least 44 points tall at its default size,
  and the `.menu` style label gets `frame(minHeight: 44)`, as the "Try Chapters Again" button
  does (`:586`).
- **Not by colour alone.** The selected segment is shown by the native thumb and the selected
  trait, never by tint. This satisfies DESIGN.md's Buttons rule.

### 9. Files

| File | Change | Project entry |
|---|---|---|
| `MangaCarta/Models/DetailSection.swift` | **New.** `DetailSection`, `DetailSectionAvailability` | `Models/` is a synchronized group, so nothing to add |
| `MangaCarta/Views/MangaDetailView.swift` | Split `body` into the above-the-picker content, the picker, and the panes. Rename `chapters` → `chaptersPane` and `moreLikeThisRail` → `moreLikeThisPane` | Existing file |
| `MangaCarta/Views/Components/DetailSectionPicker.swift` | **New.** The segmented/`.menu` switch on Dynamic Type | `Components/` is synchronized, so nothing to add |
| `MangaCarta/MangaCartaApp.swift`, `MangaCarta/Services/AppComposition.swift` | The `detail-discovery` fixture state and the `\.similarTitlesProvider` environment value | Existing files |
| `MangaCartaTests/DetailSectionTests.swift` | **New.** Unit tests for ACs 1–4 | **Needs `xcp add-file … --targets MangaCartaTests`** (plain group) |
| `MangaCartaUITests/DetailSectionsUITests.swift` | **New.** Hermetic tests for ACs 5–10 | **Needs `xcp add-file … --targets MangaCartaUITests`**: `MangaCartaUITests` is a plain `PBXGroup` with per-file references (`project.pbxproj:223`, `:458-469`), not a synchronized group |
| `.github/workflows/ci.yml` | Add `-only-testing:MangaCartaUITests/DetailSectionsUITests` next to `:246-250` | Without this the new suite is not a merge gate. The repo rule that this spec edits nothing else covers this document only; the implementing PR makes this change |
| `MangaCartaUITests/MangaCartaUITests.swift` | Live tests `:396`, `:449`: tap the "Similar" segment instead of swiping | Existing file |

The design uses only `Picker`, `@State`, the existing `EnvironmentValues` pattern and a pure
value type, all of which build on Swift 6.0 / Xcode 16.4. It needs no isolated conformance, no
`nonisolated(nonsending)`, no `@concurrent` and no `Task.immediate`.

### 10. Slicing and order against the Related spec

This is **one PR**: a moved view property, one new control, one value type, one fixture case and
its tests. It does not depend on the Related spec. Without Related, the control simply has at
most two segments, Chapters and Similar.

- **If this lands first:** the Related spec's PR 3 adds `hasRelated` to the availability struct
  and a `relatedPane`, instead of a bottom rail. Its AC 11 test,
  `testRelatedCardAnnouncesRelationAndPrecedesMoreLikeThis`, then asserts segment order
  (Related before Similar) instead of vertical order.
- **If Related PR 3 lands first:** this PR moves the Related rail into a pane next to More Like
  This, and changes that test's "precedes" assertion in the same way.

Either order works. The recommendation is in open question 5.

## Acceptance criteria

Each criterion names the test that proves it. Unit tests run under the iPhone 17 Pro destination.
Hermetic UI tests use the `detail-discovery` fixture, make no network request, and run in CI's
`ui-tests` job.

1. **Chapters is always the first section and is listed even when nothing else is**:
   `DetailSectionTests.testChaptersIsAlwaysFirstAndAlwaysPresent`.
2. **Related and Similar appear only when they have content, always in the order Chapters,
   Related, Similar**: `DetailSectionTests.testEmptySectionsAreOmittedAndOrderIsFixed`
   (all four combinations).
3. **The picker is drawn only when there is more than one section**:
   `DetailSectionTests.testPickerIsHiddenWithOnlyChapters`.
4. **A selected section that becomes unavailable falls back to Chapters, and an available one is
   kept**: `DetailSectionTests.testResolveFallsBackToChaptersAndKeepsAvailableSelection`.
5. **Chapters is the default segment, and the chapter rows, context menu and Show all are
   present without a tap**:
   `DetailSectionsUITests.testDetailOpensOnChaptersWithPreviewAndShowAll`. It asserts
   `detailSectionPicker` exists, a `label BEGINSWITH "Chapter "` button exists, and
   `showAllChaptersButton` exists.
6. **Selecting Similar shows More Like This and hides the chapter rows; selecting Chapters
   brings them back**: `DetailSectionsUITests.testSwitchingSegmentsSwapsThePane`.
7. **The selection survives opening and closing the reader**:
   `DetailSectionsUITests.testSelectionSurvivesTheReaderRoundTrip`. It selects Chapters, opens
   a chapter, closes the reader and asserts Chapters is selected. It then selects Similar,
   opens the card's detail page, goes back and asserts Similar is selected.
8. **Each segment is a VoiceOver element with a label, and exactly one reports itself selected**:
   `DetailSectionsUITests.testSegmentsExposeExactlyOneSelected`. Same shape as
   `testThePickerMenuSaysWhichSourceIsAlreadyInUse`.
9. **The detail screen with the picker passes the automated accessibility audit, at default and
   at accessibility text sizes, and at the accessibility size the control is the `.menu` style**:
   `DetailSectionsUITests.testDetailWithSectionsPassesTheAccessibilityAudit`. It uses the same
   audit set as `AccessibilityAuditUITests` (`:16`), and sets the size with the
   `UIPreferredContentSizeCategoryName` launch argument.
10. **A title with no discovery content shows no picker and its chapters exactly as before**:
    the existing `LocalImportUITests.testImportReadAndDelete` and
    `AccessibilityAuditUITests.testCoreScreensPassTheAccessibilityAudit` pass unchanged, plus
    `DetailSectionsUITests.testNoPickerWithoutDiscoveryContent` (the fixture with the stub
    returning nothing).
11. **The live rail tests reach More Like This through the segment**:
    `MangaCartaUITests.testMoreLikeThisDetailRailLiveVerification` and
    `testChapterPreviewKeepsRailReachable`, updated to wait for `detailSectionPicker` and tap
    "Similar". Run by name, as for every live test. These are not a merge gate.
12. **An unmatched title with no Similar segment still shows the notice, at the bottom of
    Chapters**: `DetailSectionsUITests.testUnmatchedNoticeEndsTheChaptersPane`. The fixture
    marks the Work unmatchable and the stub returns nothing. The test asserts
    `unmatchedTitleNotice` exists without a segment tap, and `detailSectionPicker` does not exist.
13. **The existing hermetic suites stay green**: the CI `ui-tests` job, running
    `UpdatesUITests`, `SourcePreferenceUITests`, `RepositorySettingsUITests`,
    `LocalImportUITests` and `AccessibilityAuditUITests`, passes unchanged on the PR.

## Open questions for the owner

1. **Go ahead, given that the rails are already reachable?** The five-row preview already
   fixed the "unreachable" problem the brief describes (see "A correction to the premise").
   What is left is the distance at AX sizes, the second rail, and the fact that nothing at the
   top tells the reader the rails exist. *Recommended: yes.* Related makes the bottom of the
   page a stack of two, and the control is a small, native change.
2. **What to call the segments.** "Chapters | Related | Similar", or "Chapters | Related | More
   Like This"? *Recommended: "Similar"* for the segment, keeping "More Like This" as the pane
   header. "More Like This" is three words in a segment and truncates first as the text grows.
   The pane header gives it the full name.
3. **Where the unmatched notice goes.** At the bottom of the Chapters pane when Similar is
   absent (§5.2, option 2), or as a Similar segment containing only the notice? *Recommended:
   the bottom of Chapters.* It keeps the failure visible as ADR-0005 requires, without a
   segment the reader taps only to find nothing.
4. **A two-column iPad layout.** Ship the capped-width control on iPad now and leave the side by
   side layout as a later item? *Recommended: yes, defer it.* It needs `horizontalSizeClass`
   and its own tests, and no other detail screen adapts to iPad yet.
5. **Order against Related PR 3.** Land this first, so Related arrives as a segment, or let
   Related PR 3 ship its bottom rail first? *Recommended: this first.* Then Related PR 3 writes
   its pane and its order test once, against the final layout, instead of building a bottom
   rail and moving it. Related PRs 1–2 (the cache and the projection) do not depend on this
   either way.
