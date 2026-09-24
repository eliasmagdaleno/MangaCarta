//
//  MALReverseResolverTests.swift
//  MangaCartaTests
//
//  The cache-write discipline `MALReverseResolver` exists to keep single. Until the
//  extraction these lines lived as a private method on `MoreLikeThisProvider` calling
//  `MangaDexAPI` statics, so none of it was reachable without a network — the ADR-0011
//  claim that "the golden proves the extraction moved nothing" was false, because every
//  existing test stubs `resolve` and injects *past* this code entirely.
//
//  The load-bearing case is `search THREW → record nothing`. Its failure mode is silent:
//  a transient network error recorded as `.unresolved` poisons the store against that
//  title for the full 14-day miss TTL, and nothing in the UI would ever say so.
//

import XCTest
@testable import MangaCarta

@MainActor
final class MALReverseResolverTests: XCTestCase {

    func testNoRegisteredExternalIdSourceDegradesToEmpty() async {
        let defaults = UserDefaults(suiteName: "test.reverse.unavailable.\(UUID().uuidString)")!
        var registered: MangaSource?
        let resolver = MALReverseResolver(
            store: EntityResolutionStore(defaults: defaults),
            source: { registered })
        let out = await resolver.resolve([.init(malId: 55, title: "Unavailable")])
        XCTAssertTrue(out.isEmpty)
        XCTAssertNil(EntityResolutionStore(defaults: defaults).reverseResolution(malId: 55))

        registered = StubSource(results: [manga("md-1", title: "Unavailable", malId: 55)])
        let recovered = await resolver.resolve([.init(malId: 55, title: "Unavailable")])
        XCTAssertEqual(recovered[55]?.id, "md-1")
    }

    // MARK: - Fixtures

    private func store() -> EntityResolutionStore {
        EntityResolutionStore(
            defaults: UserDefaults(suiteName: "test.reverse.\(UUID().uuidString)")!)
    }

    // MARK: - Cache-write discipline

    /// A candidate carrying the target `malId` is a confirmed match — the strong arm of
    /// `MoreLikeThis.pickMatch`, no title similarity required.
    func testConfidentMatchIsReturnedAndRecordedResolved() async {
        let store = store()
        let hit = manga("md-1", title: "Something Else Entirely", malId: 55)
        let resolver = MALReverseResolver(store: store,
                                          search: { _ in [hit] },
                                          fetchByIds: { _ in [] })

        let out = await resolver.resolve([.init(malId: 55, title: "Crimson Vow")])

        XCTAssertEqual(out[55]?.id, "md-1")
        XCTAssertEqual(store.reverseResolution(malId: 55), .resolved(mangaDexId: "md-1"))
    }

    /// The search completed and simply found nothing confident. That IS information —
    /// record it, so the next rail build doesn't pay for the same search.
    func testSearchedWithNoMatchRecordsUnresolved() async {
        let store = store()
        let miss = manga("md-9", title: "Totally Unrelated Title", malId: 999)
        let resolver = MALReverseResolver(store: store,
                                          search: { _ in [miss] },
                                          fetchByIds: { _ in [] })

        let out = await resolver.resolve([.init(malId: 55, title: "Crimson Vow")])

        XCTAssertTrue(out.isEmpty)
        guard case .unresolved = store.reverseResolution(malId: 55) else {
            return XCTFail("expected an .unresolved record, got \(String(describing: store.reverseResolution(malId: 55)))")
        }
    }

    /// The one that matters. A thrown search carries no information about the title, so
    /// writing `.unresolved` would poison the cache for 14 days over a dropped connection.
    func testThrownSearchRecordsNothing() async {
        let store = store()
        let resolver = MALReverseResolver(store: store,
                                          search: { _ in throw SearchFailed() },
                                          fetchByIds: { _ in [] })

        let out = await resolver.resolve([.init(malId: 55, title: "Crimson Vow")])

        XCTAssertTrue(out.isEmpty)
        XCTAssertNil(store.reverseResolution(malId: 55),
                     "a transient failure must leave the cache untouched")
    }

    /// One target throwing must not suppress the others — the task group's results are
    /// independent, and a partial pool is the normal outcome.
    func testOneThrownSearchDoesNotAffectItsSiblings() async {
        let store = store()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                if title == "Bad" { throw SearchFailed() }
                return [manga("md-ok", title: title, malId: 1)]
            },
            fetchByIds: { _ in [] })

        let out = await resolver.resolve([.init(malId: 2, title: "Bad"),
                                          .init(malId: 1, title: "Good")])

        XCTAssertEqual(out[1]?.id, "md-ok")
        XCTAssertNil(out[2])
        XCTAssertNil(store.reverseResolution(malId: 2))
    }

    // MARK: - Cache partition

    /// A fresh `.resolved` hit skips the search entirely and is filled in by ONE batch
    /// fetch — the whole reason the partition exists.
    func testFreshResolvedHitSkipsSearchAndIsBatchFetched() async {
        let store = store()
        store.recordReverse(malId: 55, .resolved(mangaDexId: "md-1"))
        let searches = Counter()
        let fetches = Counter()
        let resolver = MALReverseResolver(
            store: store,
            search: { _ in await searches.increment(); return [] },
            fetchByIds: { ids in
                await fetches.increment()
                return ids.map { manga($0, title: "Cached \($0)") }
            })

        let out = await resolver.resolve([.init(malId: 55, title: "Crimson Vow")])

        XCTAssertEqual(out[55]?.id, "md-1")
        let (searchCount, fetchCount) = (await searches.value, await fetches.value)
        XCTAssertEqual(searchCount, 0, "a fresh hit must not re-search")
        XCTAssertEqual(fetchCount, 1, "cache hits are filled by a single batch fetch")
    }

    /// A fresh `.unresolved` miss is skipped outright — neither re-searched nor fetched.
    /// It is re-attempted only once past the 14-day TTL.
    func testFreshUnresolvedMissIsSkippedEntirely() async {
        let store = store()
        store.recordReverse(malId: 55, .unresolved(checkedAt: Date()))
        let searches = Counter()
        let fetches = Counter()
        let resolver = MALReverseResolver(
            store: store,
            search: { _ in await searches.increment(); return [] },
            fetchByIds: { _ in await fetches.increment(); return [] })

        let out = await resolver.resolve([.init(malId: 55, title: "Crimson Vow")])

        XCTAssertTrue(out.isEmpty)
        let (searchCount, fetchCount) = (await searches.value, await fetches.value)
        XCTAssertEqual(searchCount, 0)
        XCTAssertEqual(fetchCount, 0)
    }

    /// A *stale* `.unresolved` miss is re-attempted — that is what the TTL buys, and what
    /// makes an improved matcher (or a title MangaDex adds later) eventually take effect.
    func testStaleUnresolvedMissIsResearched() async {
        let store = store()
        let old = Date().addingTimeInterval(-(EntityResolutionStore.missTTL + 60))
        store.recordReverse(malId: 55, .unresolved(checkedAt: old))
        let resolver = MALReverseResolver(
            store: store,
            search: { _ in [manga("md-1", title: "Whatever", malId: 55)] },
            fetchByIds: { _ in [] })

        let out = await resolver.resolve([.init(malId: 55, title: "Crimson Vow")])

        XCTAssertEqual(out[55]?.id, "md-1")
        XCTAssertEqual(store.reverseResolution(malId: 55), .resolved(mangaDexId: "md-1"))
    }

    /// A failed batch fetch degrades to fewer entries rather than throwing — the cache
    /// record stays `.resolved`, so the next build tries the fetch again.
    func testFailedBatchFetchDegradesWithoutClearingTheCache() async {
        let store = store()
        store.recordReverse(malId: 55, .resolved(mangaDexId: "md-1"))
        let resolver = MALReverseResolver(store: store,
                                          search: { _ in [] },
                                          fetchByIds: { _ in throw SearchFailed() })

        let out = await resolver.resolve([.init(malId: 55, title: "Crimson Vow")])

        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(store.reverseResolution(malId: 55), .resolved(mangaDexId: "md-1"))
    }

    // MARK: - ADR-0020: widening the search input

    /// The lever ADR-0020 measured. The primary spelling misses; a second spelling
    /// surfaces a MangaDex entry publishing the target `malId`, and the row recovers.
    /// This is the *Mugen no Juunin* → "Blade of the Immortal" case, 41 of the MAL arm's
    /// 45 recoveries.
    func testSecondSpellingRecoversARowTheFirstSpellingMissed() async {
        let store = store()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                title == "Blade of the Immortal"
                    ? [manga("md-1", title: "Blade of the Immortal", malId: 55)]
                    : []
            },
            fetchByIds: { _ in [] })

        let out = await resolver.resolve(
            [.init(malId: 55, titles: ["Mugen no Juunin", "Blade of the Immortal"])])

        XCTAssertEqual(out[55]?.id, "md-1")
        XCTAssertEqual(store.reverseResolution(malId: 55), .resolved(mangaDexId: "md-1"))
    }

    /// **ADR-0020 Decision 4.** A candidate surfaced by a *widened* query resolves the row
    /// only by publishing the target `malId`. Here the second spelling returns a perfect
    /// title twin carrying no id — the shape of the run's single false recovery — and it
    /// must be refused.
    ///
    /// The fuzzy arm is not disabled: it ran on the baseline pool and found nothing. It
    /// simply never sees the widened candidates.
    func testWidenedCandidatesResolveOnlyByAnExactMalId() async {
        let store = store()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                title == "Kyoukaisenjou no Horizon"
                    ? []
                    : [manga("md-wrong", title: "Kyoukaisenjou no Horizon", malId: 37783)]
            },
            fetchByIds: { _ in [] },
            fetchTitles: { _ in [] })

        let out = await resolver.resolve(
            [.init(malId: 24464, titles: ["Kyoukaisenjou no Horizon", "境界線上のホライゾン"])])

        XCTAssertTrue(out.isEmpty,
                      "a widened candidate matching only by title must not be picked")
        guard case .unresolved = store.reverseResolution(malId: 24464) else {
            return XCTFail("the row was searched and refused, so the miss is cacheable")
        }
    }

    /// **ADR-0020 Decision 1.** Three spellings, baseline included — the measured setting.
    /// Queries 4 and 5 recovered 5 cards out of 84 across the whole run and are not paid for.
    func testAtMostThreeSearchesArePaidPerTarget() async {
        let store = store()
        let searched = Box()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                await searched.append(title)
                return []
            },
            fetchByIds: { _ in [] },
            fetchTitles: { _ in [] })

        _ = await resolver.resolve(
            [.init(malId: 55, titles: ["One", "Two", "Three", "Four", "Five"])])

        let titles = await searched.value
        XCTAssertEqual(titles, ["One", "Two", "Three"])
    }

    /// The widening is paid by rows that missed, not by every row — the difference between
    /// ~0.2 extra requests per row and one per row.
    func testResolvedBaselineIssuesNoSecondSearch() async {
        let store = store()
        let searched = Box()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                await searched.append(title)
                return [manga("md-1", title: "Whatever", malId: 55)]
            },
            fetchByIds: { _ in [] },
            fetchTitles: { _ in [] })

        _ = await resolver.resolve([.init(malId: 55, titles: ["One", "Two", "Three"])])

        let titles = await searched.value
        XCTAssertEqual(titles, ["One"])
    }

    // MARK: - ADR-0020: the MAL arm's extra request

    /// The asymmetry ADR-0020 records and the measurement's cost column did not: MAL does
    /// not apply top-level `fields` to nested `recommendations` nodes, so a MAL-arm target
    /// arrives with one spelling and no way to widen without asking. One `mangaDetail` per
    /// row that missed — the request the harness prefetched and never billed.
    func testSingleSpellingTargetFetchesAlternativeTitlesAfterTheBaselineMisses() async {
        let store = store()
        let fetches = Counter()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                title == "Sensual Phrase"
                    ? [manga("md-1", title: "Sensual Phrase", malId: 55)]
                    : []
            },
            fetchByIds: { _ in [] },
            fetchTitles: { malId in
                await fetches.increment()
                XCTAssertEqual(malId, 55)
                return ["Kaikan Phrase", "Sensual Phrase"]
            })

        let out = await resolver.resolve([.init(malId: 55, title: "Kaikan Phrase")])

        XCTAssertEqual(out[55]?.id, "md-1")
        let fetchCount = await fetches.value
        XCTAssertEqual(fetchCount, 1)
    }

    /// The fetch is paid **only** by rows that missed. A row the baseline resolves costs
    /// exactly what it costs today — the reason the fan-out is ~0.2 extra requests per row
    /// overall rather than one per row.
    func testResolvedBaselineNeverFetchesAlternativeTitles() async {
        let store = store()
        let fetches = Counter()
        let resolver = MALReverseResolver(
            store: store,
            search: { _ in [manga("md-1", title: "Whatever", malId: 55)] },
            fetchByIds: { _ in [] },
            fetchTitles: { _ in await fetches.increment(); return ["A", "B"] })

        _ = await resolver.resolve([.init(malId: 55, title: "Kaikan Phrase")])

        let fetchCount = await fetches.value
        XCTAssertEqual(fetchCount, 0, "a resolved row must not pay the widening toll")
    }

    /// The AniList arm already holds its spellings, so it must never spend a request to
    /// discover them. This is what makes that arm free.
    func testTargetThatAlreadyCarriesSpellingsNeverFetches() async {
        let store = store()
        let fetches = Counter()
        let resolver = MALReverseResolver(
            store: store,
            search: { _ in [] },
            fetchByIds: { _ in [] },
            fetchTitles: { _ in await fetches.increment(); return [] })

        _ = await resolver.resolve([.init(malId: 55, titles: ["Romaji", "English"])])

        let fetchCount = await fetches.value
        XCTAssertEqual(fetchCount, 0)
    }

    /// A failed *title* fetch is not a failed search. The baseline search completed and
    /// genuinely found nothing, so the miss is real information and must still be cached —
    /// unlike a thrown search, which records nothing.
    func testThrownTitleFetchStillRecordsTheBaselineMiss() async {
        let store = store()
        let resolver = MALReverseResolver(
            store: store,
            search: { _ in [] },
            fetchByIds: { _ in [] },
            fetchTitles: { _ in throw SearchFailed() })

        let out = await resolver.resolve([.init(malId: 55, title: "Kaikan Phrase")])

        XCTAssertTrue(out.isEmpty)
        guard case .unresolved = store.reverseResolution(malId: 55) else {
            return XCTFail("a failed title fetch must not suppress the miss record")
        }
    }

    // MARK: - The AniList adapter

    /// ADR-0020 Decision 1 on the AniList arm, where it is free: `knownTitles` already
    /// carries romaji/english/native/synonyms from a request already made, and the shipped
    /// code threw all but the first away. Nothing is fetched to widen this arm.
    func testWorksAdapterSearchesEveryKnownTitleUpToTheLimit() async {
        let store = store()
        let searched = Box()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                await searched.append(title)
                return []
            },
            fetchByIds: { _ in [] })

        let work = AniListWork(anilistId: 1, malId: 11,
                               knownTitles: ["Romaji", "English", "Native", "Synonym"],
                               genres: [], tags: [],
                               publicationStatus: .releasing, chapterTotal: nil)
        _ = await resolver.resolve(works: [work], limit: 1)

        let titles = await searched.value
        XCTAssertEqual(titles, ["Romaji", "English", "Native"],
                       "three spellings searched, the fourth left unspent")
    }

    /// Which titles get searched is one decision in one place: Works past `limit`, and
    /// Works carrying no MAL id, never become targets.
    ///
    /// `fetchTitles` is stubbed to nothing rather than left defaulted. It has to be: these
    /// Works carry one `knownTitle` each, so ADR-0020's widening would otherwise reach the
    /// **real** MAL endpoint and this network-free test would assert against whatever
    /// spellings the live catalogue happens to hold.
    func testWorksAdapterHonoursLimitAndDropsWorksWithoutAMALId() async {
        let store = store()
        let searched = Box()
        let resolver = MALReverseResolver(
            store: store,
            search: { title in
                await searched.append(title)
                return []
            },
            fetchByIds: { _ in [] },
            fetchTitles: { _ in [] })

        let works = [aniList(1, malId: 11), aniList(2, malId: nil), aniList(3, malId: 33)]
        _ = await resolver.resolve(works: works, limit: 2)

        let titles = await searched.value
        XCTAssertEqual(titles, ["Title 1"],
                       "work 2 carries no malId and work 3 is past the limit")
    }

}

/// File-scope, not methods: these are called from inside `@Sendable` closures running on
/// the task group's child tasks, and `XCTestCase` here is `@MainActor`-isolated — a method
/// would capture `self` across the isolation boundary.
private func manga(_ id: String, title: String, malId: Int? = nil) -> Manga {
    Manga(id: id, sourceId: "mangadex", title: title, description: "",
          status: "ongoing", year: nil, coverURL: nil, malId: malId)
}

private func aniList(_ id: Int, malId: Int?) -> AniListWork {
    AniListWork(anilistId: id, malId: malId, knownTitles: ["Title \(id)"],
                genres: [], tags: [], publicationStatus: .releasing, chapterTotal: nil)
}

private struct StubSource: MangaSource {
    let id = "bridge"
    let name = "Bridge"
    let results: [Manga]

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { results }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

private struct SearchFailed: Error {}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Box {
    private(set) var value: [String] = []
    func append(_ new: String) { value.append(new) }
}
