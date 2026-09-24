//
//  MetadataUpgradeQueueTests.swift
//  MangaCartaTests
//
//  ADR-0010. Everything decidable lives in `drainOnce`, which has no sleeps of its
//  own — the 2s pacing is injected as a zero interval and the 429 retry is
//  unreachable behind a stub transport — so these run at full speed with no
//  wall-clock dependence. The loop itself gets two tests at the bottom, through an
//  injected `sleep`.
//
//  Each test gets its own temp directories and its own UserDefaults suite, so no
//  file or cache under test is ever shared or real.
//

import XCTest
@testable import MangaCarta

final class MetadataUpgradeQueueTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    /// Solo Leveling, trimmed from `AniListAPITests`' recorded fixture. Real shape,
    /// so the queue's tests exercise the same decode path production does.
    private static func mediaJSON(id: Int = 105_398,
                                  malId: Int = 121_496,
                                  genres: String = #"["Action","Adventure"]"#,
                                  tags: String = #"[{"name":"Dungeon","rank":95}]"#,
                                  status: String = "FINISHED") -> Data {
        Data("""
        {"data":{"Media":{
          "id":\(id), "idMal":\(malId),
          "title":{"romaji":"Na Honjaman Level Up","english":"Solo Leveling","native":null},
          "synonyms":[], "genres":\(genres), "tags":\(tags),
          "status":"\(status)", "chapters":201
        }}}
        """.utf8)
    }

    /// AniList answers a missing entry with a null `Media`, which the client turns
    /// into `.notFound` (`AniListAPI.swift:172`).
    private static let nullMediaJSON = Data(#"{"data":{"Media":null}}"#.utf8)

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: AniListAPI.endpoint, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    /// An AniList client that answers every request the same way.
    private func anilist(_ data: Data, status: Int = 200) -> AniListAPI {
        AniListAPI(transport: { [http] _ in (data, http(status)) })
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore() -> WorkStore {
        WorkStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MetadataUpgradeQueueTests-\(UUID().uuidString)"))
    }

    @MainActor
    private func makeMemory() -> UpgradeAttemptMemory {
        UpgradeAttemptMemory(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MetadataUpgradeQueueTests-mem-\(UUID().uuidString)"))
    }

    /// A resolver whose MAL search is stubbed. The `EntityResolutionStore` is isolated
    /// but real, so the cache fast path is exercised rather than mocked away.
    @MainActor
    /// `bridge` defaults to finding nothing (ADR-0016): the live default would otherwise put
    /// a real MangaDex request behind every test here that misses on MAL. A test about the
    /// bridge passes its own.
    private func makeResolver(search: @escaping MALEntityResolver.Search,
                              bridge: @escaping MALEntityResolver.BridgeSearch
                                  = MALEntityResolver.noBridge) -> MALEntityResolver {
        MALEntityResolver(store: EntityResolutionStore(defaults: isolatedDefaults()),
                          search: search,
                          bridgeSearch: bridge)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MetadataUpgradeQueueTests-\(UUID().uuidString)")!
    }

    /// A search that echoes the query back as its one candidate — an exact match, with
    /// no runner-up to trip the ambiguity guard, whatever the Work is called. The
    /// matcher's own threshold is tested exhaustively in its own suite; these tests are
    /// about what the queue does with a confident answer.
    private func alwaysMatches(malId: Int = 121_496) -> MALEntityResolver.Search {
        { title in [MALCandidate(malId: malId, titles: [title])] }
    }

    /// A Listing. `Manga` *is* a Listing despite the name (ADR-0001).
    private func listing(_ id: String,
                         source: String = "mangadex",
                         title: String = "Solo Leveling",
                         malId: Int? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: title, description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: malId)
    }

    @MainActor
    private func makeQueue(works: WorkStore,
                           anilist: AniListAPI? = nil,
                           resolver: MALEntityResolver? = nil,
                           memory: UpgradeAttemptMemory? = nil,
                           idleInterval: TimeInterval = 60,
                           sleep: @escaping MetadataUpgradeQueue.Sleep = { _ in },
                           workMetadataChanged: @escaping (WorkID) -> Void = { _ in },
                           listingParticipates: @escaping (ListingKey) -> Bool = { _ in true })
        -> MetadataUpgradeQueue {
        MetadataUpgradeQueue(
            works: works,
            anilist: anilist ?? self.anilist(Self.mediaJSON()),
            // Zero interval: the limiter's own spacing is tested in its own suite, and
            // a cold limiter never delays its first caller anyway.
            rateLimiter: AniListRateLimiter(minimumInterval: 0),
            resolver: resolver ?? makeResolver(search: alwaysMatches()),
            memory: memory ?? makeMemory(),
            idleInterval: idleInterval,
            now: { self.noon },
            sleep: sleep,
            workMetadataChanged: workMetadataChanged,
            listingParticipates: listingParticipates)
    }

    // MARK: - The upgrade path

    @MainActor func testLocalOnlyWorkIsNeverEnqueued() async {
        let works = makeStore()
        _ = works.mint(from: listing("local-item", source: "local"))
        let queue = makeQueue(works: works, listingParticipates: { $0.sourceId != "local" })
        let step = await queue.drainOnce(now: noon)
        XCTAssertEqual(step, .idle)
    }

    /// The whole happy path in one: an unresolved Work with no snapshot is resolved
    /// against MAL, fetched from AniList, and left carrying a provider snapshot and
    /// both external ids.
    @MainActor func testDrainOnceUpgradesAnUnresolvedWorkToAProviderSnapshot() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let queue = makeQueue(works: works)

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .upgraded(id))
        XCTAssertEqual(works.work(id)?.snapshot?.provider, .anilist)
        XCTAssertEqual(works.work(id)?.snapshot?.genres.map(\.name), ["Action", "Adventure"])
        XCTAssertEqual(works.work(id)?.externalIds.mal, 121_496)
        XCTAssertEqual(works.work(id)?.externalIds.anilist, 105_398)
    }

    /// A Work that already carries a MAL id skips resolution entirely — the search
    /// closure traps if it is ever called.
    /// The signal the MAL progress subsystem waits on. The queue owns metadata and knows
    /// nothing about progress; it only announces that a Work has learned external ids, and
    /// it announces the *surviving* id, because writing the ids may have merged the Work
    /// away.
    @MainActor func testLearningExternalIdsAnnouncesTheSurvivingWork() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        var announced: [WorkID] = []
        let queue = makeQueue(works: works, workMetadataChanged: { announced.append($0) })

        _ = await queue.drainOnce(now: noon)

        XCTAssertEqual(announced.first, id)
        XCTAssertEqual(works.work(id)?.externalIds.mal, 121_496)
    }

    @MainActor func testAWorkWithNothingNewToLearnAnnouncesNothing() async {
        let works = makeStore()
        _ = works.mint(from: listing("md-1"))
        var announced: [WorkID] = []
        let queue = makeQueue(works: works, workMetadataChanged: { announced.append($0) })
        _ = await queue.drainOnce(now: noon)
        announced.removeAll()

        _ = await queue.drainOnce(now: noon)

        XCTAssertEqual(announced, [])
    }

    @MainActor func testAWorkThatAlreadyCarriesAMalIdIsNotSearchedAgain() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1", malId: 121_496))
        let queue = makeQueue(works: works,
                              resolver: makeResolver(search: { _ in
                                  XCTFail("a Work with a known MAL id must not be searched")
                                  return []
                              }))

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .upgraded(id))
        XCTAssertEqual(works.work(id)?.snapshot?.provider, .anilist)
    }

    /// Nothing stale ⇒ nothing to do. A fresh provider snapshot on a FINISHED Work is
    /// terminal (`Work.swift:104`), so it can never come back.
    @MainActor func testDrainOnceIsIdleWhenNothingIsEligible() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let queue = makeQueue(works: works)
        _ = await queue.drainOnce(now: noon)          // upgrades it
        XCTAssertEqual(works.work(id)?.snapshot?.provider, .anilist)

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .idle)
    }

    // MARK: - Ordering

    /// The push from the recommender is the whole ordering source (ADR-0009): the
    /// queue never reaches back for it, so what it was last handed is what it obeys.
    @MainActor func testTheHighestWeightedEligibleWorkIsDrainedFirst() async {
        let works = makeStore()
        let low = works.mint(from: listing("md-1", title: "Low"))
        let high = works.mint(from: listing("md-2", title: "High"))
        let queue = makeQueue(works: works)
        queue.setPriority([low: 0.2, high: 9.0])

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .upgraded(high))
        XCTAssertNil(works.work(low)?.snapshot, "the lower-weighted Work waits its turn")
    }

    /// ADR-0009's amended tail: a Work with no reading history has no weight, and
    /// sorts after every Work that has one — however small.
    @MainActor func testAWorkWithNoWeightSortsAfterEveryWeightedWork() async {
        let works = makeStore()
        let unweighted = works.mint(from: listing("md-1", title: "Unweighted"))
        let barelyWeighted = works.mint(from: listing("md-2", title: "Barely"))
        let queue = makeQueue(works: works)
        queue.setPriority([barelyWeighted: 0.000_001])

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .upgraded(barelyWeighted))
        XCTAssertNil(works.work(unweighted)?.snapshot)
    }

    /// `allWorkIds()` order is unspecified — dictionary key order is randomized per
    /// process — so without an explicit tiebreak the unweighted tail would drain in a
    /// different order on every launch.
    @MainActor func testTheUnweightedTailIsOrderedByWorkId() async {
        let works = makeStore()
        let a = works.mint(from: listing("md-1", title: "First"))
        let b = works.mint(from: listing("md-2", title: "Second"))
        let expected = [a, b].min { $0.raw.uuidString < $1.raw.uuidString }!
        let queue = makeQueue(works: works)

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .upgraded(expected))
    }

    // MARK: - Answers vs. failures

    /// MAL had candidates and none cleared the threshold. That is an *answer*, so it is
    /// remembered and the Work stops being a candidate — otherwise every pass re-searches
    /// it forever.
    @MainActor func testAWorkWithNoConfidentMatchIsRecordedAndStopsBeingACandidate() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1", title: "Solo Leveling"))
        let queue = makeQueue(works: works,
                              resolver: makeResolver(search: { _ in
                                  [MALCandidate(malId: 7, titles: ["Something Else Entirely"])]
                              }))

        let first = await queue.drainOnce(now: noon)
        let second = await queue.drainOnce(now: noon)

        XCTAssertEqual(first, .upgraded(id), "a recorded answer is forward progress")
        XCTAssertNil(works.work(id)?.externalIds.mal, "nothing was matched, so nothing is written")
        XCTAssertEqual(second, .idle, "the recorded miss suppresses it")
    }

    /// ADR-0016 Decision 5, and the ordering trap inside it. The bridge identifies the right
    /// series but it carries no mal link, so the Work stays unresolved — while gaining two
    /// spellings. `.unmatched` is fingerprinted on `knownTitles.count`, so recording the
    /// **pre**-harvest count would reopen the Work on the very next pass and re-run the
    /// searches that just failed with these exact titles. The second drain asserts it does
    /// not: the Work is suppressed, having been remembered against what it now knows.
    @MainActor func testHarvestedSpellingsAreRecordedAgainstThePostHarvestTitleCount() async {
        let works = makeStore()
        let id = works.mint(from: listing("wc-1", source: "weebcentral", title: "Girlfriend, Girlfriend"))
        let queue = makeQueue(works: works,
                              resolver: makeResolver(search: { _ in [] }, bridge: { _ in
                                  [Manga(id: "md-x", sourceId: "mangadex",
                                         title: "Girlfriend Girlfriend", description: "",
                                         status: "ongoing", year: nil, coverURL: nil, malId: nil,
                                         altTitles: ["Kanojo mo Kanojo"])]
                              }))

        let first = await queue.drainOnce(now: noon)
        let second = await queue.drainOnce(now: noon)

        XCTAssertEqual(first, .upgraded(id))
        XCTAssertNil(works.work(id)?.externalIds.mal, "no mal link to take, so nothing is written")
        XCTAssertEqual(works.work(id)?.knownTitles.sorted(),
                       ["Girlfriend Girlfriend", "Girlfriend, Girlfriend", "Kanojo mo Kanojo"],
                       "both spellings the bridge learned are kept (ADR-0009: knownTitles only grows)")
        XCTAssertEqual(second, .idle,
                       "recorded against the post-harvest count, so the harvest cannot reopen it")
    }

    /// A 4xx is a statement about the *request*, not the network: reissuing it unchanged
    /// returns the same thing forever, so it is an answer and belongs in attempt memory.
    /// Observed live 2026-07-28 — MAL 400s on any `q` over 64 characters.
    @MainActor func testAPermanentResolutionFailureIsRecordedRatherThanRetriedForever() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let queue = makeQueue(works: works,
                              resolver: makeResolver(search: { _ in
                                  throw MyAnimeListError.httpStatus(400)
                              }))

        let first = await queue.drainOnce(now: noon)
        let second = await queue.drainOnce(now: noon)

        XCTAssertEqual(first, .upgraded(id), "a recorded answer is forward progress")
        XCTAssertEqual(second, .idle, "the recorded answer suppresses it")
    }

    /// The livelock this cost in production, as a regression test. Three unsearchable
    /// Works sorted ahead of a good one used to fail transiently, trip the breaker on the
    /// third, and end the pass — and because `endPass` clears the skip set, the next pass
    /// replayed the identical three. The good Work was never reached, on any pass, ever.
    @MainActor func testUnsearchableWorksDoNotStarveTheOnesBehindThem() async {
        let works = makeStore()
        let bad = (1...3).map {
            works.mint(from: listing("md-bad-\($0)", title: "Unsearchable \($0)"))
        }
        let good = works.mint(from: listing("md-good", title: "Solo Leveling"))
        let queue = makeQueue(works: works,
                              resolver: makeResolver(search: { title in
                                  guard !title.hasPrefix("Unsearchable") else {
                                      throw MyAnimeListError.httpStatus(400)
                                  }
                                  return [MALCandidate(malId: 121_496, titles: [title])]
                              }))
        // Weights force the three bad Works to the front, which is the ordering that
        // produced the livelock. Without them the tail order is by Work id, and the test
        // would pass for the wrong reason whenever the good Work happened to sort first.
        queue.setPriority([bad[0]: 3, bad[1]: 2, bad[2]: 1, good: 0.5])

        var steps: [MetadataUpgradeQueue.DrainStep] = []
        for _ in 0..<4 { steps.append(await queue.drainOnce(now: noon)) }

        XCTAssertEqual(steps.last, .upgraded(good),
                       "the good Work is reached on the turn after the three bad ones")
        XCTAssertNotNil(works.work(good)?.snapshot,
                        "and is actually upgraded, not merely visited")
        XCTAssertFalse(steps.contains(.idle),
                       "no breaker trip: none of the three 400s is a transient failure")
    }

    /// The distinction the whole `UpgradeOutcome` enum exists for: a transient failure is
    /// **not** an answer, so recording it would poison the memory for fourteen days.
    @MainActor func testATransientResolutionFailureRecordsNothing() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let memory = makeMemory()
        var shouldThrow = true
        let flaky = makeQueue(works: works,
                              resolver: makeResolver(search: { title in
                                  if shouldThrow { throw AniListError.httpStatus(503) }
                                  return [MALCandidate(malId: 121_496, titles: [title])]
                              }),
                              memory: memory)

        let failure = await flaky.drainOnce(now: noon)
        shouldThrow = false
        // Skipped for the *rest of the pass*, so the pass has to end before it reopens —
        // which for a one-Work store is the very next turn.
        let endOfPass = await flaky.drainOnce(now: noon)
        let retry = await flaky.drainOnce(now: noon)

        XCTAssertEqual(failure, .failed(id))
        XCTAssertEqual(endOfPass, .idle)
        XCTAssertEqual(retry, .upgraded(id), "an outage must not suppress the Work for the TTL")
        XCTAssertEqual(works.work(id)?.snapshot?.provider, .anilist)
    }

    /// Recording nothing is what makes the skip set necessary: without it the same Work
    /// sorts back to the head and is retried every two seconds forever.
    @MainActor func testATransientlyFailedWorkIsSkippedForTheRestOfThePass() async {
        let works = makeStore()
        let doomed = works.mint(from: listing("md-1", title: "Doomed"))
        let healthy = works.mint(from: listing("md-2", title: "Healthy"))
        let queue = makeQueue(works: works,
                              resolver: makeResolver(search: { title in
                                  if title == "Doomed" { throw AniListError.httpStatus(503) }
                                  return [MALCandidate(malId: 121_496, titles: [title])]
                              }))
        queue.setPriority([doomed: 9.0, healthy: 1.0])

        let first = await queue.drainOnce(now: noon)
        let second = await queue.drainOnce(now: noon)

        XCTAssertEqual(first, .failed(doomed))
        XCTAssertEqual(second, .upgraded(healthy),
                       "the pass moves on rather than re-picking the highest-weighted Work")
    }

    /// The breaker: three failures in a row means the network, not the Work. Without it an
    /// offline device burns one paced request per Work in the store before idling.
    @MainActor func testThreeConsecutiveFailuresEndThePassEvenWithWorkLeft() async {
        let works = makeStore()
        for index in 1...5 { _ = works.mint(from: listing("md-\(index)", title: "Work \(index)")) }
        let queue = makeQueue(works: works,
                              resolver: makeResolver(search: { _ in
                                  throw AniListError.httpStatus(503)
                              }))

        var steps: [MetadataUpgradeQueue.DrainStep] = []
        for _ in 0..<4 { steps.append(await queue.drainOnce(now: noon)) }

        let ids = works.allWorkIds()
        XCTAssertEqual(steps.prefix(2).map { $0 == .idle }, [false, false])
        XCTAssertEqual(steps[2], .idle,
                       "the third failure idles immediately rather than spending a fourth request")
        XCTAssertNotEqual(steps[3], .idle, "and the next turn opens a fresh pass")
        XCTAssertEqual(ids.count, 5, "all five are still eligible — the pass ended, not the work")
    }

    /// An already-answered Work never becomes a candidate at all — the predicate is
    /// staleness **and** attempt memory, and the queue owns both halves (ADR-0009).
    @MainActor func testAWorkSuppressedByAttemptMemoryIsNotACandidate() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let memory = makeMemory()
        memory.record(.absentFromProvider(malId: 121_496), for: id, now: noon)
        let queue = makeQueue(works: works, memory: memory)

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .idle)
        XCTAssertNil(works.work(id)?.snapshot)
    }

    // MARK: - The empty-record hole (ADR-0010)

    /// `apply` writes a snapshot only when the record has content, so an AniList entry
    /// with neither genres nor tags leaves the provisional snapshot in place — which is
    /// unconditionally stale. Without recording an outcome the Work is re-fetched every
    /// two seconds forever.
    @MainActor func testAnAniListRecordWithNoGenresOrTagsIsRecordedRatherThanRetried() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        works.applyProvisionalSnapshot(tags: [Tag(id: "t1", name: "Action", group: "genre")], to: id)
        let queue = makeQueue(works: works,
                              anilist: anilist(Self.mediaJSON(genres: "[]", tags: "[]")))

        let first = await queue.drainOnce(now: noon)
        let second = await queue.drainOnce(now: noon)

        XCTAssertEqual(first, .upgraded(id))
        XCTAssertEqual(works.work(id)?.snapshot?.provider, .mangadex,
                       "an empty record must not discard the provisional tags")
        XCTAssertEqual(second, .idle, "and must not be re-fetched forever either")
    }

    /// A null `Media` is AniList's "no such entry". Terminal, TTL-only, and **not** a
    /// transient failure — so it must not count toward the breaker.
    @MainActor func testANotFoundIsAnAnswerNotAFailure() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let queue = makeQueue(works: works, anilist: anilist(Self.nullMediaJSON))

        let first = await queue.drainOnce(now: noon)
        let second = await queue.drainOnce(now: noon)

        XCTAssertEqual(first, .upgraded(id))
        XCTAssertEqual(second, .idle, "recorded as absent, so it stops being a candidate")
    }

    /// ADR-0009 writes the id before the fetch precisely so a transient failure does not
    /// rewind the Work to a resolution case and re-search MAL forever.
    @MainActor func testATransientFetchFailureStillLeavesTheMalIdWritten() async {
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let queue = makeQueue(works: works,
                              anilist: anilist(Data("nope".utf8), status: 503))

        let step = await queue.drainOnce(now: noon)

        XCTAssertEqual(step, .failed(id))
        XCTAssertEqual(works.work(id)?.externalIds.mal, 121_496,
                       "the id survives so the next attempt is a fetch, not another search")
        XCTAssertNil(works.work(id)?.snapshot)
    }

    // MARK: - Resolve before you remember (ADR-0010)

    /// Writing the external id can merge this Work into an incumbent, deleting it. A
    /// record written against the original id is then dead on arrival — `allWorkIds()`
    /// yields only live ids — leaving the survivor unsuppressed and re-picked forever.
    @MainActor func testAnOutcomeAfterAMergeIsRecordedAgainstTheSurvivingWork() async {
        let works = makeStore()
        let incumbent = works.mint(from: listing("md-1", title: "Solo Leveling", malId: 121_496))
        let newcomer = works.mint(from: listing("wc-1", source: "weebcentral", title: "Only I Level Up"))
        let queue = makeQueue(works: works, anilist: anilist(Self.nullMediaJSON))
        queue.setPriority([newcomer: 9.0])

        let first = await queue.drainOnce(now: noon)
        let second = await queue.drainOnce(now: noon)

        XCTAssertEqual(works.work(newcomer)?.id, incumbent, "the merge happened")
        XCTAssertEqual(first, .upgraded(incumbent), "and the outcome is the survivor's")
        XCTAssertEqual(second, .idle,
                       "the survivor is suppressed; a record against the merged-away id would not suppress it")
    }

    /// A merge is the moment the queue may have made its own remaining work redundant. If
    /// the survivor already carries a fresh provider snapshot there is nothing left to
    /// fetch, and spending a paced request would overwrite good data with the same data.
    @MainActor func testAMergeIntoAnAlreadyFreshWorkSkipsTheFetch() async {
        let works = makeStore()
        let incumbent = works.mint(from: listing("md-1", title: "Solo Leveling"))
        let memory = makeMemory()
        _ = await makeQueue(works: works, memory: memory).drainOnce(now: noon)
        XCTAssertEqual(works.work(incumbent)?.snapshot?.publicationStatus, .finished,
                       "FINISHED is terminal, so the incumbent can never go stale again")

        let newcomer = works.mint(from: listing("wc-1", source: "weebcentral", title: "Only I Level Up"))
        let trapping = makeQueue(works: works,
                                 anilist: AniListAPI(transport: { _ in
                                     XCTFail("a merge into a fresh Work must not spend a request")
                                     throw AniListError.invalidResponse
                                 }),
                                 memory: memory)
        trapping.setPriority([newcomer: 9.0])

        let step = await trapping.drainOnce(now: noon)

        XCTAssertEqual(step, .upgraded(incumbent))
    }

    // MARK: - The loop

    /// `run` has exactly one branch: idle means sleep. Everything else it does is
    /// `drainOnce`'s, which is why this is the only test the loop's body needs.
    @MainActor func testTheLoopSleepsTheIdleIntervalWhenThereIsNothingToDo() async {
        let works = makeStore()                       // empty: every turn is idle
        var sleeps: [TimeInterval] = []
        let queue = makeQueue(works: works, idleInterval: 42, sleep: { interval in
            sleeps.append(interval)
            // Real `Task.sleep` throws only on cancellation, so throwing here is how a
            // test ends the loop without a wall clock.
            if sleeps.count >= 2 { throw CancellationError() }
        })

        queue.start()
        await queue.loopTask?.value

        XCTAssertEqual(sleeps, [42, 42])
    }

    /// `.active` recurs without an intervening `.background` — a dismissed notification
    /// banner is enough. Without the guard each one leaks another loop, and "serial by
    /// construction" quietly stops being true.
    @MainActor func testStartingTwiceRunsOneLoop() async {
        let works = makeStore()
        var sleeps = 0
        let queue = makeQueue(works: works, sleep: { _ in
            sleeps += 1
            throw CancellationError()
        })

        queue.start()
        queue.start()
        await queue.loopTask?.value
        await Task.yield()                            // a leaked second loop would run here

        XCTAssertEqual(sleeps, 1)
    }

    /// A debounced save that never fires because the app was suspended is a lost write,
    /// so backgrounding flushes rather than waiting for the timer.
    @MainActor func testFlushWritesTheAttemptMemoryThrough() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MetadataUpgradeQueueTests-flush-\(UUID().uuidString)")
        let works = makeStore()
        let id = works.mint(from: listing("md-1"))
        let queue = makeQueue(works: works,
                              anilist: anilist(Self.nullMediaJSON),
                              memory: UpgradeAttemptMemory(directory: directory))
        _ = await queue.drainOnce(now: noon)

        queue.flush()

        let reloaded = UpgradeAttemptMemory(directory: directory)
        XCTAssertTrue(reloaded.suppresses(works.work(id)!, now: noon))
    }
}
