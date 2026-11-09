# Related titles and MAL detail caching — Design

**Date:** 2026-11-09  
**Status:** Accepted owner decisions (2026-11-09) are recorded at the end.
**Scope:** the detail-page Related section and a read-through cache for the one MAL detail
payload consumed by both detail-page rails.

## Goal

When a manga has a MAL identity, the detail page should show the series relationships MAL
publishes — prequels, sequels, side stories, spin-offs, and the less common relationship
types — as openable installed-Source titles. The existing More Like This rail should keep its
current recommendation ordering and behavior, but repeated visits should reuse the MAL detail
payload rather than issuing one `/manga/{id}` request per visit.

This is worth doing now because the original YAGNI assumptions have expired. The shipped
More Like This path is now a permanent detail-page surface (and is also consumed by the
home collaborative candidate provider), while installed Sources and the MAL bridge make a
successful reverse resolution materially more valuable. `related_manga` is already decoded
and requested in the same request as `recommendations`, so the Related surface adds no MAL
request. Repeated detail appearances currently redo that same request despite the payload
being identical enough for a bounded freshness window; this is now visible request waste,
not speculative infrastructure.

## Non-goals

- No new MAL endpoint, authentication flow, user-list synchronization, or MAL write.
- No multi-source reverse resolution. Only the installed Source that publishes external ids
  (currently the installed MangaDex engine) participates, as required by ADR-0020 and the
  bridge decisions.
- No change to Work identity, Listing persistence, reverse-resolution confidence thresholds,
  source pins, or `RecommendationEngine` ranking.
- No provider snapshot cache for AniList, MAL search, or source chapter/detail data.
- No relation graph navigation, series timeline, editing of MAL relationships, or a tabbed
  detail-page redesign.

## Current code this builds on

These references were opened while drafting this document.

- `MangaCarta/Models/MyAnimeListAPI.swift:74-98` defines
  `MyAnimeListMangaDetail`, including `Relation` (`node`, `relationType`,
  `relationTypeFormatted`) and `Recommendation` (`node`, `numRecommendations`).
- Those declarations, including `MyAnimeListManga`, `MainPicture`, and the nested
  `Genre`/`Relation`/`Recommendation` value types, are `Decodable` only today. The cache
  slice must change every cached DTO to `Codable`; the cache's `JSONDecoder` must use the
  API decoder's `.convertFromSnakeCase` strategy (the API decoder is at
  `MyAnimeListAPI.swift:113-118`) and its `JSONEncoder` must use the corresponding
  `.convertToSnakeCase` strategy, so disk round-trips preserve the decoded model losslessly.
- `MangaCarta/Models/MyAnimeListAPI.swift:171-180` requests
  `alternative_titles,synopsis,main_picture,genres,related_manga,recommendations` in one
  `mangaDetail(id:)` call. There is therefore no additional MAL request for Related.
- `MangaCarta/Services/MoreLikeThisProvider.swift:16-61` is the current provider: it resolves
  a MAL id, calls `mangaDetail`, sorts recommendations by `numRecommendations`, asks the
  shared reverse resolver to resolve them, then removes self/duplicates while restoring MAL
  order.
- `MangaCarta/Services/MALReverseResolver.swift:36-104` owns reverse resolution, including
  injected search/fetch seams and a four-task sliding window; `:137-169` separates fresh
  cache hits from searches and batches source-id fetches; `:191-220` records a miss only
  after a search actually ran and records nothing for a thrown search.
- `MangaCarta/Models/MoreLikeThisViewModel.swift:12-42` is a main-actor, idempotent,
  per-manga loader. It filters results through the injected `SourceRegistry` before exposing
  them to the view.
- `MangaCarta/Views/MangaDetailView.swift:144-173` puts chapters before the More Like This
  section, loads it in a non-blocking `.task`, and shows an unmatched notice only when the
  rail is empty and the Work has a recorded refusal. `:556-564` defines the current rail using
  `InkSectionHeader("More Like This", eyebrow: "Similar titles")` and `MangaRail`.
- `MangaCarta/Views/Components/MangaRail.swift:11-37` supplies horizontal cover cards and
  opens `MangaDetailView` with the graph's injected registry.
- `MangaCarta/Services/EntityResolutionStore.swift:31-108` persists reverse outcomes in
  `UserDefaults`, with indefinitely fresh hits and a 14-day miss TTL. It is resolution
  evidence, not a payload cache, and must remain separate.
- `MangaCarta/Services/ListingCountCache.swift:16-87` is the closest cache pattern: a
  main-actor Codable entry, explicit TTL, `Caches/` storage, lazy load, atomic write, and
  silent cache failure. `MangaCarta/Services/AniListPoolStore.swift:22-121` additionally
  demonstrates an actor-owned disk cache and in-flight refresh deduplication.
- `MangaCarta/Services/AppComposition.swift:384-415` constructs More Like This providers
  for the recommender, and `:83-103` establishes the graph's injected registry and image
  cache conventions. The detail provider must be shared by the detail VM and candidate
  provider only where that improves payload reuse; source and registry injection stays intact.
- `MangaCartaTests/MangaCartaTests.swift:2628-2687` already proves that related and
  recommendation DTOs decode, including optional absence. `:3378-3434` covers exact/fuzzy
  reverse matching and recommendation ordering/capping.
- `docs/adr/0020-widening-the-search-input-on-the-reverse-resolution-path.md:81-98` fixes
  reverse search at three ordered spellings and a unioned candidate pool; its
  `:118-136` rejects cache-version churn for a one-off search change. The new cache must not
  weaken those rules. ADR-0019 remains the accepted bridge for installed Sources without a
  published MAL id; ADR-0018's authoritative-id rule still wins.

## Design decisions

### 1. One cached payload, two projections

Add a `MALDetailStore` read-through cache and make the MAL detail result the shared input to
both projections:

```swift
// All DTOs reachable from `MyAnimeListMangaDetail` are Codable in the cache slice:
// MyAnimeListManga, MainPicture, AlternativeTitles, Genre, Relation, and Recommendation.
struct MALDetailRecord: Codable, Equatable {
    let detail: MyAnimeListMangaDetail
    let fetchedAt: Date
}

actor MALDetailStore {
    static let ttl: TimeInterval = 24 * 60 * 60
    func freshDetail(for malID: Int, now: Date = Date()) -> MyAnimeListMangaDetail?
    func detail(for malID: Int,
                now: Date = Date(),
                fetch: @escaping (Int) async throws -> MyAnimeListMangaDetail)
                async -> MyAnimeListMangaDetail?
    func invalidate(malID: Int)
}
```

The actual implementation may use a value named `MALDetailCache`; the contract matters:
the store owns memory, disk, TTL, and in-flight coalescing, while the provider owns
resolution and presentation policy. `detail(for:fetch:)` returns a fresh entry immediately;
on a miss it shares one task among concurrent callers for the same MAL id, so a page rail
and another consumer cannot double-spend the request. The fetch closure calls
`MyAnimeListAPI.mangaDetail(id:)`; no API request code moves into the cache.

**Options considered:** memory-only is simplest but repeats the request on every cold launch;
disk-only avoids that but makes every access decode JSON and has no fast hot path; a
memory-plus-disk read-through cache is selected because this payload is small, disposable,
and already has the `Caches/` precedent. A 24-hour TTL matches `ListingCountCache` and is
long enough to avoid a detail-open request loop while allowing MAL's relationships and
recommendation weights to change. A shorter six-hour TTL would waste requests on the same
session; indefinite caching would make a changing recommendation rail silently permanent.

Store files belong under `Caches/MALDetail/mal-detail.json` (or an equivalent single file),
not Application Support: deleting it costs only time and the next successful fetch repairs
it. Keys are decimal MAL ids. Corrupt, undecodable, or future-incompatible data is a miss;
save failures are silent and do not fail the page. Writes are atomic. The store is injected
with a directory and clock-friendly `now` parameters in tests, and production owns one
instance in `AppComposition`.

### 2. Fresh, stale, and offline behavior

The normal path is read-through: a fresh entry serves both Related and More Like This with
zero MAL calls. An expired entry is not used while online; one fetch replaces it only after
the complete DTO decodes. A failed refresh never overwrites the prior record.

When the fetch fails and an expired record exists, serve that stale record as a best-effort
offline result, marked internally as stale so the view does not present it as freshly synced.
This is appropriate because Related relationships and MAL recommendation candidates are
discovery data, not reading state. When no record exists, or when the record is malformed,
show neither section and do not invent an error for the detail page; the existing provider
already degrades network failure to fewer/zero cards. A later appearance retries. Cancellation
must propagate and must not write a partial record or a negative cache entry.

An explicit retry/invalidation hook is not added to the detail UI in this slice. The cache is
invalidated by TTL, decode failure, or a future owner-approved Settings action. A successful
fresh fetch replaces the full record, including an empty `related_manga` or
`recommendations` array (an empty array is valid provider data, not a reason to retain old
cards).

### 3. Related model and reverse resolution

Add a presentation value that retains the relationship label while reusing the established
reverse resolver:

```swift
struct RelatedTitle: Identifiable, Equatable {
    let id: String                 // resolved Listing id
    let manga: Manga
    let relationType: String       // canonical MAL value
    let relationLabel: String      // MAL's relation_type_formatted, normalized
}
```

The provider maps each `Relation` to the existing reverse target initializer
`.init(malId: node.id, title: node.title)` (the current call site is
`MoreLikeThisProvider.swift:46-47`),
calls `MALReverseResolver.resolve`, and then joins the returned Manga by MAL id. It must not
write Works or links merely because a card resolved; this remains discovery and uses the
existing precision-biased resolver. A relation with no confident MangaDex/installed-Source
match is omitted. A thrown source search records no reverse miss, exactly as
`MALReverseResolver.swift:211-218` requires. Self, duplicate Listing ids, non-admitted
Sources, and disabled/uninstalled Sources are omitted. The stable id is the resolved Listing
id plus relation type, so one Listing cannot accidentally collapse two meaningful labels;
the UI should still de-duplicate a repeated MAL target and keep its first relation.

No relation-specific MAL request is made. The same cached detail record feeds Related and
More Like This, including a single provider invocation from the detail view. The home
`MALCandidateProvider` may use the same cache independently; it must not force Related work
or affect the detail VM's lifecycle.

### 4. Relation labels and order

MAL's `relation_type` is the machine value and `relation_type_formatted` is the display value.
Normalize known labels to sentence case so malformed/changed server capitalization cannot
change the visual rhythm, while preserving an unknown value as a readable title-cased label.
Use this mapping:

| MAL value | Label |
|---|---|
| `prequel` | Prequel |
| `sequel` | Sequel |
| `side_story` | Side story |
| `spin_off` | Spin-off |
| `alternative_version` | Alternative version |
| `alternative_setting` | Alternative setting |
| `full_story` | Full story |
| `summary` | Summary |
| `parent_story` | Parent story |
| `serialization` | Serialization |
| `other` | Other |

Order is semantic and deterministic: **Prequel, Sequel, Side story, Spin-off, Alternative
version, Alternative setting, Full story, Summary, Parent story, Serialization, Other**;
within each group preserve MAL's array order. Unknown values sort after `Other`, retaining
their original array order. This keeps the common “where next?” choices first, does not
pretend MAL provides a chronology, and makes tests independent of dictionary ordering.
Each card carries its relation label as a visible metadata stamp and in its accessibility
label (for example, “Berserk: The Prototype, Prequel”).

### 5. Detail view and empty state

Extend the detail view model (or its existing provider-facing child VM) with `relatedTitles`
and `isLoadingRelated`, loaded by the existing detail `.task`. The provider returns a result
containing both projections so the detail page does not resolve the MAL id or fetch the
payload twice. Keep the existing More Like This `items` API for the home candidate provider;
add a focused `relatedTitles(for:)` projection or a combined `DetailDiscovery` value rather
than making `RelatedTitle` leak into `MALCandidateProvider`.

Place **Related before the existing More Like This rail** at the bottom of the page, with a
shared horizontal `MangaRail`-like component that accepts an item label. Header: **“Related”** with
eyebrow **“From the same series”**. The section is hidden when no relation resolves. It must
not show an empty bordered panel, a spinner after loading, or the “unmatched” notice; an
unresolved relation is an omission, not an error. A title with no `related_manga`, no MAL id,
or no installed external-id Source therefore has no Related section and the detail page
remains otherwise unchanged.

**Options considered:** one mixed rail loses the distinction between continuation and
collaborative similarity; a tab/segmented control adds navigation and was explicitly deferred
by the original spec; two bottom sections are selected, with Related first, because this
prioritizes series continuity while communicating the distinction with one glance and
reusing the shipped detail layout.

## Persistence and graph changes

1. Add `MALDetailStore` under `MangaCarta/Services/`, with `Caches/` persistence and injected
   directory/clock seams. Add it as one `let malDetailStore` in `AppComposition`, constructed
   once and injected into detail and recommendation providers. The store does not share or
   replace `EntityResolutionStore`.
2. Refactor `MoreLikeThisProvider`'s direct `MyAnimeListAPI.mangaDetail` call at
   `MangaCarta/Services/MoreLikeThisProvider.swift:41-43` behind the store. Add the Related
   projection and relation ordering as pure helpers where possible.
3. Keep `MALReverseResolver` as the sole reverse-resolution implementation. Extend its input
   or add a small pure join helper; do not create a second search/cache discipline for
   relations.
4. Add tests in `MangaCartaTests/` for the new store and pure relation helpers. Because
   `MangaCartaTests/` is a plain Xcode group, every new test file needs `xcp add-file` (four
   project entries); a test added to the existing `MangaCartaTests.swift` needs no project
   edit. New service files in `MangaCarta/Services/` are synchronized and need no
   `project.pbxproj` edit. If a new view/component file is chosen under `Views/`, it needs
   the same four project entries because `Views/` is not synchronized.

## Error, privacy, and edge cases

- MAL `related_manga` can be absent, null, empty, duplicated, or contain an unknown relation
  type; all decode safely, and unknown types are shown after known groups.
- A relation node can have a title but no usable installed Source match; omit only that card.
  A failed search is transient and must not become a 14-day negative reverse-cache record.
- If MAL is rate-limited, offline, missing its client id, or returns malformed JSON, use the
  stale record if present; otherwise keep both rails hidden. Never surface raw request or
  cache errors as a detail-page failure.
- If the source is disabled/uninstalled between cache read and card presentation, registry
  admission filters it out. Existing Listings, pins, and history remain untouched.
- A cache entry contains provider metadata already requested by the app, not credentials,
  reading history, or user account data. It is disposable and may be deleted by the OS.
- Do not cache authenticated MAL list status or mix the public detail cache with
  `MALAuthenticatedClient` data.
- Sorting ties are stable: use original MAL array index as the final tiebreaker, both for
  recommendation weight ties and relation groups.

## Accessibility and visual treatment

Use `InkSectionHeader` and existing Ink & Seal spacing, typography, colors, and hairlines;
do not introduce a new accent for relation categories. The relation stamp is supplementary
metadata, never the only distinction. Every card is a native `NavigationLink` with a minimum
44-point target, a spoken title plus relation label, and no reliance on cover color. The
horizontal rail remains VoiceOver-scrollable; Dynamic Type may wrap the stamp/title rather
than truncating the relation label. At accessibility sizes, preserve the section order and
header hierarchy. Hidden empty sections must not leave an accessibility heading or loading
announcement behind.

## Acceptance criteria and named tests

1. **A real decoded MAL detail fixture round-trips through the disk cache** — decode the
   representative JSON fixture with the API's snake-case decoder, persist it, reload it in a
   fresh store, and compare the complete value including relations and recommendations in
   `MALDetailStoreTests.testRealDecodedFixtureRoundTripsAcrossInstances`.
2. **Fresh detail is served without invoking the fetch closure** —
   `MALDetailStoreTests.testFreshEntryAvoidsFetchWithin24Hours`.
3. **Expired detail fetches once and concurrent callers coalesce** —
   `MALDetailStoreTests.testExpiredEntryCoalescesConcurrentFetches`.
4. **A failed refresh preserves stale data for offline rendering and does not rewrite its
   timestamp** — `MALDetailStoreTests.testFailedRefreshReturnsStaleRecord`.
5. **Corrupt cache data is treated as a miss and repaired by the next successful fetch** —
   `MALDetailStoreTests.testCorruptEntryIsIgnored`.
6. **`related_manga` decodes all representative relation types and missing/empty values** —
   `MangaCartaTests.testMyAnimeListMangaDetailDecodesRelationsAndMissingRelations`.
7. **Relation ordering is stable and preserves MAL order within groups** —
   `RelatedTitlesTests.testRelationsUseSemanticOrderAndStableTieBreak`.
8. **Unknown relation types remain visible after known types with a readable label** —
   `RelatedTitlesTests.testUnknownRelationIsLabeledAndSortedLast`.
9. **Exact MAL id resolution wins, fuzzy matching remains precision-biased, and failed
   searches write no miss** — existing `testPickMatchPrefersExactMalIdOverCloserTitle`,
   `testPickMatchReturnsNilWhenAmbiguousOrBelowThreshold`, plus
   `MALReverseResolverTests.testThrownSearchDoesNotRecordReverseMiss`.
10. **Resolved relations are joined in semantic order, self/duplicates/unadmitted Sources
    are omitted, and the original relation label survives** —
    `RelatedTitlesTests.testProjectionFiltersAndPreservesRelationLabels`.
11. **The detail page renders Related before More Like This, hides Related when no relation
    resolves, and exposes each card's title and relation to VoiceOver** — hermetic UI test
    `MangaDetailRelatedUITests.testRelatedSectionIsAbsentWhenNoRelationResolves` and
    `testRelatedCardAnnouncesRelationAndPrecedesMoreLikeThis`.
12. **The existing More Like This rail keeps recommendation-weight ordering and uses the same
    cached payload** — `MangaCartaTests.testMoreLikeThisAndRelatedShareOneDetailFetch`.
13. **All new tests pass under the iPhone 17 Pro destination and Swift 6.0-compatible APIs**;
    the implementation uses ordinary actors/tasks and does not require isolated
    conformances, `nonisolated(nonsending)`, `@concurrent`, or `Task.immediate`.

## Implementation slices

This is intentionally **three PRs in order**, each mergeable on its own:

1. **PR 1 — cache seam:** add the Codable record/store, graph injection, fetch coalescing, and unit
   tests; refactor More Like This to use it. This slice is useful independently because it
   removes duplicate MAL calls without changing UI.
2. **PR 2 — Related projection:** add pure relation ordering/join logic and resolver
   integration, with unit tests. The UI can remain hidden until the projection is proven.
3. **PR 3 — Detail UI and accessibility:** add the Related rail, labels, empty-state behavior,
   and hermetic UI coverage. No slice depends on an unmerged later slice.

## Owner decisions (2026-11-09)

1. Keep the 24-hour TTL and stale-if-offline fallback. An expired cached payload may render
   when refresh fails because it is harmless discovery data and preserves useful offline
   navigation.
2. Show Related as the first of the two bottom rails, before More Like This, to prioritize
   series continuity while retaining More Like This as the established companion surface.
3. Use MAL's supplied `relation_type_formatted` only after normalizing it through the fixed
   mapping above. Unknown future relation values are shown with their readable title-cased
   label and sorted after `Other`; they are not hidden until explicitly mapped.
4. Keep the cache in `Caches/` and do not expose a “Clear MAL cache” control in this PR. The
   cache contains no credentials or personal data and the OS may evict it at any time.
