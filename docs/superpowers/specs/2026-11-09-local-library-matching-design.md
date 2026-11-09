# Local-library matching design

**Date:** 2026-11-09  
**Status:** Proposed  
**Slug:** `local-library-matching`

## Goal

Let a reader attach an imported local Work to the correct MAL/AniList identity and, when
available, a remote MangaDex Listing. The local reader remains the source of chapter bytes, but
the Work can gain a provider cover/synopsis/genres and can participate in the existing MAL/AniList
metadata and progress paths.

The feature is deliberately confirmation-first. A missed match costs a metadata upgrade; a wrong
match can put reading progress on another person's MAL title. The existing precision-biased
resolution path remains the candidate generator and authority for automatic evidence. This spec
owns the local-match record and its UX; ADR-0001, ADR-0018, ADR-0020 and ADR-0027 continue to own
identity, external-id trust, search widening and read-state semantics.

## Non-goals

- Matching local files silently, or loosening `MALTitleMatcher`'s threshold or ambiguity guard.
- Making Local browsable, refreshable, or part of update notifications. `LocalSource` remains
  `isBrowsable == false` and `participatesInUpdates == false` (`MangaCarta/Models/LocalSource.swift:8-11`).
- Uploading local files or page images to any provider.
- Replacing local pages with remote chapters, or downloading a remote Listing merely to make a
  match.
- Inferring a match from a filename alone when the resolver has no confident candidate.
- Cross-device sync of match choices.
- Matching uncommitted browsed titles; a Work is required, as in ADR-0007.

## Current code this builds on

The following files were opened for this design:

- `docs/superpowers/specs/2026-09-22-local-import-design.md:169-179,221-240,316-335,390-444`
  defines one local Work/Listing shape, ComicInfo grouping, stable local chapter numbers, and
  explicitly leaves matching to future work.
- `MangaCarta/Models/LocalSource.swift:3-14,46-77` exposes local metadata and chapters, returns
  `malId: nil`, and declares Local outside browse/update surfaces.
- `MangaCarta/Services/LocalLibraryStore.swift:100-115,154-162,217-265` persists the imported
  record and derives series chapters from ComicInfo `Volume`, `Number`, filename digits and stable
  fallback numbering.
- `MangaCarta/Models/ComicInfo.swift:3-18,21-37` parses `Series`, `Title`, `Number`, `Volume`,
  synopsis, writer and genres. `Manga` is parsed but is not used for matching.
- `MangaCarta/Services/WorkStore.swift:135-177,257-329,366-390` mints a Work from a Listing,
  stores external IDs, and merges Works when an external ID is already owned; the loser is aliased
  rather than erased.
- `MangaCarta/Models/Work.swift:44-55,80-126,128-133` defines accumulating MAL/AniList IDs,
  one-provider metadata snapshots, and monotonic `knownTitles`.
- `MangaCarta/Services/MALEntityResolver.swift:95-157,160-177,179-245` resolves a Work by
  authoritative IDs or Listing-keyed cache, searches up to three `knownTitles` into one unioned
  candidate pool, applies the matcher, and then uses the ADR-0019 MangaDex bridge only when the
  Work is not already MangaDex-backed. `malId(for:)` is a separate Listing-keyed entry point at
  `:271-303` and is not the entry point for this feature.
- `MangaCarta/Services/MetadataUpgradeQueue.swift:127-207,219-237` resolves a Work, records
  attempt memory, writes the MAL ID before AniList fetch, and calls `workMetadataChanged` after
  the ID is learned. Its existing listing-participation predicate is why matching must introduce
  a distinct metadata-eligibility decision for a Work with a local Listing.
- `MangaCarta/Services/MALProgressCoordinator.swift:129-169` queues a completion immediately
  when a MAL ID exists, defers it by Work ID otherwise, and promotes deferred rows from
  `workMetadataChanged`.
- `MangaCarta/Services/HistoryStore.swift:146-200,214-227,235-259` records completion and
  derives Work-wide ordinals while retaining Listing-keyed storage.
- `MangaCarta/Models/MALReadingProgress.swift:10-28` maps a numeric chapter label to MAL's
  integer progress, dropping fractional suffixes only for the outgoing MAL count.
- `MangaCarta/Views/MangaDetailView.swift:44-83,93-117,144-177` provides the local detail
  surface, Work lookup, source control and tag-change hook. The match action belongs beside these
  detail actions and must use the injected `SourceRegistry`.
- `MangaCarta/MangaCartaApp.swift:266-297` starts/stops metadata and MAL-progress drains on
  scene activation/background.

### ADR resolution contract

For a local Work, the primary entry point is `MALEntityResolver.resolve(work)`, not
`malId(for: Manga)`. The resolver receives a Work whose `knownTitles` are built as follows:

1. ComicInfo `Series`, when non-empty, is the primary title. This is already the display title for
   a grouped local Work (`LocalSource.swift:73-77`).
2. ComicInfo `Title`, when non-empty and different, is an additional spelling.
3. The source filename with its extension removed and underscores converted to spaces is an
   additional spelling. This is the current fallback title construction in
   `LocalLibraryStore.swift:100-114`, retained as useful evidence even when Series wins.
4. Existing provider/remote spellings are appended after a confirmed match, as required by the
   monotonic `knownTitles` rule.

`Volume` and `Number` are not title spellings. They are chapter identity and progress evidence:
  `LocalLibraryStore` already uses them to derive stable local chapter numbers. A filename's
  digits are likewise a chapter-number fallback, not a license to search MAL for “Title 07” as a
  separate title. A match UI may display these numbers to help the reader distinguish candidates,
  but must not feed them into fuzzy title matching.

The resolver's existing contract then applies unchanged: authoritative IDs short-circuit; otherwise
up to three title spellings are searched and unioned; novels are filtered at the MAL API boundary
per ADR-0017; the 0.90 threshold and 0.05 ambiguity guard remain; the ADR-0019 bridge is used only
when the Work is not already MangaDex-backed. The resolver returns an ID/evidence result, not a
Listing. A MangaDex Listing is selected separately from candidates returned by the installed
Source through the injected `SourceRegistry`.

The match sheet needs more than the resolver's one `WorkResolution`, so add this read-only seam:

```swift
struct ScoredCandidate: Equatable {
    let malID: Int
    let matchedTitle: String
    let score: Double
    let titles: [String]
}

func candidates(for work: Work) async throws -> [ScoredCandidate]
```

`candidates(for:)` returns candidates that clear the acceptance threshold, ordered by descending
score and then ascending MAL ID. It returns an empty array for a confident refusal, and throws on
an incomplete/transient search exactly as `resolve(_:)` does. It must not persist cache entries,
attempt memory, IDs or harvested titles. The sheet can therefore show the same evidence the
resolver would use without mutating the Work.

Implement this without a second matcher: extract the MAL pool construction currently inline at
`MALEntityResolver.swift:117-139` into a shared private `malCandidatePool(for:)`, and extract
the title cross-product scoring/threshold/ambiguity decision currently delegated to
`MALTitleMatcher.bestMatch` (`MALTitleMatcher.swift:75-109`) into a shared ranked result helper.
`resolve(_:)` consumes that helper's top accepted result; `candidates(for:)` consumes the same
ranked results. Both continue to share `isBridgeable` and `bridged(sourceTitles:)` for the
ADR-0019 path, including its id-bearing/id-less partition at `MALEntityResolver.swift:211-245`.
If the bridge is needed to produce a candidate list, its id-bearing MAL candidates use the same
shared ranking; id-less MangaDex rows are displayed as Listing suggestions but cannot be a MAL
progress match. The required regression test is
`MALEntityResolverTests.candidatesTopEqualsResolvePickWhenGuardClears`: inject one unique
threshold-clearing candidate, assert `candidates(for:).first.malID` equals `resolve(_:)`'s
`malId`, and assert the ambiguous case returns no accepted top candidate.

## Design

### 1. Explicit match flow

The local detail page shows a section titled **Metadata and sync**. Before confirmation it has:

- **Match…** — a visible, VoiceOver-operable button;
- the state text “Not matched”; and
- a short explanation: “Find this title in your services to add metadata and sync reading
  progress. MangaCarta will ask before linking it.”

Tapping Match… runs the resolver's read-only `candidates(for:)` seam with the Work's title evidence.
It never changes identity or
  sends progress. A sheet presents zero or more candidates. Each candidate states its provider,
  title, alternate title if it was the deciding spelling, MAL/AniList IDs when known, publication
  type/status, and (if a registered Source supplied it) the MangaDex Listing/source name. The
  sheet has **Use this match**, **Search again** (which permits a different title spelling but
  still uses the same resolver rules), and **Cancel**.

There are three policy options:

1. Auto-accept a unique exact result, ask for fuzzy or ambiguous results.
2. Always ask once, even for a unique exact result; remember the confirmed choice thereafter.
3. Never show candidates; make the user paste an external ID.

Choose option 2. The consequence of an incorrect exact title is still severe (title collisions,
regional editions and ComicInfo mistakes exist), and one confirmation is a small price for
progress safety. “Threshold” therefore controls whether a candidate is shown, not whether it is
silently attached. A confirmed choice is durable until Unmatch; a later background resolver pass
cannot replace it.

If there is no confident result, the sheet says **No confident match** and explains that no change
was made. It offers **Search by another title…**, prefilled with the collected spellings, and
**Done**. No negative result is treated as a match.

After confirmation the detail page shows **Matched to [provider title]**, the external IDs, and,
when selected, **Reading source: [Source]**. The action becomes **Change match…** and **Unmatch**.
If the selected external ID already belongs to another Work, confirmation pauses before any write
and shows: **“This will combine with <title> in your library. This can't be undone.”** The reader
must choose **Combine** or **Cancel**. Cancel leaves the local Work, match record and history
unchanged. There is no un-merge or split operation in `WorkStore` (`WorkStore.swift:299-329` is
the one-way merge path; a repository-wide search found no `unmerge` or `split` API).

Unmatch removes the local match record, external IDs and remote Listing link from the surviving
Work, leaves local chapters, history and the surviving Work intact, and suppresses automatic
re-prompting until the reader explicitly chooses Match… again. If confirmation previously merged
two Works, Unmatch **does not separate them**: the alias and combined Listings/history remain one
Work, and only the active external identity/link is removed. Unmatch does not delete metadata
already fetched; it marks that metadata stale/unsupported for this local Work and removes the
remote identity used for future sync.

### 2. What confirmation writes

Persist a separate `local-matches.json` owned by a new `LocalMatchStore`, not `LocalItemRecord`:

LocalMatchRecord
  localWorkID: WorkID
  confirmedAt: Date
  status: confirmed | rejected | unmatched
  malID: Int?
  aniListID: Int?
  remoteListing: ListingKey?
  evidence: [title spelling, candidate id, score, source id]
```

The record is user intent, not resolver cache. It is never expired or overwritten by a later
automatic result. A rejected candidate is retained only to avoid showing it again in the same
explicit flow; Unmatch clears the active identity but retains a tombstone sufficient to avoid an
automatic prompt. Reinstall loss is acceptable under the current no-sync boundary.

Confirmation performs these steps in order:

1. Resolve the local Work ID through aliases.
2. Persist the confirmed MAL/AniList IDs and any chosen remote Listing in the match store.
3. Call `WorkStore.setExternalIds` with the confirmed external IDs. If another Work owns one of
   them, this step happens only after the reader chooses **Combine** in the irreversible warning;
   use the existing external-ID merge path, never title-merge. The incumbent Work survives, and
   the local Listing and history follow the Work alias.
4. Add the selected remote Listing to that surviving Work. This is an explicit Listing link, not
   a new local replacement; it must preserve the local Listing as the bytes source and must never
   route through a different source because the selected Source is unavailable.
5. Trigger the metadata upgrade for the surviving Work and call the existing
   `MALProgressCoordinator.workMetadataChanged(survivorID)` so deferred completions are promoted.

If the reader confirms MAL/AniList metadata but no remote Listing, the local Work still gets a
provider identity and snapshot; its active fulfillment remains Local. If a remote Listing is
selected, the reader still defaults to Local for local Work detail and reader entry. Remote
fulfillment is an opt-in source choice, not an implicit replacement of local files.

### 3. Work identity and read state

Do not create a second “matched local” Work. A local Work is an ordinary ADR-0001 Work with a
`local` Listing. When the confirmed external ID is already owned, first require the explicit
Combine step above, then merge into that Work using the existing aliasing merge behavior. This is
the only safe deduplication key: equal titles are not
identity, and a local title can be a translation or a different edition.

ADR-0027 then applies without a new storage format. History and read marks remain Listing-keyed;
the Work-wide view unions parsed `ChapterOrdinal`s across all Listings. Existing local chapter
numbers remain stable. Remote chapter rows with the same numeric ordinal appear read/resumable when
the local chapter was read; unparseable labels match only by exact chapter ID, so an unnumbered
remote chapter is never guessed to equal a local one.

This intentionally accepts ADR-0027's existing risk that two sources split or renumber chapters
differently. The match sheet must disclose: “Read state follows numeric chapter numbers; editions
with different numbering may not line up.”

### 4. MAL progress mapping

On local completion, the existing `HistoryStore` completion callback is used. Local is not excluded
from the MAL-progress callback merely because it is excluded from update polling. Once confirmed,
`MALProgressCoordinator` finds the Work's MAL ID and enqueues the mapped integer progress.

Use the existing `MALChapterProgress.map`: `7` and `7.1` map to MAL progress `7`; non-numeric
labels do not enqueue progress. For a local Work with several completed chapters, each completion
raises the outbox's desired progress by max, so the queue sends the highest confirmed numeric
chapter reached. It never sends a count derived from the number of files, volume number, or a
fractional suffix. If a chapter was completed before confirmation, the deferred Work-keyed row is
promoted by `workMetadataChanged`; merging uses the canonical Work alias already supported by the
coordinator.

AniList progress is a separate owner decision: this slice stores the AniList ID and metadata but
does not invent an AniList write protocol. The implementation seam should leave a provider-neutral
completion event so an AniList outbox can be added without changing local matching or MAL rules.

### 5. MetadataUpgradeQueue and change notification

Local remains excluded from `LibraryRefreshCoordinator` and update notifications. Metadata matching
is different: a confirmed local Work with a remote identity is eligible for a provider metadata
fetch. Add a separate `metadataEligibility(for:)` predicate to the composition/queue wiring:

- ordinary local-only Works: ineligible;
- confirmed local Works with MAL/AniList IDs or a remote Listing: eligible;
- ordinary remote Works: unchanged;
- disabled/uninstalled remote Sources: do not fetch their Listing, but retain the confirmed IDs
  and local data.

The queue should expose an explicit `request(workID:)` or equivalent one-shot wake-up. Confirmation
calls it after `setExternalIds`; scene activation still calls `queue.start()` as the correctness
fallback (`MangaCartaApp.swift:266-274`). The queue fetches AniList through its existing rate
limiter, applies the one-provider snapshot through `WorkStore.apply`, and calls
`workMetadataChanged` after the external ID is learned or confirmed. The callback is not a signal
to refresh local content; it only promotes deferred MAL progress and wakes the relevant metadata
consumer.

The detail page's existing `onChange(of: vm.detailTags)` remains local provisional metadata. A
remote provider snapshot outranks those tags under `WorkStore`'s existing snapshot ordering; a
later local detail load must not overwrite it.

### 6. Candidate-to-Listing selection

Candidate generation and Listing selection are separate because `MALEntityResolver` intentionally
returns only a MAL answer. For each installed Source that is browsable and can search, the match
sheet may search the confirmed title. A MangaDex candidate is eligible for the **Remote Listing**
choice only when it carries the same confirmed MAL ID (`links.mal`), or when the user explicitly
confirms a candidate after seeing its title and source. Prefer the authoritative-ID case; do not
fuzzy-link an unrelated Listing just because its title is similar.

If no matching Source is installed, the match still provides MAL/AniList metadata and offers a
repository/source installation hint without blocking confirmation. Installing a Source later does
not silently attach it; Match… must be opened again.

## Data and persistence changes

- Add `LocalMatchStore` and versioned `local-matches.json` under Application Support. Keep it
  separate from `LocalLibraryStore` and `WorkStore`; it records user intent and must not be evicted
  with resolver caches.
- Add a `LocalMatchRecord` model with Codable migration defaults for old installs (no records).
- Add a Work-level local metadata evidence builder that appends Series, ComicInfo Title and filename
  stem to `knownTitles` without changing `displayTitle` or chapter numbers.
- Add an explicit Work-to-Listing link operation to `WorkStore`, or a narrowly scoped public wrapper
  around the existing link/merge invariants. It must resolve aliases, update `listingIndex`, and
  preserve both Listing keys.
- Add a queue metadata-eligibility/request seam distinct from `participatesInUpdates`.
- Do not add IDs to `LocalItemRecord`; the identity belongs to Work/match persistence, so deleting
  and re-importing a file can restore the same local Work without duplicating a match decision.
- New files under `MangaCarta/Models` or `MangaCarta/Services` are synchronized groups. New files
  under `MangaCarta/Views` and `MangaCartaTests` are not: use `xcp add-file` for every new test or
  view file, which writes the four required `project.pbxproj` entries. The likely test files are
  `MangaCartaTests/LocalMatchStoreTests.swift`, `MangaCartaTests/LocalMatchingCoordinatorTests.swift`,
  and `MangaCartaUITests/LocalMatchingUITests.swift` if a new UI file is needed; the UI test target
  follows the same plain-group rule.

## Errors and edge cases

- MAL/AniList/network failure: keep the Work unmatched, show “Couldn’t search right now,” and do
  not persist a negative resolver answer. Retry from Match…; no automatic progress is sent.
- No candidate or ambiguity guard refusal: show no confident match; never choose the top row.
- Two candidates with the same title: show both IDs/types and require explicit choice; novel and
  light-novel candidates must remain filtered as ADR-0017 requires.
- Candidate has no MAL ID: it may be shown as a MangaDex title but cannot satisfy MAL progress
  matching until the reader confirms a provider ID.
- Existing Work owns the confirmed MAL ID: pause before writing and require Combine/Cancel with the
  irreversible warning. After Combine, merge by external ID, preserve the incumbent Work ID, union
  Listings/known titles, and rely on ADR-0027's Work-wide ordinal derivation. The UI reports
  “Already matched; combined with your existing title.”
- Remote Source unavailable, disabled or uninstalled: keep the local Listing, match record and
  external IDs; metadata that can be fetched by provider ID remains usable; do not fall back to a
  different Source or delete the pin/match.
- Local Work has no ComicInfo: use filename stem as its sole title evidence, show a lower-confidence
  explanation, and still require confirmation.
- ComicInfo Series differs from filename or ComicInfo Title: display Series, search all distinct
  title spellings, and show the evidence spelling in the candidate row.
- Volume/Number are missing, non-decimal, or fractional: preserve local chapter ordering and use
  exact numeric `ChapterOrdinal` behavior; do not invent MAL progress for labels that
  `MALChapterProgress.map` rejects.
- Unmatch after queued progress: cancel only undelivered MAL outbox rows for this Work; leave
  already-delivered MAL progress alone. After a merge, this applies to the surviving Work and does
  not undo the merge or split its outbox/history.
- Unmatch after a merge: remove the external IDs and remote link from the survivor, but do not
  separate the Works; the alias, combined Listings and Work-wide read state remain.
- Deleting the local library item: preserve the Work/history rules from the local-import design;
  the match record is retained only while the Work still has a local Listing. If the Work is
  deleted because it had no other Listing, remove the match record with it.

## Accessibility

- Match…, Change match…, Unmatch, Search by another title…, Use this match and Cancel are native
  buttons with 44-point minimum hit targets and spoken labels that include the title where useful.
- Candidate rows expose one combined label: provider, title, external ID, media type/status,
  confidence explanation and whether a MangaDex Listing is available. Do not communicate selection
  by vermilion alone; use the native checkmark and selected accessibility value.
- The confirmation sheet has a meaningful VoiceOver order: explanation, candidate identity,
  consequences, primary action, secondary actions. Dynamic Type must allow candidate details to
  wrap; no fixed-height row may clip IDs or status.
- Unmatch confirmation states exactly what remains (“Your local chapters and read history stay on
  this device”), what stops (“future progress sync for this match”), and, after a merge, that
  “This does not separate the combined Works.” The pre-confirmation merge warning is read in full:
  “This will combine with <title> in your library. This can't be undone.”
- Follow DESIGN.md's Ink & Seal system: native sheets/controls, serif identity title, body copy in
  Dynamic Type, and vermilion only for the primary action or destructive Unmatch confirmation.

## Acceptance criteria and named tests

1. A local Work's distinct Series, ComicInfo Title and filename stem become ordered matcher input;
   Volume/Number never become title spellings. **Test:** `LocalMatchingCoordinatorTests`
   `localEvidenceUsesTitlesNotChapterNumbers`.
2. Matching exposes `candidates(for:)` as a read-only seam and shares the resolver's MAL pool,
   bridge partition and matcher ranking; `resolve` chooses the same top accepted candidate, and no
   match is auto-accepted. **Test:** `MALEntityResolverTests`
   `candidatesTopEqualsResolvePickWhenGuardClears`, `localMatchRequiresConfirmationForUniqueExactCandidate`
   and `localMatchRefusesAmbiguousCandidates`.
3. Confirming a candidate persists a durable match, external IDs and optional remote Listing; a
   relaunch restores it. **Test:** `LocalMatchStoreTests`
   `confirmedMatchRoundTripsAndUnmatchKeepsLocalWork`.
4. Confirming an ID already owned by another Work pauses with the exact irreversible Combine/Cancel
   warning; Combine uses external-ID merge, preserves the incumbent Work ID, keeps both Listings,
   and follows aliases, while Cancel makes no change. **Test:** hermetic `LocalMatchingUITests`
   `existingWorkShowsIrreversibleCombineWarning`, plus `LocalMatchingCoordinatorTests`
   `cancelledCombineDoesNotWrite`.
5. A local-only Work remains excluded from browse, update polling and notifications; a confirmed
   local Work is eligible only for metadata upgrade, not local content refresh. **Test:**
   `LibraryRefreshCoordinatorTests` `matchedLocalWorkIsNeverContentRefreshed` and
   `MetadataUpgradeQueueTests` `matchedLocalWorkCanRequestProviderMetadata`.
6. Confirmation triggers `workMetadataChanged` for the canonical survivor and promotes deferred MAL
   progress, including after a Work merge. **Test:** `MALProgressCoordinatorTests`
   `localConfirmationPromotesDeferredProgressThroughAlias`.
7. A completed local chapter with numeric label `7` queues MAL progress 7; `7.1` queues 7; `?`
   queues nothing. **Test:** `MALProgressCoordinatorTests` `localChapterProgressUsesExistingMapper`.
8. Work-wide read state matches local and remote chapters by `ChapterOrdinal`, leaves unparseable
   labels exact-ID-only, and does not migrate Listing-keyed storage. **Test:**
   `HistoryStoreTests` `matchedListingsShareNumericReadOrdinals`.
9. Unmatch removes the active remote association without deleting local pages, Work identity,
   history, or read marks; after a merge it removes external IDs/link but does not split the
   combined Works or aliases. **Test:** `LocalMatchingCoordinatorTests`
   `unmatchPreservesLocalData` and `unmatchAfterMergeDoesNotSplitWorks`.
10. The detail page exposes Match…/Unmatch and the confirmation sheet remains operable at larger
    Dynamic Type with VoiceOver labels and no color-only state. **Test:** hermetic
    `LocalMatchingUITests` `matchSheetIsAccessibleAndUnmatchIsExplicit`.
11. A network error, unavailable Source, or no confident candidate leaves no partial link and
    provides a retryable error string. **Test:** `LocalMatchingCoordinatorTests`
    `failedMatchDoesNotPersistPartialIdentity`.

## Implementation slices

1. **Evidence and persistence:** model local title evidence, `LocalMatchStore`, Codable migration,
   and pure matching/coordinator tests. No UI.
2. **Identity/linking:** add the explicit Work Listing-link operation, external-ID merge handling,
   confirmation/unmatch coordinator, and deferred MAL promotion. Existing app remains usable with
   Match… unreachable until the next slice.
3. **Metadata eligibility:** allow confirmed local Works through the provider metadata queue while
   keeping Local out of content refresh/update surfaces; add queue request and snapshot tests.
4. **Detail UX:** add the Match… sheet, candidate presentation, confirmation/unmatch copy,
   accessibility, and hermetic UI fixture path.
5. **Ordinal/progress hardening:** exercise local/remote ordinal presentation and MAL outbox behavior;
   document the AniList write seam without implementing an AniList write protocol.

## Owner decisions (2026-11-09)

1. **Unmatch cancels already queued but not yet delivered MAL progress.** Only undelivered outbox
   rows for this Work are removed; delivered history is preserved. This prevents a deliberate unlink
   from causing a later write while keeping server state irreversible and honest.
2. **A confirmed local Work defaults its detail page to Local.** The reader imported files to read
   those bytes; the existing source picker offers the remote Listing explicitly.
3. **AniList progress sync does not ship in this work.** Ship MAL metadata/progress and the
   provider-neutral completion seam first; AniList writes are a separately reviewable outbox with
   its own authentication and conflict policy.
