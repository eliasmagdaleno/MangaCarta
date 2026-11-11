# Per-title Sources: add a Source, remove a Source — Design

**Date:** 2026-11-11
**Status:** Proposed. The owner asked for items 1–2 on 2026-11-11 ("similarly to Paperback without copying
them outright"). Library-wide switching (item 3) is a separate design that comes after this one.
**Slug:** `per-title-sources`

## Goal

Let the reader decide, for each title, which Sources serve it. **Add a Source** finds the title on another
installed Source and links that copy. **Remove a Source** unlinks a copy, and it stays unlinked. Today a
title gains copies only when automatic resolution finds them, and loses them never. A copy that was matched
wrongly, or that the reader simply doesn't want, can't be removed.

This is the decision ADR-0005 made and then parked: keep matching precision-biased, and give the reader a
manual override, with unlinking shipped alongside linking. Its revisit trigger has been met. Installed
Sources replaced the two built-in ones, so a Listing → Work mismatch is no longer hypothetical. ADR-0005
Amendment 2 records that, and this document is the design it points to.

## How this relates to Paperback

Paperback's per-title menu has *Add Source*, *Remove Source* and *Change Primary Source* (its guides:
paperback.moe/guides/merging, /guides/migrating). The shape is right and we take the shape. Where we
differ, it's because MangaCarta already has machinery Paperback lacks, or because our identity model makes
something unnecessary:

| | Paperback | MangaCarta |
|---|---|---|
| Finding the other copy | A plain search in one extension | Every visible Source is searched at once. Each result is graded: same MyAnimeList entry, likely match, or different entry. The top three show chapter counts (slice 3's chooser) |
| Reading progress | Migration asks whether to bring "chapter markers" | Already shared. Read state belongs to the title, matched by chapter number (ADR-0027) |
| Removing a copy | Drops it | Asks *why*. "Same title, unwanted copy" keeps what you read on it. "A different title" drops it |
| Which copy you read | Primary source | Unchanged: ranking, a per-title pin, and the Settings tie-breaker (ADR-0004) |
| Metadata | Comes from the primary source | Comes from MAL/AniList, never a Source, so there is nothing to choose |

Nothing is copied: not the wording, the layout or the menu structure. The controls live on our existing
Source stamp, not a separate menu.

## Non-goals

- Library-wide switching to another Source (item 3; its own design).
- Linking or unlinking a **Local** copy. Local-library matching owns that
  (`2026-11-09-local-library-matching-design.md`), with its own Match/Unmatch. Local Sources are excluded
  from Add's search, and Local Listings are never offered for Remove.
- Splitting one Work into two. Remove takes one copy out; it doesn't undo a Work merge. Local matching
  makes the same call.
- Changing how automatic resolution matches. `MALTitleMatcher` keeps its threshold and ambiguity guard.
- A Settings screen listing every title's Sources. The controls live on the title, as Paperback's do. The
  MAL hub's remembered choice stays on its preview, which answers that design's open question 3 the same
  way.

## Current code this builds on

- **Works and Listings:** `Work.listings` (`Models/Work.swift:123`) and `WorkStore`
  (`Services/WorkStore.swift`). It already has `merge(_:into:)` (aliasing, never erasing),
  `removeListing(_:)` (`:84`, which deletes a Work left with no Listings), and the private
  `link`/`absorb` that mint uses. There is no public "link this Listing" operation. Local matching plans
  the same one (its "Data and persistence changes"), and both features use the single operation defined
  here.
- **The Source stamp:** `SourcePickerStamp` (`Views/Components/SourceBranding.swift:139`), a "Read from"
  menu plus "Use best available". It renders only when `offersAChoice`. With one Listing, the plain
  `SourceStamp` renders (`MangaDetailView.swift:99-118`).
- **Pins:** `SourcePreferenceStore.choose/clearChoice` (`:71`, `:81`). **Ranking:**
  `FulfillmentCoordinator.chosenListing(for:)` and `reconcile(_:)` (`:45`, `:87`).
- **Read state per Work:** `HistoryStore.readOrdinals(forListings:)` (`:256`), fed from the Work's
  `listings` (ADR-0027).
- **Searching every Source:** `MALHubResolver`. It runs one timed search per visible non-Local Source,
  with at most four in flight, a deadline that pauses while a challenge is on screen, per-Source "Couldn't
  check" with "Try again", and a nested host for challenge sheets. `MALHubChapterCountLoader` counts the
  top three choices.
- **Other stores keyed by Listing that a removal touches:** `LibraryItem` (one item per saved Listing),
  `MALSourceChoiceStore` (MAL id → Listing), `UpdateStateStore` (per Work, with a per-Listing check state), and
  `ListingCountCache` (disposable; left alone).

## Design

### 1. Where the controls live

The detail page's Source stamp becomes the one place a title's Sources are managed. It is always a menu
for a remote title, even with one Listing:

```
Read from
  ✓ Source A · 212 chapters
    Source B · 198 chapters
  Use best available            (only when there is a choice)
──────────
  Add a Source…
  Remove a Source            ▸  Source A
                                Source B
```

- **Remove a Source** appears only when the Work has two or more remote Listings. Removing the last copy
  isn't offered: that is "Remove from Library", which already exists.
- **Add a Source…** is offered on every remote title, including one that hasn't been saved or read. Adding
  a Source is a commitment, so it mints the Work from the current Listing first. "Manual link" is already
  in the glossary's list of commitments (`docs/glossary.md`, **Mint**).
- **Local titles** keep their plain stamp. Local matching's Match… owns them.
- The menu's button label stays as it is ("Source: Source A, 212 chapters, pinned";
  `SourceBranding.swift:208-210`). Each item has a spoken label with
  no glyphs.

### 2. Add a Source

Tapping **Add a Source…** opens a sheet:

- **Title:** "Add a Source". Below it, a search field pre-filled with the Work's display title.
- **On open:** it searches every visible, non-Local Source that doesn't already serve this Work, using the
  Work's known titles as spellings (the MAL hub's search). A reader who edits the field and submits
  searches that text alone, on the same Sources. The reader's spelling is the override when the Work's
  titles miss.
- **Results:** grouped by Source in registry order, the way the hub's chooser groups them. Each row shows
  a cover, the title, alternate titles where one matched, and a grade:
  - **Same MyAnimeList entry:** the result publishes the Work's MAL id.
  - **Likely match:** `MALTitleMatcher.rankedScores` clears its threshold against any known title.
  - **Different MyAnimeList entry:** the result publishes a MAL id that isn't the Work's. It's shown,
    because a Source can mislabel, and adding one asks first (below).
  - **No grade:** every other search result. A manual link exists for the copies the matcher declines, so
    they are listed rather than hidden.
- **Counts:** the top three graded rows show chapter counts through `MALHubChapterCountLoader`. "Chapter
  count unknown" means unknown, never zero.
- **Failures:** a Source that fails or times out shows "Couldn't check" with "Try again, <Source>". A
  retry merges into the rows on screen, as in the hub. Challenge sheets present over this sheet through
  `.challengeSheets(nested: true)`.
- **Empty:** "No results on your Sources". When some Sources failed, it reads "No results on the Sources
  that answered", for the same reason the hub's wording does.
- A Source the reader **removed earlier** from this title still appears, labelled "Removed earlier".
  Adding it again lifts the removal (§4).

Tapping a row adds that copy. It does so immediately when nothing is at stake. Otherwise it asks once:

| The picked copy | What happens |
|---|---|
| Belongs to no Work | Linked to this Work. Its published MAL id is recorded when the Work has none, and ignored when the Work's differs. |
| Publishes a **different** MAL id | Asks first: "MyAnimeList lists this as a different title, <title>. Add it anyway?" with **Add anyway** and **Cancel**. When added, the copy is linked and its MAL id is not recorded on this Work. |
| Is already this Work's | It can't be picked: the row reads "Already a Source for this title". |
| Belongs to **another Work** that has no other copies | Asks first: "This is also <title> in your Library. Adding it makes them one title." with **Add** and **Cancel**. Adding merges that Work into this one; this one survives. |
| Belongs to **another Work** that has other copies too | Asks first, with two choices: **Combine the titles** (merge, as above) or **Move just this copy** (take it out of the other title as if removed there, keeping progress there (§4), and link it here). |

After an add, the sheet closes. The Work's counts are reconciled, and ranking (ADR-0004) decides which copy
the page reads from, as it does for any Work with several Listings. A pin still wins. The page switches
only if the new copy now ranks first and nothing is pinned. To read from it now, the reader picks it in
"Read from". The add itself doesn't auto-pin, because a pin is a separate, deliberate decision (ADR-0004).

**When this Work merges with a saved title:** if both were in the Library, the Library keeps one item, the
one for the Work on screen, with the two items' collections combined. Without this the Library would show
the same title twice.

### 3. Remove a Source

Choosing **Remove a Source › Source B** asks why, because the two answers need different handling:

> **Remove Source B from this title?**
> **It's the same title, I don't want this copy:** keeps what you read on it.
> **It's a different title:** what you read on it no longer counts here.
> **Cancel**

Both answers:
- take the copy out of the Work, so it no longer serves chapters, ranks, or counts toward updates;
- and keep it out (§4). Automatic resolution never links it back, even though it may publish the same
  MAL id.

Then the cleanup:
- **A pin** on the removed copy is cleared. The page retargets to `chosenListing(for:)`, the ranking's
  answer, and reloads.
- **The Library item**, if it was saved under the removed copy, is re-pointed to the copy the Work now
  reads from. Its collections are kept. Its cached chapter list is cleared until the next refresh, because
  it described the removed copy.
- **A MAL-hub remembered choice** pointing at the removed copy is forgotten.
- **Update records:** the removed copy's per-Listing check state (`WorkUpdateState.listings[key]`) is
  dropped. The Work's frontier and its "newly discovered" chapters are Work-level chapter numbers
  (`UpdateStateStore.swift:10-18`), so they stay. The next refresh recomputes them from the remaining
  copies.
- **History isn't deleted.** History is Listing-keyed, and it stays where it was recorded. What changes is
  whether it counts for this title:
  - **Same title:** the copy is kept as a *retired* Listing, and `readOrdinals` reads the Work's Listings
    plus its retired ones. So chapters read only on Source B still show as read on Source A. No marks are
    copied, no chapter list is fetched, and nothing new reaches MAL.
  - **Different title:** the copy isn't kept. Its reads stop counting for this Work, which is right,
    because they were reads of a different title.

### 4. How a removal stays put

A removal has to survive two automatic paths that would otherwise put the copy straight back:
- **Minting from the copy again.** Mint links a Listing to the Work that owns its published external id.
- **The external-id index's merge-on-conflict.** ADR-0008 keeps one Work per external id, and repairs any
  split on load.

The rule, enforced inside `WorkStore`:

- `Work` gains `removedListings: [RemovedListing]`. A `RemovedListing` is a `ListingKey` plus
  `keepsReadState: Bool`. It's Codable, and defaults to empty for existing `works.json` files. A merge
  unions it.
- **`link`** never links a Listing to a Work that has removed it, unless the reader adds it there (§2).
  That clears the removal.
- **Minting from a removed copy** gives it its own Work if the reader commits to it again, for example by
  reading it from Browse. That new Work **doesn't take** any external id owned by a Work that removed the
  copy. The external-id index therefore never sees two Works claiming one id, ADR-0008's invariant holds,
  and the load-time repair has nothing to merge.
- **`setExternalIds`**, when later resolution learns an id, applies the same filter to that new Work.
- **Merges** (automatic or manual) never combine two Works when one of them has removed a Listing the
  other serves. An automatic merge is skipped. The manual case can't arise, because §2 lifts the removal
  first.

A copy the reader adds by hand is recorded too. `Work.handLinkedListings: [ListingKey]` lists them, and no
automatic path removes or moves a hand-linked Listing. (Today the only callers that remove or move a Listing
are local-library deletion and the local series migration, `LocalLibraryDeletion.swift:28` and
`LocalSeriesMigration.swift:18`, and both touch Local Listings only. The record makes ADR-0005's
"authoritative over any future automatic match" a checked rule, not an accident.)

Both records live in `works.json`, which is authoritative user data in Application Support, not a cache.
That satisfies ADR-0005's "never evicted". Cross-device sync (ADR-0028) must carry both fields when it
ships.

### 5. One link operation, shared with local matching

`WorkStore` gains three public operations. All three resolve aliases, keep `listingIndex` exact, and mark
the store dirty once:

- `addListing(_ listing: Manga, to work: WorkID, recordExternalIds: Bool)`, the explicit link;
- `removeListing(_ key: ListingKey, from work: WorkID, keepingReadState: Bool)`, which replaces the
  current `removeListing(_:)` for this path. The old operation stays for its existing callers, which
  delete a Work;
- `retiredListings(of work: WorkID) -> [ListingKey]`, for read state.

Local matching's "explicit Work-to-Listing link operation" is `addListing`. Its design needs no change
beyond pointing at this one.

Coordinating the other stores lives in one place: a small `@MainActor` `WorkSourcesCoordinator` beside
`FulfillmentCoordinator`, built in `AppComposition`. It covers the Library item, the pin, the MAL-hub
choice, update records and count reconciliation. The view calls the coordinator, never the stores one by
one. That is how the removal cleanup stays complete when a new store keyed by Listing appears.

### 6. Searching: extract, don't copy

The Add sheet's search is the MAL hub's search with a different question. The hub asks "where is this MAL
id?"; Add asks "where is this Work?" The per-Source timed search, the four-at-a-time limit, the
challenge-aware deadline and the retry merge move out of `MALHubResolver` into a shared
`SourceTitleSearch`. The hub keeps its grading and its remembered choice on top. The hub's behaviour and
tests don't change; its tests still pass unmodified, which proves that.

## Errors and edge cases

- **No other Sources installed:** the sheet says "No other Sources to search" and offers "Add a
  repository in Settings", the hub's hint.
- **The Source of a removed copy is uninstalled:** nothing changes. A removal record for a missing Source
  is kept, the same reasoning that keeps a pin (glossary, **Pin**).
- **Removing the copy the Work was minted from:** the display title stays. It is set once (ADR-0007).
- **Removing the copy currently open in the reader:** this isn't reachable, because the controls are on
  the detail page. A Continue entry pointing at that copy still opens it (history is kept), and ADR-0027
  matches it by chapter number.
- **Offline:** search fails per Source with "Couldn't check". Remove works offline, because it's purely
  local.
- **Two Sources numbering chapters differently:** "keeps what you read" inherits ADR-0027's accepted risk.
  The confirmation doesn't promise per-chapter precision.

## Accessibility

- The stamp's menu items are plain text ("Add a Source", "Remove Source B").
- Each result row reads "title, Source, grade[, also known as …], count", the hub's pattern.
- The removal dialog's two choices are buttons whose labels carry the full sentence, not a bare "Remove".
- At large Dynamic Type, nothing truncates in the sheet or the dialog. A UI test covers this with a
  screenshot attachment, as the hub's does.

## Testing

- **Unit (WorkStore):**
  - add then remove, both ways;
  - a removed copy is not relinked by mint or by `setExternalIds`;
  - a removed copy re-minted elsewhere doesn't take the Work's MAL id;
  - load-time repair leaves the two Works apart;
  - adding again lifts the removal;
  - merges union the new fields;
  - an existing `works.json` decodes with empty fields.
- **Unit (read state):** with "same title", a chapter read only on the removed copy is still read on the
  remaining one. With "different title", it isn't.
- **Unit (coordinator):**
  - the pin is cleared and the page retargets;
  - the Library item is re-pointed with its collections kept;
  - the MAL-hub choice is forgotten;
  - the removed copy's update check state is dropped;
  - two saved items become one after "Combine".
- **Unit (search):** the hub's existing tests pass unchanged against `SourceTitleSearch`. Add's grading
  covers same id, likely, different id and ungraded.
- **Hermetic UI** (`-uitest-title-sources`, a fixture with Sources A–D and a title on A and B, gated in
  CI's hermetic job):
  - add C from the stamp, and it appears in "Read from";
  - a different-MAL-id result asks first;
  - remove B as "same title", and a chapter read on B stays read on A;
  - remove B as "different title", and it doesn't;
  - B stays removed after relaunch and a Library refresh;
  - large Dynamic Type.
- **Mutations to run:**
  - drop the removal check in `link`, and the relaunch test must fail;
  - drop the retired Listings from `readOrdinals`, and "same title" must fail;
  - drop the Library re-point, and the coordinator test must fail.

## Slices

1. **Model.** The `WorkStore` fields and operations, the §4 guards, retired Listings in read state, and
   `WorkSourcesCoordinator`. No UI.
2. **Add a Source.** Extract `SourceTitleSearch`, then build the stamp menu entry, the sheet, the
   confirmations and the Library dedupe on combine.
3. **Remove a Source.** The menu entry, the dialog and the cleanup, with the UI tests.

Each slice is its own PR, never stacked (stacked PRs here close when their base branch is deleted).

## Open questions for the owner

1. **Remove asks why. Decided 2026-11-11 (owner): ask.** Two choices, "same title" and "different
   title", rather than one Remove that always keeps progress. *Recommended:* ask. One silent default is wrong for one of the two cases, and a
   wrong match carrying its reads into the right title is the kind of corruption ADR-0005 exists to
   prevent.
2. **Picking a copy that belongs to another title with other copies.** Offer both "Combine the titles" and
   "Move just this copy"? *Recommended:* offer both, with Combine first. It is the rare case, and each
   choice is wrong for someone.
