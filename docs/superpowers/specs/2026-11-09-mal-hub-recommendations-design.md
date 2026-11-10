# MAL as the recommendation hub — Design

**Date:** 2026-11-09  
**Status:** Proposed — revised after coordinator review 2026-11-10; owner chose adult option B  
**Scope:** MAL-native Related and More Like This cards that can discover titles served by any installed Source.

## Goal

Make MyAnimeList the single recommendation and relationship catalog. A title returned by MAL should be
visible as a useful discovery card even when no installed Source serves it; opening the card then gives
the reader an honest, Source-aware way to find and confirm a readable copy. This gives every installed
Source recommendations for free, without measuring or scraping every Source on every detail-page open.

The design keeps MAL's ordering, keeps exact-id cards opening in one tap, and uses the reader's explicit
choice as evidence when title matching is uncertain.

## Relationship to the Related design

This document **amends PRs 2 and 3** of the Related design
(`docs/superpowers/specs/2026-11-09-related-titles-and-mal-cache-design.md`, "Implementation slices").
Those PRs specify a resolve-then-show `RelatedTitle` projection — a relation renders only once it has a
confident Source match. This design replaces that projection with MAL-native candidates (section 2).

**Related PR 1, the `MALDetailStore` cache, is unaffected** and is being built now. Its 24-hour TTL,
stale-if-offline fallback, fetch coalescing and Related-before-More-Like-This order all stand. The one
addition this design makes to its DTO — an optional `nsfw` field (section 6) — is backward-compatible:
`nsfw` decodes optional, so records cached before the field existed still load, and simply carry no
`nsfw` value until their next refresh.

## Non-goals

- No new MAL recommendation endpoint, MAL write, account/list synchronization, or AniList fallback for
  recommendation cards.
- No automatic all-Source reverse-resolution sweep, background search of installed Sources, or
  per-Source reverse-resolution cache/miss TTL.
- No change to Work identity, Listing identity, fulfillment ranking, source pins, or the existing
  precision-biased forward resolver.
- Rendering a card contacts no Source **beyond the existing external-id reverse resolution**, which keeps
  running at render time exactly as it does today (section 2). Only the all-Source title search waits for
  a tap.
- No change to the home For You rail. `SimilarTitlesProviding.recommendations(for:limit:) -> [Manga]` and
  its resolved-only output stay as they are (section 2).
- No per-card MAL fetches to learn whether an unrendered card is adult (section 6).
- No new recommendation algorithm: MAL's recommendation weight remains the More Like This order, and
  MAL relationship order remains the Related order defined by the Related design.

## Current code this builds on

These files were opened while drafting this document.

- `MangaCarta/Services/MoreLikeThisProvider.swift:5-11,16-61` currently resolves a Work to a MAL id,
  calls `MyAnimeListAPI.mangaDetail`, takes the weighted top recommendations, reverse-resolves each
  recommendation, then drops unresolved, self, and duplicate results. `MangaCarta/Services/MALReverseResolver.swift:36-104,137-169,191-242`
  owns the single-Source external-id reverse path (MangaDex today), its four-task window, and its
  resolved/unresolved/throw cache discipline over `EntityResolutionStore`.
- `MangaCarta/Models/MyAnimeListAPI.swift:33-71,74-97,171-197` decodes MAL manga titles, alternate
  titles, pictures, synopsis, genres, relations, and recommendations. `mangaDetail` currently requests
  `alternative_titles,synopsis,main_picture,genres,related_manga,recommendations` in one call; it does
  not request `nsfw` today. **Those fields apply to the top-level manga only.** The doc comment on
  `alternativeTitles(id:)` records that MAL does not apply top-level `fields` to nested nodes: a
  `recommendations` or `related_manga` node carries only `id`, `title` and `main_picture`. So a nested
  node's `allTitles` is just its main title, and it has no synopsis, genres, alternate titles or `nsfw`.
  `alternativeTitles(id:)` exists precisely to fetch the full spelling set for one id.
- `MangaCarta/Services/MALTitleMatcher.swift:25-109` is pure and precision-biased: normalized
  Levenshtein, threshold `0.90`, and a `0.05` ambiguity margin. It supports exact-id selection through
  the existing `MoreLikeThis.pickMatch` path; this design must preserve that stronger arm.
- `MangaCarta/Services/MALEntityResolver.swift:16-136,280-311` resolves any Source's title forward to MAL, including
  the ADR-0019 bridge. A Work without a MAL id therefore has no MAL-native rail input.
- `MangaCarta/Models/MangaSource.swift:17-33,53-59,83-92` requires every Source to implement title
  `search`, and supplies detail/chapter operations. Search results include a Source-local id, title,
  cover, alternate titles, external id when known, and content rating through `MangaCarta/Models/MangaModels.swift:18-44`.
- `MangaCarta/Services/SourceRegistry.swift:118-170,196-220` provides active/registered Sources,
  browsability, adult admission, and discovery admission (`admitsForDiscovery`). `visibleSources(includeAdult:)`
  is for picker visibility; the resolver must use the same effective admission rules and never route a
  retired or hidden Source as a fallback.
- `MangaCarta/Models/AdultContentFilter.swift:5-20` defines the fail-closed discovery rule over **Source
  content ratings**: with the switch off, the MangaDex-style ratings in `AdultContentFilter.adultRatings`
  (`erotica`, `pornographic`) are rejected and an unrated title from an adult-declaring Source is
  rejected. These are Listing ratings, not MAL genre names.
- `MangaCarta/Models/CandidateProvider.swift:93-153,165-225` shows that `MALCandidateProvider`
  consumes `SimilarTitlesProviding.recommendations(for:limit:) -> [Manga]` — already-resolved Listings —
  while `CompositeCandidateProvider` treats the MAL pool as a graceful-degradation signal.
  `MangaCarta/Services/AppComposition.swift:384-414` wires that provider with the shared reverse resolver.
- `MangaCarta/Services/WebViewService.swift:20-35,94-159` and `MangaCarta/Models/MangaSource.swift:96-118`
  establish the interactive Cloudflare behavior: an admitted Source search can surface a challenge,
  wait up to `challengeTimeout` (120 seconds), and return a typed unsolved/timeout error; navigation and
  script timeouts are bounded. A tap is an acceptable point to ask the reader for that interaction.
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
- `docs/superpowers/specs/2026-11-09-related-titles-and-mal-cache-design.md` is the Related/cache design.
  It defines a 24-hour `MALDetailStore`, stale-if-offline, Related before More Like This, and the
  resolve-then-show Related projection that this design amends (see "Relationship to the Related design").

## Design

### 1. MAL-native candidate model

Introduce a presentation-only `MALDiscoveryCandidate` built from a nested node of the cached parent
`MyAnimeListMangaDetail`. Because nested nodes are sparse, the candidate holds only what a node really
carries, plus the result of the existing external-id reverse resolution:

```swift
struct MALDiscoveryCandidate: Identifiable, Equatable {
    let malId: Int
    let title: String                    // the node's main title
    let coverURL: URL?
    let reason: MALDiscoveryReason       // related(label) or recommendation
    let resolvedListing: Manga?          // existing external-id reverse resolution, if it hit
}
```

The node's `mainPicture.large ?? medium` is the cover. There is deliberately no synopsis, genre,
alternate-title or `nsfw` field: the node has none, and inventing empty ones would read as "MAL says
none". Those come from the tap-time preview fetch (section 3).

Recommendation candidates retain MAL's `numRecommendations` sort; Related candidates retain the Related
design's semantic relation grouping and label. Self and duplicate MAL ids are removed, but a candidate
is not removed merely because it has no installed match — subject to the adult rule in section 6.
Candidate identity is `malId`, not a Source-local id.

Options considered:

1. Keep resolve-then-show: cheapest UI change, but silently drops the very titles that make the hub
   useful to new Sources. Rejected.
2. Show unresolved titles as disabled cards: honest, but turns discovery into a dead end and makes a
   whole rail look noisy. Rejected.
3. **Show MAL-native cards and resolve on tap (selected):** every card has a MAL cover and title, while
   only interested cards incur all-Source work. A quiet status stamp (`ON YOUR SOURCES` or
   `NOT ON YOUR SOURCES`) communicates availability without making unavailable cards errors.

### 2. One detail cache, two MAL-native rails

Amend the Related design's `RelatedTitle` projection so the cached MAL relation first becomes a
`MALDiscoveryCandidate`; it no longer requires a confident Source match to render. Keep all of that
design's other decisions: one `MALDetailStore` fetch shared by Related and More Like This, 24-hour
freshness, stale-if-offline, relation label normalization/order, and Related before More Like This.

The More Like This detail rail similarly returns candidates from the same cached detail payload. A
detail page therefore costs at most one MAL detail call on a cold/expired cache, not one call per rail.
A MAL id is still required; if forward resolution fails, both rails remain hidden as today. No AniList
fallback is added: AniList can enrich Work metadata, but using it as a second recommendation catalog
would make the MAL hub non-single-source and would need a separate adult/privacy contract.

**Render-time resolution is unchanged.** The existing external-id reverse resolution
(`MALReverseResolver`, MangaDex today, cached in `EntityResolutionStore`) keeps running when the rails
render, exactly as now. It is what fills `resolvedListing` and so what makes a card `ON YOUR SOURCES`
with exact-id one-tap open. The only Source work that waits for a tap is the new all-Source title search
of section 3. A resolved card shows the Source stamp; an unresolved card shows `NOT ON YOUR SOURCES` in
neutral metadata and keeps the MAL cover/title. It is not an error badge and does not claim the title is
absent from the internet. Resolved and unresolved cards may coexist in the same rail.

**The home For You rail does not change.** `MALCandidateProvider` (`Models/CandidateProvider.swift`)
consumes `SimilarTitlesProviding.recommendations(for:limit:) -> [Manga]`, and that protocol keeps its
signature and its resolved-only output: the home rail ranks Listings it can open, and has no preview or
chooser. The MAL-native candidate projection is a **separate detail-page API** on the provider (for
example `nativeCandidates(for:)`), not a change to `SimilarTitlesProviding`. Both read the same
`MALDetailStore` payload.

### 3. Tap flow: preview, then Source resolution

Tapping any candidate opens a lightweight MAL-backed preview immediately, showing the candidate's
cached cover and title at once. Opening the preview makes **one MAL detail fetch for the tapped id,
through `MALDetailStore`**, so it is cached for 24 hours like any other detail and a second open is
free. That fetch supplies the synopsis, genres, alternative titles and `nsfw`, which load into the
preview when it returns; until then the preview shows a loading state for those rows, and if the fetch
fails it keeps the cover and title and says `Details unavailable` without blocking `Read on…`. The
primary action is `Read on…`; secondary copy says `MAL title · {id}` only when useful for
disambiguation.

On `Read on…`, a resolved candidate (`resolvedListing` present, single exact-id match) opens that Listing
directly, as today. Otherwise check the non-evictable confirmation store first. If it contains a
still-installed, admitted Source listing, open that Listing directly. Otherwise search every currently
installed, admitted, browsable Source, including Sources that do not publish MAL ids. Never search
Local: it is always registered but excluded from browse/update surfaces and cannot serve remote
discovery.

For each Source, search the MAL primary title first, then at most two additional MAL spellings,
matching ADR-0020's maximum of three queries. **The spellings come from the tap-time detail's
alternative titles** (or, if that fetch failed, from `MyAnimeListAPI.alternativeTitles(id:)`) — never
from the nested node's `allTitles`, which is only the main title. If neither is available, search the
main title alone. Each Source's result pool is matched with the shared matcher and exact external-id
preference:

- a result whose external MAL id equals the candidate id is a confident exact match;
- otherwise score Source title plus `altTitles` against MAL's full ordered title set using the existing
  `0.90` threshold and `0.05` ambiguity guard;
- a Source may return a fuzzy match for reader confirmation, but the app must never open it silently;
- deduplicate a Source's repeated result by Source-local id, and never compare ids from different Sources;
- every result shown must pass `SourceRegistry.admitsForDiscovery`.

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

The detail path is one cached MAL call at most per 24 hours, as specified by the Related design; the
preview adds at most one cached MAL call per tapped id. Tap-time resolution is bounded as follows:

- no more than four Source search operations in flight globally;
- no more than three title spellings per Source, and stop widening after an exact match;
- per-search deadline eight seconds at the orchestration layer, while allowing a Source's own request
  timeout to classify the failure — **except while an interactive challenge sheet is up** (below);
- cancel all remaining searches when the reader leaves the preview or taps a result;
- cap displayed choice enrichment at three chapter-count requests globally, with four-task concurrency.

These bounds are deliberately separate from the existing render-time reverse resolver: the user has
expressed interest, so a slower tap is acceptable, but the sheet must remain cancellable and finite.

HTML/Cloudflare Sources use their existing WebView/Host path. If a search surfaces an interactive
challenge, the tap flow may present the existing challenge sheet. **That search is exempt from the
eight-second orchestration deadline while the sheet is up**; it is bounded instead by
`WebViewService.challengeTimeout` (120 seconds) and by the reader's Cancel. Once the sheet is dismissed
or solved, the search's remaining work is bounded normally. Solving it lets that Source continue;
cancel, timeout, or sticky decline marks only that Source unavailable for this attempt and does not
block other Sources. A challenge is not treated as "not on your Sources."

### 6. Adult content and privacy

**Owner decision (2026-11-10): option B.** No per-card MAL fetch is made to learn whether a card is
adult. Nested nodes carry no `nsfw` and no genres, so an unresolved card's adult status is unknown at
render time, and unknown is not safe.

- **"Show adult content" OFF:** a MAL-native card is shown **only** if the existing external-id reverse
  resolver resolved it to a Listing that `SourceRegistry.admitsForDiscovery` admits. This is today's
  behaviour: the Listing's own content rating and its Source's declaration decide. Unresolved
  (`NOT ON YOUR SOURCES`) cards are not rendered.
- **"Show adult content" ON:** unresolved cards appear too. Normal Source admission still applies to
  every Listing a search offers, and the declared-age gate (ADR-0022 A2) still applies to the Sources
  that can be searched.

`nsfw` is used only where MAL genuinely supplies it — a **top-level** detail: the parent Work's cached
detail and the preview's own tapped-id fetch (section 3), both through `MALDetailStore`. Add `nsfw` to
`mangaDetail`'s requested fields and to the DTO as an **optional** value, so records cached before the
field existed still decode (see "Relationship to the Related design"). It is a string enum —
`white`, `gray`, `black` — not a Bool; decode unknown future values as unknown rather than failing the
record. In the preview, `gray` and `black` count as adult, fail-closed, and with the switch off an
absent or unknown value counts as adult too. With the switch off and the preview's `nsfw` adult or
unknown, the preview does not offer the all-Source `Read on…` search; a resolved candidate's admitted
Listing still opens, because Source admission already passed it.

Two different vocabularies are in play and must not be mixed:

- `erotica` / `pornographic` are **Source content ratings** (`AdultContentFilter.adultRatings`,
  MangaDex-style). They apply to Listings — the resolved Listing and every Source search result — through
  `admitsForDiscovery`.
- MAL's adult **genre** names are `Hentai` and `Erotica`. They are available only on a top-level detail,
  so they apply only in the preview, as a second adult signal beside `nsfw`: either genre, with the
  switch off, has the same effect as an adult `nsfw` value. They are never applied to nested nodes,
  which carry no genres.

MAL requests are the same public detail calls already made today, plus one per tapped preview, all
cached as the Related design defines. Source searches beyond the existing reverse resolution carry the
MAL title only after an explicit tap. The choice store contains no credentials or reading history. Do
not log MAL ids alongside Source search URLs or challenge content beyond existing diagnostics.

### 7. What this does to reverse-resolution measurement

Do not re-measure or build the separate "reverse resolution beyond MangaDex" protocol for this feature.
That protocol answered whether automatic fallback could justify its per-open scrape cost; it found only
10 possible extra cards beyond MangaDex's 90/100, and explicitly did not reject matcher precision.
Resolve-on-tap avoids both problems: it searches only cards a reader wants to open, and the reader
confirms fuzzy candidates rather than forcing a pre-measured automatic choice. A future automatic
background resolver would need a new owner-approved protocol; this design does not create one.

## Persistence and graph changes

1. Extend the `MALDetailStore` DTO from Related PR 1 with an optional `nsfw` string enum (and
   `mangaDetail`'s fields with `nsfw`). It decodes optional, so existing cache entries still load.
   Expose one cached candidate projection for both detail rails.
2. Replace the detail page's More Like This and Related "resolved Manga only" presentation values with
   MAL-native candidates while retaining the existing ordering, self/duplicate filtering, render-time
   external-id reverse resolution, and cache lifecycle. `SimilarTitlesProviding` and the home rail's
   `MALCandidateProvider` are untouched.
3. Add an injected `MALSourceChoiceStore` in `AppComposition`; do not use a singleton from views or
   view models. New service files under `MangaCarta/Services/` are synchronized and need no project edit.
4. Add a tap-resolution coordinator that receives `SourceRegistry`, `MALDetailStore`, the candidate,
   matcher, clock, and Source-search seams. It returns grouped exact/fuzzy choices and typed per-Source
   failures.
5. If a new preview/coordinator view or test file is added under `Views/` or `MangaCartaTests/`, those
   folders are plain Xcode groups: use `xcp add-file ... --targets MangaCarta` or
   `--targets MangaCartaTests` so the four project entries are created. Adding tests to the existing
   `MangaCartaTests.swift` avoids a project edit.

## Error and edge cases

- No MAL id after forward resolution: hide both rails, as today; do not query AniList or Sources.
- MAL detail missing/empty/null relations or recommendations: hide only the corresponding rail; a valid
  empty payload replaces stale cards after a successful refresh.
- Switch off and every candidate unresolved: the rail is hidden, exactly as a rail of all-dropped
  results is today.
- MAL title has no cover: use the existing screentone placeholder. The preview's tap-time fetch has no
  synopsis: a concise "No synopsis available" label. The tap-time fetch fails: keep cover and title,
  show `Details unavailable`, and search with whatever spellings are available.
- A cached detail written before `nsfw` was requested: decodes with `nsfw` absent, which the preview
  treats as unknown (adult, with the switch off) until the entry refreshes.
- A Source returns zero results, malformed results, rate limit, timeout, navigation failure, or
  Cloudflare decline: keep other Source groups; distinguish `Couldn't check` from `Not on your Sources`.
- Source disabled/uninstalled or hidden by adult gating between search and open: revalidate and return to
  the chooser; never route to another Source silently.
- Several exact matches: show Source choices, because exact identity does not establish the reader's
  preferred fulfillment Source.
- Several fuzzy matches within one Source: show all candidates only when they are within the matcher
  result window; label the group "Choose a match" and never preselect.
- A remembered choice whose title changed: show the stored title as historical context, re-search if the
  id is unavailable, and overwrite only after a new explicit confirmation.
- Cancellation: cancel child tasks, do not write a choice or negative result, and do not leave a loading
  announcement or challenge sheet attached to a dismissed preview.

## Accessibility and visual treatment

Use the existing Ink & Seal cover card, `MangaRail`, `InkSectionHeader`, semantic colors, and Dynamic
Type. Availability is a spoken/textual stamp, not cover tint. "Not on your Sources" is neutral metadata;
it must not sound like an error. Every MAL card has a 44-point action target and an accessibility label
including title, rail reason, and availability (for example, "Planetes, recommended by MyAnimeList,
not on your Sources").

The preview announces title and MAL source at once, then synopsis and genres when the tap-time fetch
returns (without stealing focus), and the `Read on…` action. The grouped chooser announces Source name,
title, match confidence ("exact match" or "possible match"), alternate titles, and chapter count/unknown.
Exact choices use a checkmark and words, never color alone. Challenge presentation retains the existing
VoiceOver-operable sheet and Cancel action. At large Dynamic Type, rows become taller and wrap metadata;
no title or confidence label is truncated.

## Acceptance criteria and named tests

1. **A cached MAL detail produces both MAL-native rails with one fetch** —
   `MALHubProjectionTests.testRelatedAndRecommendationsShareOneCachedDetailFetch`.
2. **Recommendation order, relation order/labels, self removal, and MAL-id de-duplication remain
   stable while unresolved candidates are retained (switch on)** —
   `MALHubProjectionTests.testNativeCandidatesKeepOrderAndRetainUnresolvedTitles`.
3. **A Work without a MAL id produces no MAL-native rail and performs no Source search** —
   `MALHubProjectionTests.testMissingMALIdentityHidesBothRails`.
4. **The preview shows the candidate's cached cover and title immediately, makes exactly one MAL detail
   fetch for the tapped id through `MALDetailStore` (none on a second open within 24 hours), and maps
   that fetch's synopsis, genres, alternative titles and `nsfw` into the preview** —
   `MALHubPreviewTests.testPreviewShowsCachedCoverThenLoadsTappedDetailOnce` and
   `testPreviewDetailFailureKeepsCoverAndTitle`.
5. **Exact external-id match wins and opens in one tap; exact matches from multiple Sources show a
   Source chooser** — `MALHubResolutionTests.testExactIdOpensDirectly` and
   `testMultipleExactSourcesRequireChoice`.
6. **Fuzzy matches use the 0.90 threshold and 0.05 ambiguity guard, but displayed fuzzy choices require
   confirmation** — `MALHubResolutionTests.testFuzzyChoicesRequireReaderConfirmation` and
   `testAmbiguousChoicesAreShownWithoutPreselection`.
7. **All admitted browsable non-Local Sources are searched with at most three spellings taken from the
   tap-time detail (not the nested node), with at most four searches in flight** —
   `MALHubResolutionTests.testSearchesEveryAdmittedSourceWithBoundedConcurrency` and
   `testSearchSpellingsComeFromTappedDetailNotNestedNode`.
8. **A Source timeout, rate limit, or challenge decline does not suppress other Source results and is
   not recorded as a negative cache miss** — `MALHubResolutionTests.testSourceFailureIsPerSourceAndTransient`.
9. **Cloudflare interaction can be surfaced after a tap, a search with its challenge sheet up is not
   cut off by the eight-second deadline, and cancellation leaves no pending work** —
   `MALHubResolutionTests.testChallengeSuspendsOrchestrationDeadline` and hermetic
   `MALHubResolutionUITests.testTapMayPresentChallengeAndCancelReturnsToPreview`.
10. **A confirmed choice is persisted, reopened directly while valid, and invalidated when its Source
    or listing disappears** — `MALSourceChoiceStoreTests.testConfirmedChoiceSurvivesReload` and
    `MALHubResolutionTests.testMissingRememberedChoiceFallsBackToChooser`.
11. **Adult option B: with the switch off, an unresolved adult-unknown card is not rendered, and a
    resolved card renders only if `admitsForDiscovery` admits its Listing; with the switch on,
    unresolved cards render and Source admission and the declared-age gate still apply. In the preview,
    `nsfw` `gray`/`black`, an absent `nsfw` (switch off), or a `Hentai`/`Erotica` genre withholds the
    all-Source search** — `MALHubAdultTests.testSwitchOffHidesUnresolvedCards`,
    `testSwitchOffKeepsOnlyAdmittedResolvedCards`, `testSwitchOnShowsUnresolvedCardsUnderSourceAdmission`,
    and `testPreviewNSFWFailsClosed`.
12. **Rendering does not contact any Source beyond the existing external-id reverse resolution; the
    all-Source search waits for `Read on…`; MAL calls remain cache-bounded** —
    `MALHubPrivacyTests.testRenderingContactsOnlyTheExistingReverseResolver` and
    `MALDetailStoreTests.testFreshEntryAvoidsFetchWithin24Hours`.
13. **The detail UI mixes resolved and unresolved cards, exposes truthful VoiceOver labels, and shows
    the honest empty state** — hermetic `MALHubUITests.testUnavailableCardIsLabeledWithoutSources` and
    `testNotOnYourSourcesStateOffersRepositoryHint`.
14. **The home For You rail is unchanged: `SimilarTitlesProviding.recommendations(for:limit:)` still
    returns resolved Listings only, never an unresolved MAL candidate** —
    `MALCandidateProviderTests.testHomeRailReceivesResolvedListingsOnly`.
15. **A `MALDetailStore` record cached before `nsfw` existed still decodes, with `nsfw` absent** —
    `MALDetailStoreTests.testRecordWithoutNSFWStillDecodes`.
16. **All new tests use the iPhone 17 Pro destination and Swift 6.0-compatible ordinary actors/tasks;
    no isolated conformances, `nonisolated(nonsending)`, `@concurrent`, or `Task.immediate`.**

## Implementation slices

1. **Slice 1 — shared cached MAL projection:** on top of Related PR 1's `MALDetailStore`, add optional
   `nsfw` (decoded optional, so old cache entries still load), and pure Related/More Like This
   MAL-native candidate projections as a detail-page API beside `SimilarTitlesProviding`. Existing rails
   can remain temporarily resolved-only behind the new model; unit tests prove ordering, cache sharing,
   old-record decoding, and that the home rail's protocol is unchanged.
2. **Slice 2 — tap resolver and durable choice:** add the preview's tapped-id detail fetch, the injected
   coordinator, per-Source bounded searches, matcher confidence model, challenge/error states, and
   `MALSourceChoiceStore`. Unit tests prove exact/fuzzy/ambiguous behavior, spellings from the tapped
   detail, and the challenge deadline exemption without UI.
3. **Slice 3 — preview, mixed rails, and accessibility:** change the detail UI to render MAL candidates
   under option B, add preview/chooser/empty states, and add hermetic UI coverage. Each slice is
   independently mergeable and no background reverse-resolution migration is required.

## Open questions for the owner

1. **Decided 2026-11-10 — option B.** With "Show adult content" off, only cards the existing
   external-id reverse resolver resolved to an admitted Listing are shown; unresolved cards appear only
   with the switch on, under Source admission and the declared-age gate; no per-card MAL adult fetches.
   Still open, and small: in the preview, should MAL's adult genres be exactly `Hentai` and `Erotica`,
   or a broader centrally-owned list?
2. **Recommended:** show one MAL-native mixed rail per section, with a quiet `NOT ON YOUR SOURCES`
   stamp and no disabled treatment. Owner: should unavailable cards be visually dimmed slightly, or use
   the same card treatment as available cards for a calmer rail?
3. **Recommended:** remember a confirmed `(MAL id, Source id, listing id)` indefinitely but expose
   "Choose another Source" in the preview menu. Owner: should Settings also expose a list/clear control
   for remembered choices, or is the per-preview control sufficient?
4. **Recommended:** fetch chapter counts only for the top three displayed choices and label missing data
   "Chapter count unknown." Owner: is that small enrichment worth the extra Source calls, or should the
   chooser omit chapter counts entirely for the first PR?
5. **Recommended:** keep MAL as the only rail provider and hide rails without a MAL id. Owner: should a
   future AniList fallback be tracked as a separate proposal, rather than weakening this MAL-hub scope?
