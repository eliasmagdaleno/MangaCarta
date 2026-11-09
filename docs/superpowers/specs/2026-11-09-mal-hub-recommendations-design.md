# MAL as the recommendation hub — Design

**Date:** 2026-11-09  
**Status:** Proposed owner review  
**Scope:** MAL-native Related and More Like This cards that can discover titles served by any installed Source.

## Goal

Make MyAnimeList the single recommendation and relationship catalog. A title returned by MAL should be
visible as a useful discovery card even when no installed Source serves it; opening the card then gives
the reader an honest, Source-aware way to find and confirm a readable copy. This gives every installed
Source recommendations for free, without measuring or scraping every Source on every detail-page open.

The design keeps MAL's ordering and metadata, keeps exact-id MangaDex cards opening in one tap, and
uses the reader's explicit choice as evidence when title matching is uncertain.

## Non-goals

- No new MAL recommendation endpoint, MAL write, account/list synchronization, or AniList fallback for
  recommendation cards.
- No automatic reverse-resolution sweep, background search of installed Sources, or per-Source
  reverse-resolution cache/miss TTL.
- No change to Work identity, Listing identity, fulfillment ranking, source pins, or the existing
  precision-biased forward resolver.
- No Source is searched merely because a MAL card is rendered; searches happen only after a reader taps.
- No new recommendation algorithm: MAL's recommendation weight remains the More Like This order, and
  MAL relationship order remains the Related order defined by the parallel Related spec.

## Current code this builds on

These files were opened while drafting this document.

- `MangaCarta/Services/MoreLikeThisProvider.swift:5-11,16-61` currently resolves a Work to a MAL id,
  calls `MyAnimeListAPI.mangaDetail`, takes the weighted top recommendations, reverse-resolves each
  recommendation, then drops unresolved, self, and duplicate results. `MangaCarta/Services/MALReverseResolver.swift:36-104,137-169,191-242`
  owns the single-Source reverse path, its four-task window, and its resolved/unresolved/throw cache
  discipline.
- `MangaCarta/Models/MyAnimeListAPI.swift:33-71,74-97,171-197` decodes MAL manga titles, alternate
  titles, pictures, synopsis, genres, relations, and recommendations. `mangaDetail` currently requests
  `alternative_titles,synopsis,main_picture,genres,related_manga,recommendations` in one call; it does
  not request `nsfw` today. `MyAnimeListManga.allTitles` already provides ordered matching spellings.
- `MangaCarta/Services/MALTitleMatcher.swift:25-109` is pure and precision-biased: normalized
  Levenshtein, threshold `0.90`, and a `0.05` ambiguity margin. It supports exact-id selection through
  the existing `MoreLikeThis.pickMatch` path; this design must preserve that stronger arm.
- `MangaCarta/Services/MALEntityResolver.swift:16-136,280-311` resolves any Source's title forward to MAL, including
  the ADR-0019 bridge. A Work without a MAL id therefore has no MAL-native rail input.
- `MangaCarta/Models/MangaSource.swift:17-33,53-59,83-92` requires every Source to implement title
  `search`, and supplies detail/chapter operations. Search results include a Source-local id, title,
  cover, alternate titles, external id when known, and content rating through `MangaCarta/Models/MangaModels.swift:18-44`.
- `MangaCarta/Services/SourceRegistry.swift:118-170,196-220` provides active/registered Sources,
  browsability, adult admission, and discovery admission. `visibleSources(includeAdult:)` is for
  picker visibility; the resolver must use the same effective admission rules and never route a retired
  or hidden Source as a fallback.
- `MangaCarta/Models/AdultContentFilter.swift:5-20` defines the fail-closed discovery rule: with the
  switch off, `erotica` and `pornographic` are rejected and an unrated title from an adult-declaring
  Source is rejected.
- `MangaCarta/Models/CandidateProvider.swift:93-153,165-225` shows that `MALCandidateProvider`
  currently consumes already-resolved `Manga` values, while `CompositeCandidateProvider` treats the MAL
  pool as a graceful-degradation signal. `MangaCarta/Services/AppComposition.swift:384-414` wires that
  provider with the shared reverse resolver.
- `MangaCarta/Services/WebViewService.swift:20-35,94-159` and `MangaCarta/Models/MangaSource.swift:96-118`
  establish the interactive Cloudflare behavior: an admitted Source search can surface a challenge,
  wait up to 120 seconds, and return a typed unsolved/timeout error; navigation and script timeouts are
  bounded. A tap is an acceptable point to ask the reader for that interaction.
- `docs/adr/0005-manual-link-override.md:71-112` keeps precision bias while making a user-established
  link authoritative and non-evictable. `docs/adr/0019-bridging-resolution-for-sources-that-publish-no-external-ids.md:70-130`
  confirms that a bridge may assert an id but must not silently create a Listing link. This feature's
  confirmed choice is the explicitly user-driven exception and must be stored separately from a cache.
- `docs/adr/0020-widening-the-search-input-on-the-reverse-resolution-path.md:21-35,81-116,138-145`
  fixes the existing reverse-search fan-out and explains why it is not evidence for an all-Source
  background sweep.
- `docs/superpowers/specs/2026-08-13-reverse-resolution-beyond-mangadex-measurement-protocol.md:8-39,78-129`
  measured recall/cost as the question for an automatic fallback. Its result,
  `docs/superpowers/specs/2026-08-15-reverse-resolution-beyond-mangadex-measured.md:42-94`, found a
  generous ceiling of 90/100 already served by MangaDex and only 10 possible additional cards, making
  a scraped round trip on every open unjustified. That is a yield/cost rejection, not a matcher-precision
  rejection.
- `../spec-related-mal-cache/docs/superpowers/specs/2026-11-09-related-titles-and-mal-cache-design.md:8-35,90-187,218-239,241-287`
  is the parallel Related/cache design. It defines a 24-hour `MALDetailStore`, stale-if-offline,
  Related before More Like This, and the existing resolve-then-show Related projection. This design
  amends that projection rather than contradicting its cache, ordering, accessibility, and MAL DTO rules.

## Design

### 1. MAL-native candidate model

Introduce a presentation-only `MALDiscoveryCandidate` built from a cached `MyAnimeListManga` node and,
for the detail preview, the parent `MyAnimeListMangaDetail`:

```swift
struct MALDiscoveryCandidate: Identifiable, Equatable {
    let malId: Int
    let title: String
    let alternateTitles: [String]
    let coverURL: URL?
    let synopsis: String?
    let genres: [String]
    let reason: MALDiscoveryReason       // related(label) or recommendation
}
```

The node's `mainPicture.large ?? medium` is the cover. Recommendation candidates retain MAL's
`numRecommendations` sort; Related candidates retain the Related spec's semantic relation grouping
and label. Self and duplicate MAL ids are removed, but a candidate is not removed merely because it
has no installed match. Candidate identity is `malId`, not a Source-local id.

Options considered:

1. Keep resolve-then-show: cheapest UI change, but silently drops the very titles that make the hub
   useful to new Sources. Rejected.
2. Show unresolved titles as disabled cards: honest, but turns discovery into a dead end and makes a
   whole rail look noisy. Rejected.
3. **Show MAL-native cards and resolve on tap (selected):** every card has useful metadata, while only
   interested cards incur Source work. A quiet status stamp (`ON YOUR SOURCES` or `NOT ON YOUR SOURCES`)
   communicates availability without making unavailable cards errors.

### 2. One detail cache, two MAL-native rails

Amend the Related spec's `RelatedTitle` projection so the cached MAL relation first becomes a
`MALDiscoveryCandidate`; it no longer requires a confident Source match to render. Keep all of its
decisions: one `MALDetailStore` fetch shared by Related and More Like This, 24-hour freshness,
stale-if-offline, relation label normalization/order, and Related before More Like This.

The More Like This provider similarly returns candidates from the same cached detail payload. A detail
page therefore costs at most one MAL detail call on a cold/expired cache, not one call per rail. A MAL
id is still required; if forward resolution fails, both rails remain hidden as today. No AniList fallback
is added: AniList can enrich Work metadata, but using it as a second recommendation catalog would make
the MAL hub non-single-source and would need a separate adult/privacy contract.

An exact-id match from the active/external-id Source keeps the existing one-tap behavior: its card may
open the Source detail directly. Resolved and unresolved cards may coexist in the same rail. A resolved
card shows the Source stamp; an unresolved card shows `NOT ON YOUR SOURCES` in neutral metadata and keeps
the MAL cover/title. It is not an error badge and does not claim the title is absent from the internet.

### 3. Tap flow: preview, then Source resolution

Tapping any candidate opens a lightweight MAL-backed preview sheet/navigation destination immediately.
It uses the already-cached title, cover, synopsis, and genres; no Source request is needed just to read
about the title. The primary action is `Read on…`; secondary copy says `MAL title · {id}` only when
useful for disambiguation.

On `Read on…`, check the non-evictable confirmation store first. If it contains a still-installed,
admitted Source listing, open that Listing directly. Otherwise search every currently installed,
admitted, browsable Source, including Sources that do not publish MAL ids. Never search Local: it is
always registered but excluded from browse/update surfaces and cannot serve remote discovery.

For each Source, search the MAL primary title first, then at most two additional MAL spellings from
`allTitles`, matching ADR-0020's maximum of three queries. Each Source's result pool is matched with
the shared matcher and exact external-id preference:

- a result whose external MAL id equals the candidate id is a confident exact match;
- otherwise score Source title plus `altTitles` against MAL's full ordered title set using the existing
  `0.90` threshold and `0.05` ambiguity guard;
- a Source may return a fuzzy match for reader confirmation, but the app must never open it silently;
- deduplicate a Source's repeated result by Source-local id, and never compare ids from different Sources.

Present results grouped by Source name. An exact match may be opened directly when there is one exact
match across all Sources; if several Sources have exact matches, show the Source choices so the reader
can choose where to read. Fuzzy/ambiguous candidates are always shown as choices, never auto-opened.
The choice row includes Source name, cover, title, alternate titles when they differ, MAL title, and a
chapter count when cheaply available. Chapter count is an optional detail fetched only for the displayed
top three choices globally, with the same bounded/timeout policy; absence is shown as `Chapter count
unknown`, never as zero. This makes a fuzzy confirmation informative without turning every search result
into a full Source-detail crawl.

If no Source produces a choice, show `Not on your Sources` and `Add a repository in Settings to add
more places to read.` Keep the MAL preview available and provide `Done`; do not call this a MAL failure.
If a Source search throws, mark that Source `Couldn't check` with `Try again`; continue displaying other
Source results. A thrown search never writes a negative cache entry.

### 4. Remembered confirmation

Add a `MALSourceChoiceStore` (or equivalent name) under `Services/`, persisted in Application Support,
keyed by `(malId, sourceId)` and storing the Source-local manga id, title at confirmation time, and
confirmed date. This is user evidence, not an `EntityResolutionStore` cache. It is never expired by a
TTL and is invalidated only when the Source-local id is no longer served or the reader explicitly
chooses a different Source.

Confirmation writes only after the reader taps a displayed choice. It records the MAL-to-Listing
choice, not a Work merge and not a claim that every same-title Source listing is identical. Opening a
remembered choice revalidates that the Source is installed, admitted, and can fetch the listing; if
validation fails, discard only that stale choice and return to the grouped chooser. This follows
ADR-0005's durable, user-correctable evidence rule while avoiding automatic identity mutation.

Options considered: reuse `EntityResolutionStore` (wrong lifecycle and cache semantics), write a Work
manual link immediately (would mutate library identity from discovery), or **use a separate durable
choice store (selected)**. The separate store preserves the user's confirmed navigation preference and
keeps Work/Listing identity decisions out of a recommendation tap.

### 5. Cost, concurrency, and challenges

The detail path is one cached MAL call at most per 24 hours, as specified by the parallel Related spec.
Tap-time resolution is bounded as follows:

- no more than four Source search operations in flight globally;
- no more than three title spellings per Source, and stop widening after an exact match;
- per-search deadline eight seconds at the orchestration layer, while allowing a Source's own request
  timeout to classify the failure;
- cancel all remaining searches when the reader leaves the preview or taps a result;
- cap displayed choice enrichment at three chapter-count requests globally, with four-task concurrency.

These bounds are deliberately separate from the old automatic reverse resolver: the user has expressed
interest, so a slower tap is acceptable, but the sheet must remain cancellable and finite.

HTML/Cloudflare Sources use their existing WebView/Host path. If a search surfaces an interactive
challenge, the tap flow may present the existing challenge sheet. Solving it lets that Source continue;
cancel, timeout, or sticky decline marks only that Source unavailable for this attempt and does not
block other Sources. A challenge is not treated as “not on your Sources.”

### 6. Adult content and privacy

Add MAL's `nsfw` field to the detail request/model if the API supplies it, and decode it optional/fail
closed. The requested fields become the existing detail fields plus `nsfw`; the cache DTO and fixture
round-trip must include it. With `Show adult content` off, suppress MAL-native candidates when MAL marks
them `nsfw`, when any MAL genre is an agreed adult genre (`erotica`/`pornographic`), or when the
candidate has no MAL rating signal but the candidate would be opened on an adult-declaring Source.
The final Source listing is still checked by `SourceRegistry.admitsForDiscovery`. Unknown MAL data does
not become proof of safety. With the switch on, normal Source admission and the declared-age gate still
apply.

The adult policy has two options: rely only on MAL `nsfw` (simple but can miss genre-labelled adult
titles), or **combine optional `nsfw` with the existing adult genre names and final Source admission
(selected)**. This is fail-closed discovery behavior consistent with ADR-0022; the owner should confirm
whether the genre set needs a broader, centrally-owned list before implementation.

MAL requests are the same public detail calls already made today and are cached as the Related spec
defines. Source searches carry the MAL title only after an explicit tap; rendering a card sends no
Source query. The choice store contains no credentials or reading history. Do not log MAL ids alongside
Source search URLs or challenge content beyond existing diagnostics.

### 7. What this does to reverse-resolution measurement

Do not re-measure or build the separate “reverse resolution beyond MangaDex” protocol for this feature.
That protocol answered whether automatic fallback could justify its per-open scrape cost; it found only
10 possible extra cards beyond MangaDex's 90/100, and explicitly did not reject matcher precision.
Resolve-on-tap avoids both problems: it searches only cards a reader wants to open, and the reader
confirms fuzzy candidates rather than forcing a pre-measured automatic choice. A future automatic
background resolver would need a new owner-approved protocol; this design does not create one.

## Persistence and graph changes

1. Extend the MAL detail DTO/cache slice from the parallel Related spec with optional `nsfw` and expose
   one cached candidate projection for both rails.
2. Replace More Like This and Related's “resolved Manga only” presentation values with MAL-native
   candidates while retaining the existing ordering, self/duplicate filtering, and cache lifecycle.
3. Add an injected `MALSourceChoiceStore` in `AppComposition`; do not use a singleton from views or
   view models. New service files under `MangaCarta/Services/` are synchronized and need no project edit.
4. Add a tap-resolution coordinator that receives `SourceRegistry`, the candidate, matcher, clock,
   and Source-search seams. It returns grouped exact/fuzzy choices and typed per-Source failures.
5. If a new preview/coordinator view or test file is added under `Views/` or `MangaCartaTests/`, those
   folders are plain Xcode groups: use `xcp add-file ... --targets MangaCarta` or
   `--targets MangaCartaTests` so the four project entries are created. Adding tests to the existing
   `MangaCartaTests.swift` avoids a project edit.

## Error and edge cases

- No MAL id after forward resolution: hide both rails, as today; do not query AniList or Sources.
- MAL detail missing/empty/null relations or recommendations: hide only the corresponding rail; a valid
  empty payload replaces stale cards after a successful refresh.
- MAL title has no cover or synopsis: use the existing screentone placeholder and a concise “No synopsis
  available” label; matching still uses all available titles.
- A Source returns zero results, malformed results, rate limit, timeout, navigation failure, or
  Cloudflare decline: keep other Source groups; distinguish `Couldn't check` from `Not on your Sources`.
- Source disabled/uninstalled or hidden by adult gating between search and open: revalidate and return to
  the chooser; never route to another Source silently.
- Several exact matches: show Source choices, because exact identity does not establish the reader's
  preferred fulfillment Source.
- Several fuzzy matches within one Source: show all candidates only when they are within the matcher
  result window; label the group “Choose a match” and never preselect.
- A remembered choice whose title changed: show the stored title as historical context, re-search if the
  id is unavailable, and overwrite only after a new explicit confirmation.
- Cancellation: cancel child tasks, do not write a choice or negative result, and do not leave a loading
  announcement or challenge sheet attached to a dismissed preview.

## Accessibility and visual treatment

Use the existing Ink & Seal cover card, `MangaRail`, `InkSectionHeader`, semantic colors, and Dynamic
Type. Availability is a spoken/textual stamp, not cover tint. “Not on your Sources” is neutral metadata;
it must not sound like an error. Every MAL card has a 44-point action target and an accessibility label
including title, rail reason, and availability (for example, “Planetes, recommended by MyAnimeList,
not on your Sources”).

The preview announces title, MAL source, synopsis, genres, and the `Read on…` action. The grouped
chooser announces Source name, title, match confidence (“exact match” or “possible match”), alternate
titles, and chapter count/unknown. Exact choices use a checkmark and words, never color alone. Challenge
presentation retains the existing VoiceOver-operable sheet and Cancel action. At large Dynamic Type,
rows become taller and wrap metadata; no title or confidence label is truncated.

## Acceptance criteria and named tests

1. **A cached MAL detail produces both MAL-native rails with one fetch** —
   `MALHubProjectionTests.testRelatedAndRecommendationsShareOneCachedDetailFetch`.
2. **Recommendation order, relation order/labels, self removal, and MAL-id de-duplication remain
   stable while unresolved candidates are retained** —
   `MALHubProjectionTests.testNativeCandidatesKeepOrderAndRetainUnresolvedTitles`.
3. **A Work without a MAL id produces no MAL-native rail and performs no Source search** —
   `MALHubProjectionTests.testMissingMALIdentityHidesBothRails`.
4. **MAL primary/alternate title, cover, synopsis, and genres map into the preview** —
   `MALHubProjectionTests.testPreviewUsesCachedMALMetadata`.
5. **Exact external-id match wins and opens in one tap; exact matches from multiple Sources show a
   Source chooser** — `MALHubResolutionTests.testExactIdOpensDirectly` and
   `testMultipleExactSourcesRequireChoice`.
6. **Fuzzy matches use the 0.90 threshold and 0.05 ambiguity guard, but displayed fuzzy choices require
   confirmation** — `MALHubResolutionTests.testFuzzyChoicesRequireReaderConfirmation` and
   `testAmbiguousChoicesAreShownWithoutPreselection`.
7. **All admitted browsable non-Local Sources are searched with at most three spellings, with at most
   four searches in flight** — `MALHubResolutionTests.testSearchesEveryAdmittedSourceWithBoundedConcurrency`.
8. **A Source timeout, rate limit, or challenge decline does not suppress other Source results and is
   not recorded as a negative cache miss** — `MALHubResolutionTests.testSourceFailureIsPerSourceAndTransient`.
9. **Cloudflare interaction can be surfaced after a tap and cancellation leaves no pending work** —
   hermetic `MALHubResolutionUITests.testTapMayPresentChallengeAndCancelReturnsToPreview`.
10. **A confirmed choice is persisted, reopened directly while valid, and invalidated when its Source
    or listing disappears** — `MALSourceChoiceStoreTests.testConfirmedChoiceSurvivesReload` and
    `MALHubResolutionTests.testMissingRememberedChoiceFallsBackToChooser`.
11. **Adult MAL candidates are hidden with the switch off for `nsfw`, adult genres, and adult-declaring
    Sources, and admitted when the switch is on** — `MALHubAdultTests.testAdultNativeCardsRespectADR0022`.
12. **Cards do not search Sources until `Read on…` is tapped; MAL calls remain cache-bounded** —
    `MALHubPrivacyTests.testRenderingDoesNotContactSources` and
    `MALDetailStoreTests.testFreshEntryAvoidsFetchWithin24Hours`.
13. **The detail UI mixes resolved and unresolved cards, exposes truthful VoiceOver labels, and shows
    the honest empty state** — hermetic `MALHubUITests.testUnavailableCardIsLabeledWithoutSources` and
    `testNotOnYourSourcesStateOffersRepositoryHint`.
14. **All new tests use the iPhone 17 Pro destination and Swift 6.0-compatible ordinary actors/tasks;
    no isolated conformances, `nonisolated(nonsending)`, `@concurrent`, or `Task.immediate`.**

## Implementation slices

1. **Slice 1 — shared cached MAL projection:** land the parallel Related cache, optional `nsfw`, and
   pure Related/More Like This MAL-native candidate projections. Existing rails can remain temporarily
   resolved-only behind the new model; unit tests prove ordering and cache sharing.
2. **Slice 2 — tap resolver and durable choice:** add the injected coordinator, per-Source bounded
   searches, matcher confidence model, challenge/error states, and `MALSourceChoiceStore`. Unit tests
   prove exact/fuzzy/ambiguous behavior without UI.
3. **Slice 3 — preview, mixed rails, and accessibility:** change the detail UI to render all admitted
   MAL candidates, add preview/chooser/empty states, and add hermetic UI coverage. Each slice is
   independently mergeable and no background reverse-resolution migration is required.

## Open questions for the owner

1. **Recommended:** combine optional MAL `nsfw`, the existing `erotica`/`pornographic` genre checks,
   and final Source admission, fail-closed when adult data is unknown. Owner: should the adult genre set
   be broadened in this feature, or remain the existing centrally-owned set?
2. **Recommended:** show one MAL-native mixed rail per section, with a quiet `NOT ON YOUR SOURCES`
   stamp and no disabled treatment. Owner: should unavailable cards be visually dimmed slightly, or use
   the same card treatment as available cards for a calmer rail?
3. **Recommended:** remember a confirmed `(MAL id, Source id, listing id)` indefinitely but expose
   “Choose another Source” in the preview menu. Owner: should Settings also expose a list/clear control
   for remembered choices, or is the per-preview control sufficient?
4. **Recommended:** fetch chapter counts only for the top three displayed choices and label missing data
   “Chapter count unknown.” Owner: is that small enrichment worth the extra Source calls, or should the
   chooser omit chapter counts entirely for the first PR?
5. **Recommended:** keep MAL as the only rail provider and hide rails without a MAL id. Owner: should a
   future AniList fallback be tracked as a separate proposal, rather than weakening this MAL-hub scope?
