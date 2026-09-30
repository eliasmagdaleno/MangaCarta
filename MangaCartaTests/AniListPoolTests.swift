//
//  AniListPoolTests.swift
//  MangaCartaTests
//
//  Slice 3 of ADR-0011: the pool's core, its cache, and the provider shell.
//
//  Every policy the ADR argues for has a deterministic test here, which is the whole
//  reason the provider takes an injected `Query` and `Resolve` rather than calling
//  `MangaDexAPI` statics the way `MoreLikeThisProvider` does: a `Resolve` returning short
//  exercises the no-floor rule, one returning nothing exercises the 24-hour empty TTL, and
//  a `Query` throwing on the third pair exercises the all-or-nothing abort.
//

import XCTest
@testable import MangaCarta

final class AniListPoolTests: XCTestCase {

    // MARK: - Fixtures

    private static let vocabulary = TagVocabulary(
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
        entries: [
            TagVocabularyEntry(name: "Dungeon", category: "Theme-Fantasy",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Revenge", category: "Theme-Drama",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Magic", category: "Theme-Fantasy",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Reincarnation", category: "Theme-Fantasy",
                               isGeneralSpoiler: true, isAdult: false),
            TagVocabularyEntry(name: "Time Skip", category: "Theme-Other",
                               isGeneralSpoiler: true, isAdult: false)
        ])

    private func aniList(_ id: Int, malId: Int?, _ tags: [(String, Int)]) -> AniListWork {
        AniListWork(anilistId: id,
                    malId: malId,
                    knownTitles: ["Title \(id)"],
                    genres: [],
                    tags: tags.map { RankedTag(name: $0.0, rank: $0.1) },
                    publicationStatus: .finished,
                    chapterTotal: nil)
    }

    private func manga(_ id: String, malId: Int? = nil) -> Manga {
        Manga(id: id, sourceId: "mangadex", title: "Title \(id)", description: "",
              status: "completed", year: nil, coverURL: nil, malId: malId)
    }

    private func seeded(_ a: String, _ b: String, weight: Double,
                        works: Set<WorkID> = [WorkID()]) -> SeededTagPair {
        SeededTagPair(pair: TagPair(a, b), weight: weight, contributingWorks: works)
    }

    private func makeDirectory() -> URL {
        makeTestDirectory("pool")
    }

    // MARK: - The pure core

    /// `withinPool` sums over the pairs that surfaced a title. This is the multi-signal
    /// overlap property both existing pools have, expressed on the ranked axis.
    func testACandidateSurfacedByTwoPairsSumsBothContributions() {
        let dungeonRevenge = seeded("Dungeon", "Revenge", weight: 2.0)
        let dungeonMagic = seeded("Dungeon", "Magic", weight: 1.0)
        let work = aniList(1, malId: 11, [("Dungeon", 90), ("Revenge", 80), ("Magic", 70)])

        let ranked = rankPoolCandidates(results: [(dungeonRevenge, [work]),
                                                  (dungeonMagic, [work])])

        XCTAssertEqual(ranked.count, 1, "de-duped by AniList id across pairs")
        XCTAssertEqual(ranked[0].contributions.count, 2)

        let weights = [dungeonRevenge.pair: 2.0, dungeonMagic.pair: 1.0]
        // 2.0 x min(90,80)/100 + 1.0 x min(90,70)/100 = 1.6 + 0.7
        XCTAssertEqual(withinPoolScore(ranked[0].contributions, weights: weights),
                       2.3, accuracy: 0.0001)
    }

    /// The candidate's *own* ranks set the multiplier — not the ranks of the Work that
    /// seeded the pair. This is the first candidate-side scoring in the system.
    func testTheMultiplierComesFromTheCandidatesOwnWeakerLeg() {
        let pair = seeded("Dungeon", "Revenge", weight: 1.0)
        let strong = aniList(1, malId: 11, [("Dungeon", 98), ("Revenge", 95)])
        let scraped = aniList(2, malId: 22, [("Dungeon", 61), ("Revenge", 60)])

        let ranked = rankPoolCandidates(results: [(pair, [strong, scraped])])

        XCTAssertEqual(ranked.map(\.work.anilistId), [1, 2],
                       "95 beats 60 on the weaker leg")
    }

    /// A title with no `idMal` has no path to an openable MangaDex listing — reverse
    /// resolution goes through the MAL id — so it must not occupy a resolution slot.
    func testCandidatesWithoutAMalIdAreDropped() {
        let pair = seeded("Dungeon", "Revenge", weight: 1.0)
        let ranked = rankPoolCandidates(results: [(pair, [aniList(1, malId: nil,
                                                                 [("Dungeon", 90),
                                                                  ("Revenge", 90)])])])
        XCTAssertEqual(ranked, [])
    }

    /// Absent is not zero. A response that does not carry one leg is no claim at all; a
    /// zero term would read as a scored-and-weak match.
    func testACandidateMissingALegContributesNothingForThatPair() {
        let pair = seeded("Dungeon", "Revenge", weight: 1.0)
        let ranked = rankPoolCandidates(results: [(pair, [aniList(1, malId: 11,
                                                                 [("Dungeon", 90)])])])
        XCTAssertEqual(ranked, [])
    }

    func testThePoolIsCappedAndOrderedTotally() {
        let pair = seeded("Dungeon", "Revenge", weight: 1.0)
        // All identical scores, so the cut runs straight through one tie block.
        let works = (1...50).map { aniList($0, malId: $0,
                                           [("Dungeon", 80), ("Revenge", 80)]) }
        let ranked = rankPoolCandidates(results: [(pair, works)], cap: 40)

        XCTAssertEqual(ranked.count, 40)
        XCTAssertEqual(ranked.map(\.work.anilistId), Array(1...40),
                       "ties break on AniList id, so the cut is not arbitrary between runs")
    }

    // MARK: - Reason strings

    func testTheReasonNamesThePairContributingTheLargestTerm() {
        let big = seeded("Dungeon", "Revenge", weight: 5.0)
        let small = seeded("Dungeon", "Magic", weight: 0.1)
        let contributions = [PairContribution(pair: big.pair, minimumRank: 60),
                             PairContribution(pair: small.pair, minimumRank: 99)]

        XCTAssertEqual(poolReason(for: contributions,
                                  weights: [big.pair: 5.0, small.pair: 0.1],
                                  vocabulary: Self.vocabulary),
                       "More Dungeon + Revenge",
                       "the pair that placed the title, not the one it matched best")
    }

    /// Spoiler suppression degrades the *text*; it never re-picks the pair. Falling
    /// through to a clean pair would print a weaker contribution than the one that
    /// actually placed the title.
    func testASpoilerLegIsDroppedFromTheTextNotFromTheChoice() {
        let winner = seeded("Magic", "Reincarnation", weight: 5.0)
        let clean = seeded("Dungeon", "Revenge", weight: 0.1)
        let contributions = [PairContribution(pair: winner.pair, minimumRank: 90),
                             PairContribution(pair: clean.pair, minimumRank: 90)]

        XCTAssertEqual(poolReason(for: contributions,
                                  weights: [winner.pair: 5.0, clean.pair: 0.1],
                                  vocabulary: Self.vocabulary),
                       "More Magic")
    }

    func testBothLegsSpoilingFallsBackToRecommended() {
        let pair = seeded("Reincarnation", "Time Skip", weight: 1.0)
        XCTAssertEqual(poolReason(for: [PairContribution(pair: pair.pair, minimumRank: 90)],
                                  weights: [pair.pair: 1.0],
                                  vocabulary: Self.vocabulary),
                       "Recommended")
    }

    // MARK: - The record's two TTLs

    func testAPopulatedPoolKeepsFourteenDaysAndAnEmptyOneKeepsTwentyFour() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let populated = AniListPoolRecord(
            seeds: [TagPair("Dungeon", "Revenge")], fetchedAt: start,
            candidates: [PooledCandidate(manga: manga("a"), contributions: [])])
        let empty = AniListPoolRecord(seeds: [TagPair("Dungeon", "Revenge")],
                                      fetchedAt: start, candidates: [])

        let inADay = start.addingTimeInterval(25 * 60 * 60)
        XCTAssertTrue(populated.isFresh(now: inADay))
        XCTAssertFalse(empty.isFresh(now: inADay),
                       "an empty pool is also what a transient failure looks like")

        let inAFortnight = start.addingTimeInterval(15 * 24 * 60 * 60)
        XCTAssertFalse(populated.isFresh(now: inAFortnight))
    }

    /// The entry's identity is the seed *set*: order must not matter, or a re-sort would
    /// invalidate a good pool.
    func testTheRecordIsKeyedOnTheSeedSetRegardlessOfOrder() {
        let record = AniListPoolRecord(seeds: [TagPair("Revenge", "Dungeon"),
                                               TagPair("Magic", "Dungeon")],
                                       fetchedAt: Date(), candidates: [])
        XCTAssertTrue(record.matches(seeds: [TagPair("Dungeon", "Magic"),
                                             TagPair("Dungeon", "Revenge")]))
        XCTAssertFalse(record.matches(seeds: [TagPair("Dungeon", "Magic")]))
    }

    // MARK: - The store

    func testAColdStoreAnswersNilAndNeverBlocks() async {
        let store = AniListPoolStore(directory: makeDirectory())
        let pool = await store.pool(seeds: [TagPair("Dungeon", "Revenge")])
        XCTAssertNil(pool)
    }

    /// `load()` fires on every Home appearance, so two appearances seconds apart must not
    /// kick two independent 5-query refreshes — 10 requests against a 30/min budget.
    func testConcurrentRefreshesForTheSameSeedsShareOneTask() async {
        let store = AniListPoolStore(directory: makeDirectory())
        let seeds = [TagPair("Dungeon", "Revenge")]
        let counter = Counter()

        let refresh: AniListPoolStore.Refresh = { pairs in
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return AniListPoolRecord(seeds: pairs, fetchedAt: Date(), candidates: [])
        }

        let first = await store.refreshIfNeeded(seeds: seeds, using: refresh)
        let second = await store.refreshIfNeeded(seeds: seeds, using: refresh)
        await first?.value
        await second?.value

        let count = await counter.value
        XCTAssertEqual(count, 1, "the second caller gets the same in-flight task")
    }

    func testARefreshThatAbortsLeavesThePreviousEntryStanding() async {
        let directory = makeDirectory()
        let store = AniListPoolStore(directory: directory)
        let seeds = [TagPair("Dungeon", "Revenge")]

        await store.refreshIfNeeded(seeds: seeds) { pairs in
            AniListPoolRecord(seeds: pairs, fetchedAt: Date(),
                              candidates: [PooledCandidate(manga: self.manga("kept"),
                                                           contributions: [])])
        }?.value
        // A later refresh that aborts (nil) must not clear what is there.
        await store.refreshIfNeeded(seeds: seeds, now: Date().addingTimeInterval(60 * 24 * 60 * 60)) { _ in
            nil
        }?.value

        let pool = await store.pool(seeds: seeds)
        XCTAssertEqual(pool?.candidates.map(\.manga.id), ["kept"])
    }

    /// Taste can shift while five queries are outstanding. The older refresh may finish
    /// *last*, and without a guard it would overwrite the newer pool with a superseded
    /// one — self-healing on the next Home appearance, but only at the cost of a whole
    /// refresh.
    func testARefreshForSupersededSeedsIsDiscardedNotWritten() async {
        let store = AniListPoolStore(directory: makeDirectory())
        let old = [TagPair("Dungeon", "Revenge")]
        let new = [TagPair("Magic", "Revenge")]

        // The old refresh is slow; the new one is kicked while it is still outstanding.
        let slow = await store.refreshIfNeeded(seeds: old) { pairs in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return AniListPoolRecord(seeds: pairs, fetchedAt: Date(),
                                     candidates: [PooledCandidate(manga: self.manga("stale"),
                                                                  contributions: [])])
        }
        let fast = await store.refreshIfNeeded(seeds: new) { pairs in
            AniListPoolRecord(seeds: pairs, fetchedAt: Date(),
                              candidates: [PooledCandidate(manga: self.manga("current"),
                                                           contributions: [])])
        }
        await fast?.value
        await slow?.value

        let current = await store.pool(seeds: new)
        let superseded = await store.pool(seeds: old)
        XCTAssertEqual(current?.candidates.map(\.manga.id), ["current"])
        XCTAssertNil(superseded, "the superseded refresh wrote nothing")
    }

    func testACorruptCacheFileIsAMiss() async {
        let directory = makeDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: directory.appendingPathComponent("anilist-pool.json"))

        let store = AniListPoolStore(directory: directory)
        let pool = await store.pool(seeds: [TagPair("Dungeon", "Revenge")])
        XCTAssertNil(pool)
    }

    func testAWrittenPoolSurvivesANewStoreOnTheSameDirectory() async {
        let directory = makeDirectory()
        let seeds = [TagPair("Dungeon", "Revenge")]

        await AniListPoolStore(directory: directory).refreshIfNeeded(seeds: seeds) { pairs in
            AniListPoolRecord(seeds: pairs, fetchedAt: Date(),
                              candidates: [PooledCandidate(manga: self.manga("persisted"),
                                                           contributions: [])])
        }?.value

        // In-memory-only would mean no pool on the first Home appearance of every cold
        // launch, which is the most common Home appearance there is.
        let reopened = AniListPoolStore(directory: directory)
        let pool = await reopened.pool(seeds: seeds)
        XCTAssertEqual(pool?.candidates.map(\.manga.id), ["persisted"])
    }

    // MARK: - buildRecord: the fan-out policies

    func testAllFivePairQueriesMustSucceedOrNothingIsWritten() async {
        let seeds = (1...5).map { seeded("Dungeon", "Tag\($0)", weight: Double($0)) }
        let attempts = Counter()

        let record = await AniListCandidateProvider.buildRecord(
            seeds: seeds,
            query: { _, _ in
                let n = await attempts.increment()
                if n == 3 { throw AniListError.invalidResponse }
                return [self.aniList(n, malId: n, [("Dungeon", 90), ("Tag\(n)", 90)])]
            },
            resolve: { _ in [:] },
            resolveLimit: 12)

        XCTAssertNil(record, "an entry keyed on five pairs but built from three lies about its key")
        let count = await attempts.value
        XCTAssertEqual(count, 3, "and it aborts rather than finishing the remaining queries")
    }

    /// Under AND semantics an empty result is a normal outcome for a reader whose taste is
    /// genuinely rare — not an error. Treating it as one would abort refreshes for exactly
    /// that reader and prevent the 24-hour empty record from ever being written.
    func testAQueryReturningNothingIsNotAFailure() async {
        let record = await AniListCandidateProvider.buildRecord(
            seeds: [seeded("Dungeon", "Revenge", weight: 1.0)],
            query: { _, _ in [] },
            resolve: { _ in [:] },
            resolveLimit: 12)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.candidates.count, 0)
        XCTAssertFalse(record?.isFresh(now: Date().addingTimeInterval(25 * 60 * 60)) ?? true,
                       "and it is written at the 24-hour TTL")
    }

    /// Only the head is resolved. The AniList side costs 5 requests regardless; the real
    /// fan-out is one live MangaDex search per unresolved `idMal`.
    func testOnlyTheTopCandidatesAreResolved() async {
        let works = (1...30).map { aniList($0, malId: $0,
                                           [("Dungeon", 100 - $0), ("Revenge", 100 - $0)]) }
        let asked = Box()

        _ = await AniListCandidateProvider.buildRecord(
            seeds: [seeded("Dungeon", "Revenge", weight: 1.0)],
            query: { _, _ in works },
            resolve: { works in
                await asked.set(works.compactMap(\.malId))
                return [:]
            },
            resolveLimit: 12)

        let ids = await asked.value
        XCTAssertEqual(ids.count, 12)
        XCTAssertEqual(ids, Array(1...12), "the head, in score order")
    }

    /// The per-pair page size is half the fan-out budget, and it reaches AniList only if
    /// something actually passes it. It was declared and never threaded through once.
    func testEachPairQueryAsksForThePerPairLimit() async {
        let asked = Box()

        _ = await AniListCandidateProvider.buildRecord(
            seeds: [seeded("Dungeon", "Revenge", weight: 1.0)],
            query: { _, limit in
                await asked.set([limit])
                return []
            },
            resolve: { _ in [:] },
            perPairLimit: 12,
            resolveLimit: 12)

        let limits = await asked.value
        XCTAssertEqual(limits, [12])
    }

    /// A title failing to resolve is the normal case — AniList's catalogue and MangaDex's
    /// are different sets. No minimum floor, and no backfill to top the head back up:
    /// that would turn a bounded fan-out into a loop whose length depends on network luck.
    func testResolutionFailuresNeitherAbortNorBackfill() async {
        let works = (1...30).map { aniList($0, malId: $0,
                                           [("Dungeon", 100 - $0), ("Revenge", 100 - $0)]) }
        let resolveCalls = Counter()

        let record = await AniListCandidateProvider.buildRecord(
            seeds: [seeded("Dungeon", "Revenge", weight: 1.0)],
            query: { _, _ in works },
            resolve: { works in
                await resolveCalls.increment()
                // Only 4 of the 12 come back.
                return Dictionary(uniqueKeysWithValues: works.compactMap(\.malId).prefix(4).map {
                    ($0, self.manga("md-\($0)", malId: $0))
                })
            },
            resolveLimit: 12)

        XCTAssertEqual(record?.candidates.count, 4)
        let calls = await resolveCalls.value
        XCTAssertEqual(calls, 1, "one bounded pass, never a top-up loop")
    }

    // MARK: - The provider: the gate and read-through

    private func provider(works: [Work],
                          vocabularyStore: TagVocabularyStore,
                          poolStore: AniListPoolStore,
                          query: @escaping AniListCandidateProvider.Query = { _, _ in [] },
                          resolve: @escaping AniListCandidateProvider.Resolve = { _ in [:] })
    -> AniListCandidateProvider {
        AniListCandidateProvider(loadWorks: { works },
                                 vocabularyStore: vocabularyStore,
                                 poolStore: poolStore,
                                 query: query,
                                 resolve: resolve)
    }

    private func vocabularyStore(seeded vocabulary: TagVocabulary?) -> TagVocabularyStore {
        let directory = makeDirectory()
        if let vocabulary {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(vocabulary)
                .write(to: directory.appendingPathComponent("anilist-tag-vocabulary.json"))
        }
        return TagVocabularyStore(directory: directory, fetch: { [] })
    }

    private func work(_ title: String, _ tags: [(String, Int?)]) -> Work {
        var w = Work(id: WorkID(), displayTitle: title, knownTitles: [title],
                     externalIds: ExternalIDs(), listings: [], snapshot: nil)
        w.snapshot = MetadataSnapshot(provider: .anilist,
                                      fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      genres: [],
                                      tags: tags.map { RankedTag(name: $0.0, rank: $0.1) },
                                      publicationStatus: .finished,
                                      chapterTotal: nil)
        return w
    }

    private func profile(_ weights: [WorkID: Double]) -> TasteProfile {
        TasteProfile(weights: [:], tagName: [:], orderedTagKeys: [],
                     taggedMangaCount: 0, seeds: [], workWeights: weights)
    }

    /// A missing vocabulary skips generation entirely rather than seeding with categories
    /// unknown — unfiltered seeding is specifically the "recommend me webtoons and Male
    /// Protagonist" failure. **Absence disqualifies; staleness does not.**
    func testNoVocabularyMeansNoPoolAndNoQueries() async throws {
        let queried = Counter()
        let provider = provider(works: [work("A", [("Dungeon", 90), ("Revenge", 90)])],
                                vocabularyStore: vocabularyStore(seeded: nil),
                                poolStore: AniListPoolStore(directory: makeDirectory()),
                                query: { _, _ in await queried.increment(); return [] })

        let out = try await provider.candidates(for: profile([:]), excluding: [], limit: 10)
        XCTAssertEqual(out.count, 0)
        let count = await queried.value
        XCTAssertEqual(count, 0)
    }

    /// The gate counts **contributing** Works. A Work whose ranked tags all sit below the
    /// floor contributes nothing, and counting it would open the gate on a store that then
    /// produces zero pairs — an empty pool cached for 24 hours, the gate doing the opposite
    /// of its job.
    func testTheGateCountsContributingWorksNotWorksWithARankedAxis() async throws {
        let contributing = (1...2).map { work("Real \($0)", [("Dungeon", 90), ("Revenge", 90)]) }
        // Ranked axis present, nothing admissible: both legs below 60.
        let hollow = (1...5).map { work("Hollow \($0)", [("Dungeon", 40), ("Revenge", 30)]) }
        let weights = Dictionary(uniqueKeysWithValues:
            (contributing + hollow).map { ($0.id, 1.0) })
        let queried = Counter()

        let provider = provider(works: contributing + hollow,
                                vocabularyStore: vocabularyStore(seeded: Self.vocabulary),
                                poolStore: AniListPoolStore(directory: makeDirectory()),
                                query: { _, _ in await queried.increment(); return [] })

        let out = try await provider.candidates(for: profile(weights), excluding: [], limit: 10)
        XCTAssertEqual(out.count, 0, "7 Works carry ranked tags, but only 2 contributed")
        let count = await queried.value
        XCTAssertEqual(count, 0, "and the gate closes before any budget is spent")
    }

    /// The rule the whole slice exists for: a cold pool returns **empty immediately** and
    /// the refresh happens behind it. The pool appears on the next rail build.
    func testAColdPoolReturnsEmptyAndRefreshesInTheBackground() async throws {
        let works = (1...3).map { work("W\($0)", [("Dungeon", 90), ("Revenge", 90)]) }
        let weights = Dictionary(uniqueKeysWithValues: works.map { ($0.id, 1.0) })
        let poolStore = AniListPoolStore(directory: makeDirectory())

        let provider = provider(works: works,
                                vocabularyStore: vocabularyStore(seeded: Self.vocabulary),
                                poolStore: poolStore,
                                query: { _, _ in [self.aniList(1, malId: 11,
                                                            [("Dungeon", 90), ("Revenge", 80)])] },
                                resolve: { works in
                                    Dictionary(uniqueKeysWithValues:
                                        works.compactMap(\.malId)
                                            .map { ($0, self.manga("md-\($0)", malId: $0)) })
                                })

        let profile = profile(weights)
        let first = try await provider.candidates(for: profile, excluding: [], limit: 10)
        XCTAssertEqual(first.count, 0, "cold miss — the rail must not wait for AniList")

        // Let the background refresh land, then ask again: the second build has the pool.
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = try await provider.candidates(for: profile, excluding: [], limit: 10)
        XCTAssertEqual(second.map(\.manga.id), ["md-11"])
        XCTAssertEqual(second.first?.reason, "More Dungeon + Revenge")
    }

    /// The seam the golden file cannot see.
    ///
    /// `RecommendationGoldenTests` feeds the composite a hand-scored `StubPool`, so nothing
    /// there proves a *real* `AniListCandidateProvider`'s output lands in the `ani` slot,
    /// normalizes against its own pool, and carries its reason through the
    /// tag < AniList < MAL precedence. This is that proof, and it is deliberately **not**
    /// goldened: it needs a settle for the background refresh, and a golden whose content
    /// depends on a sleep is the flake the fixture's no-ties invariant exists to avoid.
    ///
    /// Not covered here, and not automated anywhere: that the app's composition root hands
    /// the provider *single* long-lived store instances. See ADR-0011's hazard on that.
    func testTheAniListPoolReachesTheComposite() async throws {
        let works = (1...3).map { work("W\($0)", [("Dungeon", 90), ("Revenge", 90)]) }
        let weights = Dictionary(uniqueKeysWithValues: works.map { ($0.id, 1.0) })

        let ani = provider(works: works,
                           vocabularyStore: vocabularyStore(seeded: Self.vocabulary),
                           poolStore: AniListPoolStore(directory: makeDirectory()),
                           query: { _, _ in [self.aniList(1, malId: 11,
                                                          [("Dungeon", 90), ("Revenge", 80)])] },
                           resolve: { works in
                               Dictionary(uniqueKeysWithValues:
                                   works.compactMap(\.malId)
                                       .map { ($0, self.manga("md-\($0)", malId: $0)) })
                           })

        // A tag pool that also carries md-11, so the composite has something to blend with
        // and the reason precedence has something to override.
        let tag = FixedPool(items: [
            ScoredManga(manga: manga("md-11"), score: 1.0, reason: "More Dungeon"),
            ScoredManga(manga: manga("md-99"), score: 0.5, reason: "More Revenge")
        ])
        let composite = CompositeCandidateProvider(tag: tag, mal: EmptyCandidateProvider(),
                                                   ani: ani)
        let profile = profile(weights)

        let cold = try await composite.candidates(for: profile, excluding: [], limit: 10)
        XCTAssertEqual(cold.map(\.manga.id), ["md-11", "md-99"],
                       "a cold AniList pool degrades to the tag ranking, it does not fail it")
        XCTAssertEqual(cold.first?.reason, "More Dungeon",
                       "and nothing overrides the tag reason while the pool is empty")

        try await Task.sleep(nanoseconds: 200_000_000)
        let warm = try await composite.candidates(for: profile, excluding: [], limit: 10)

        XCTAssertEqual(warm.map(\.manga.id), ["md-11", "md-99"])
        XCTAssertEqual(warm.first?.reason, "More Dungeon + Revenge",
                       "the AniList reason overrides the tag one — a conjunction says more")
        // md-11 tops both pools, so both normalize to 1.0: 1.0 + 0.6 + 0.25 x sqrt(1 x 1).
        XCTAssertEqual(warm[0].score, 1.85, accuracy: 1e-9)
        XCTAssertEqual(warm[1].score, 0.5, accuracy: 1e-9,
                       "tag-only, so no AniList term and no agreement bonus")
    }

    /// Exclusions are applied at scoring time, never baked into the cache: `read ∪ saved ∪
    /// notInterested` changes every time a chapter is opened, the pool every two weeks.
    func testExclusionsAreAppliedAtReadTimeNotCachedIntoThePool() async throws {
        let works = (1...3).map { work("W\($0)", [("Dungeon", 90), ("Revenge", 90)]) }
        let weights = Dictionary(uniqueKeysWithValues: works.map { ($0.id, 1.0) })
        let poolStore = AniListPoolStore(directory: makeDirectory())

        let provider = provider(works: works,
                                vocabularyStore: vocabularyStore(seeded: Self.vocabulary),
                                poolStore: poolStore,
                                query: { _, _ in [self.aniList(1, malId: 11,
                                                            [("Dungeon", 90), ("Revenge", 80)])] },
                                resolve: { works in
                                    Dictionary(uniqueKeysWithValues:
                                        works.compactMap(\.malId)
                                            .map { ($0, self.manga("md-\($0)", malId: $0)) })
                                })

        let profile = profile(weights)
        _ = try await provider.candidates(for: profile, excluding: [], limit: 10)
        try await Task.sleep(nanoseconds: 200_000_000)

        let excluded = try await provider.candidates(for: profile,
                                                     excluding: ["md-11"], limit: 10)
        XCTAssertEqual(excluded.count, 0)

        // The pool itself still holds it — the title comes back when it stops being excluded.
        let included = try await provider.candidates(for: profile, excluding: [], limit: 10)
        XCTAssertEqual(included.map(\.manga.id), ["md-11"])
    }
}

// MARK: - Test doubles

/// Actors, not `var` captures: these are written from inside injected closures that run on
/// the pool store's unstructured refresh task.
private actor Counter {
    private(set) var value = 0
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

private actor Box {
    private(set) var value: [Int] = []
    func set(_ new: [Int]) { value = new }
}

/// A pre-scored pool, for asserting composite behaviour without a network-shaped provider.
private struct FixedPool: CandidateProvider {
    let items: [ScoredManga]
    func candidates(for profile: TasteProfile,
                    excluding: Set<String>, limit: Int) async throws -> [ScoredManga] { items }
}
