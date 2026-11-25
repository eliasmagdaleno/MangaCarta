import Foundation
import XCTest
@testable import MangaCarta

final class CoOccurrenceCandidateProviderTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func manga(_ id: Int) -> Manga {
        Manga(id: "m\(id)", sourceId: "fixture", title: "Title \(id)", description: "",
              status: "", year: nil, coverURL: nil, malId: id, altTitles: nil, contentRating: "safe")
    }

    private func work(_ malID: Int, listings: [ListingKey] = []) -> Work {
        Work(id: WorkID(), displayTitle: "Seed \(malID)", knownTitles: ["Seed \(malID)"],
             externalIds: ExternalIDs(mal: malID, anilist: nil), listings: listings)
    }

    private func profile(_ seed: Work) -> TasteProfile {
        TasteProfile(weights: [:], tagName: [:], orderedTagKeys: [], taggedMangaCount: 0,
                     seeds: [], workWeights: [seed.id: 2.0])
    }

    private func store(_ dir: URL, table: CoOccurrenceTable, malIDs: [Int],
                       candidates: [Manga], now: Date) async throws -> CoOccurrenceStore {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tableCache = CoOccurrenceTableCache(table: table, fetchedAt: now, attemptedAt: now)
        try JSONEncoder().encode(tableCache).write(to: dir.appendingPathComponent("cooccurrence-v1.json"))
        let pool = CoOccurrencePoolRecord(malIDs: malIDs, fetchedAt: now,
            candidates: Dictionary(candidates.map { ($0.malId ?? 0, $0) }, uniquingKeysWith: { first, _ in first }))
        try JSONEncoder().encode(pool).write(to: dir.appendingPathComponent("cooccurrence-pool.json"))
        return CoOccurrenceStore(directory: dir, clock: { now })
    }

    func testPairsBelowThresholdAreDropped() throws {
        let data = Data(#"{"v":1,"k":20,"pairs":{"21":[[22,19],[23,20],[21,40],[0,40],[-5,40]],"-1":[[4,40]]}}"#.utf8)
        let table = try CoOccurrenceTable(data: data).validated()
        XCTAssertEqual(table.pairs, [21: [[23, 20]]])
    }

    /// The exclusion holds Listing ids, so each excluded Work is named by one copy while the
    /// pool resolves a different copy of it.
    func testNeverReturnsReadSavedOrDismissed() async throws {
        let now = Date()
        let seed = work(21)
        let otherSeed = work(27)
        let saved = work(22, listings: [ListingKey(sourceId: "other", mangaId: "saved-copy")])
        var dismissed = work(23)
        dismissed.removedListings = [RemovedListing(key: ListingKey(sourceId: "other", mangaId: "dismissed-copy"),
                                                    keepsReadState: true)]
        // Excluded Work with no MAL id, owning the Listing that id 24 resolves to.
        let unidentified = Work(id: WorkID(), displayTitle: "x", knownTitles: ["x"],
                                externalIds: ExternalIDs(mal: nil, anilist: nil),
                                listings: [ListingKey(sourceId: "other", mangaId: "x-copy"),
                                           ListingKey(sourceId: "fixture", mangaId: "m24")])
        let ids = [24, 25, 26]
        let dir = directory()
        let entries = (21...27).map { [$0, 20] }
        let cache = try await store(dir, table: CoOccurrenceTable(pairs: [21: entries]), malIDs: ids,
                                    candidates: ids.map(manga), now: now)
        let provider = CoOccurrenceCandidateProvider(isEnabled: { true }, fetchTable: { nil },
            loadWorks: { [seed, otherSeed, saved, dismissed, unidentified] }, titles: { _ in [] },
            resolve: { _ in [:] }, store: cache)
        let excluding: Set<String> = ["saved-copy", "dismissed-copy", "x-copy", "m25"]
        let taste = TasteProfile(weights: [:], tagName: [:], orderedTagKeys: [], taggedMangaCount: 0,
                                 seeds: [], workWeights: [seed.id: 2.0, otherSeed.id: 1.0])
        let results = try await provider.candidates(for: taste, excluding: excluding, limit: 12)
        XCTAssertEqual(results.map(\.manga.id), ["m26"])
    }

    func testAMatchWithoutItsOwnMALIdIsKept() async throws {
        let now = Date()
        let seed = work(21)
        let dir = directory()
        let store = CoOccurrenceStore(directory: dir, clock: { now })
        let bare = Manga(id: "bare", sourceId: "fixture", title: "Bare", description: "",
                         status: "", year: nil, coverURL: nil, malId: nil)
        await store.refreshTableIfNeeded(enabled: { true }, fetch: {
            Data(#"{"v":1,"k":20,"pairs":{"21":[[22,20]]}}"#.utf8)
        })?.value
        await store.refreshPoolIfNeeded(malIDs: [22], enabled: { true }, titles: { _ in [] },
                                        resolve: { _ in [22: bare] })?.value
        let reopened = CoOccurrenceStore(directory: dir, clock: { now })
        let provider = CoOccurrenceCandidateProvider(isEnabled: { true }, fetchTable: { nil },
            loadWorks: { [seed] }, titles: { _ in [] }, resolve: { _ in [:] }, store: reopened)
        let results = try await provider.candidates(for: profile(seed), excluding: [], limit: 12)
        XCTAssertEqual(results.map(\.manga.id), ["bare"])
        XCTAssertEqual(results.map(\.reasonKind), [.cooccurrence])
    }

    func testExclusionHappensBeforeTheHeadIsTaken() async throws {
        let now = Date()
        let seed = work(21)
        let entries = (22...35).map { [$0, 20] }
        let table = CoOccurrenceTable(pairs: [21: entries])
        let dir = directory()
        let cache = try await store(dir, table: table, malIDs: [34, 35], candidates: [manga(34), manga(35)], now: now)
        let excludedWorks = (22...33).map { work($0, listings: [ListingKey(sourceId: "different", mangaId: "excluded\($0)")]) }
        let excludedIDs = Set((22...33).map { "excluded\($0)" })
        let provider = CoOccurrenceCandidateProvider(isEnabled: { true }, fetchTable: { nil },
            loadWorks: { [seed] + excludedWorks }, titles: { _ in [] }, resolve: { _ in [:] }, store: cache)
        let result = try await provider.candidates(for: profile(seed), excluding: excludedIDs, limit: 12)
        XCTAssertTrue(result.contains { $0.manga.malId == 35 })
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheHeadIsTwelveTitles() async throws {
        let now = Date()
        let seed = work(21)
        let ids = Array(30...41)
        let table = CoOccurrenceTable(pairs: [21: (30...42).map { [$0, 20] }])
        let cache = try await store(directory(), table: table, malIDs: ids, candidates: ids.map(manga), now: now)
        let provider = CoOccurrenceCandidateProvider(isEnabled: { true }, fetchTable: { nil },
            loadWorks: { [seed] }, titles: { _ in [] }, resolve: { _ in [:] }, store: cache)
        let results = try await provider.candidates(for: profile(seed), excluding: [], limit: 20)
        XCTAssertEqual(results.map(\.manga.malId), ids)
    }

    func testEmptyTableReturnsNothingAndAsksNobody() async throws {
        let now = Date()
        let seed = work(21)
        let dir = directory()
        let store = CoOccurrenceStore(directory: dir, clock: { now })
        await store.refreshTableIfNeeded(enabled: { true }, fetch: {
            Data(#"{"v":1,"k":20,"pairs":{}}"#.utf8)
        })?.value
        let provider = CoOccurrenceCandidateProvider(isEnabled: { true }, fetchTable: { nil },
            loadWorks: { [seed] }, titles: { _ in [] }, resolve: { _ in [:] }, store: store)
        let results = try await provider.candidates(for: profile(seed), excluding: [], limit: 10)
        XCTAssertTrue(results.isEmpty)
        let asked = await store.refreshPoolIfNeeded(malIDs: [], enabled: { true }, titles: { _ in [] },
                                                    resolve: { _ in [:] })
        XCTAssertNil(asked)
    }

    func testWithoutConsentNothingIsFetchedOrReturned() async throws {
        let now = Date()
        let seed = work(21)
        let dir = directory()
        let cache = try await store(dir, table: CoOccurrenceTable(pairs: [21: [[22, 20]]]),
                                    malIDs: [22], candidates: [manga(22)], now: now)
        let loadedWorks = TestCounter()
        let unexpectedCalls = TestCounter()
        let consent = TestConsentSequence([false])
        let provider = CoOccurrenceCandidateProvider(isEnabled: { await consent.next() },
            fetchTable: {
                await unexpectedCalls.add(1)
                return nil
            },
            loadWorks: {
                await loadedWorks.add(1)
                return [seed]
            }, titles: { _ in
                await unexpectedCalls.add(1)
                return []
            }, resolve: { _ in
                await unexpectedCalls.add(1)
                return [:]
            }, store: cache)
        let result = try await provider.candidates(for: profile(seed), excluding: [], limit: 10)
        let loadedCount = await loadedWorks.value
        let callCount = await unexpectedCalls.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(loadedCount, 0)
        XCTAssertEqual(callCount, 0)
    }

    func testWithdrawingConsentStopsBackgroundFetch() async throws {
        let dir = directory()
        let store = CoOccurrenceStore(directory: dir)
        let fetched = TestCounter()
        let consent = TestConsentSequence([false])
        let task = await store.refreshTableIfNeeded(enabled: { await consent.next() }, fetch: {
            await fetched.add(1)
            return Data(#"{"v":1,"k":20,"pairs":{}}"#.utf8)
        })
        await task?.value
        let fetchCount = await fetched.value
        XCTAssertEqual(fetchCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cooccurrence-v1.json").path))
    }

    func testBackgroundRefreshChecksConsentBeforeWriting() async throws {
        let dir = directory()
        let store = CoOccurrenceStore(directory: dir)
        let consent = TestConsentSequence([true, false])
        let task = await store.refreshTableIfNeeded(enabled: { await consent.next() }, fetch: {
            Data(#"{"v":1,"k":20,"pairs":{}}"#.utf8)
        })
        await task?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cooccurrence-v1.json").path))
    }

    func testWithdrawingConsentDoesNotReturnCachedCandidates() async throws {
        let now = Date()
        let seed = work(21)
        let dir = directory()
        let cache = try await store(dir, table: CoOccurrenceTable(pairs: [21: [[22, 20]]]),
                                    malIDs: [22], candidates: [manga(22)], now: now)
        let consent = TestConsentSequence([true, true, true, false])
        let unexpectedCalls = TestCounter()
        let provider = CoOccurrenceCandidateProvider(isEnabled: { await consent.next() },
            fetchTable: {
                await unexpectedCalls.add(1)
                return nil
            }, loadWorks: { [seed] }, titles: { _ in
                await unexpectedCalls.add(1)
                return []
            }, resolve: { _ in
                await unexpectedCalls.add(1)
                return [:]
            }, store: cache)
        let result = try await provider.candidates(for: profile(seed), excluding: [], limit: 10)
        let callCount = await unexpectedCalls.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(callCount, 0)
    }

    func testWithdrawingConsentDeletesTheCaches() async throws {
        let dir = directory()
        let store = CoOccurrenceStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: dir.appendingPathComponent("cooccurrence-v1.json"))
        try Data("cache".utf8).write(to: dir.appendingPathComponent("cooccurrence-pool.json"))
        await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cooccurrence-v1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cooccurrence-pool.json").path))

        let tableTask = await store.refreshTableIfNeeded(enabled: { true }, fetch: {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return Data(#"{"v":1,"k":20,"pairs":{"21":[[22,20]]}}"#.utf8)
        })
        let poolTask = await store.refreshPoolIfNeeded(malIDs: [22], enabled: { true }, titles: { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return [AniListWork(anilistId: 100, malId: 22, knownTitles: [], genres: [], tags: [],
                                publicationStatus: .unknown, chapterTotal: nil)]
        }, resolve: { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return [22: self.manga(22)]
        })
        await store.clear()
        await tableTask?.value
        await poolTask?.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cooccurrence-v1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cooccurrence-pool.json").path))
    }

    func testTableRefreshesWeeklyAndFailureWaitsADay() async throws {
        let dir = directory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = CoOccurrenceStore(directory: dir, clock: { now })
        let calls = TestCounter()
        let failed = await store.refreshTableIfNeeded(now: now, enabled: { true }, fetch: {
            await calls.add(1)
            return nil
        })
        await failed?.value
        let blockedRetry = await store.refreshTableIfNeeded(
            now: now.addingTimeInterval(23 * 3600), enabled: { true }, fetch: {
                await calls.add(1)
                return nil
            })
        XCTAssertNil(blockedRetry)
        var callCount = await calls.value
        XCTAssertEqual(callCount, 1)
        let retry = await store.refreshTableIfNeeded(
            now: now.addingTimeInterval(25 * 3600), enabled: { true }, fetch: {
                await calls.add(1)
                return nil
            })
        await retry?.value
        callCount = await calls.value
        XCTAssertEqual(callCount, 2)
        let reopened = CoOccurrenceStore(directory: dir, clock: { now })
        let persistedGate = await reopened.refreshTableIfNeeded(
            now: now.addingTimeInterval(26 * 3600), enabled: { true }, fetch: {
                await calls.add(1)
                return nil
            })
        XCTAssertNil(persistedGate)
        callCount = await calls.value
        XCTAssertEqual(callCount, 2)
    }

    func testMalformedTableKeepsThePreviousOne() async throws {
        // Valid but for its size: JSON ignores the trailing spaces.
        let oversized = Data(#"{"v":1,"k":20,"pairs":{}}"#.utf8)
            + Data(repeating: 32, count: CoOccurrenceTable.maximumBytes)
        XCTAssertThrowsError(try CoOccurrenceTable(data: Data(#"{"v":2,"k":20,"pairs":{}}"#.utf8)).validated())
        XCTAssertThrowsError(try CoOccurrenceTable(data: Data(#"{"v":1,"k":19,"pairs":{}}"#.utf8)).validated())
        XCTAssertThrowsError(try CoOccurrenceTable(data: oversized))
        XCTAssertThrowsError(try CoOccurrenceTable(data: Data("bad".utf8)))
        XCTAssertThrowsError(try CoOccurrenceTable(data: Data(#"{"v":1,"k":20,"pairs":{"21":[[22]]}}"#.utf8)))

        let now = Date()
        let dir = directory()
        let previous = CoOccurrenceTable(pairs: [21: [[22, 20]]])
        let store = try await store(dir, table: previous, malIDs: [], candidates: [],
                                    now: now.addingTimeInterval(-8 * 86400))
        let refresh = await store.refreshTableIfNeeded(now: now, enabled: { true }, fetch: {
            Data(#"{"v":2,"k":20,"pairs":{}}"#.utf8)
        })
        await refresh?.value
        let retained = await store.table()
        XCTAssertEqual(retained, previous)
    }

    func testRailNeverWaits() async throws {
        let seed = work(21)
        let now = Date()
        let dir = directory()
        // Both caches are out of date by the reopened store's clock, so both refreshes run.
        _ = try await self.store(dir, table: CoOccurrenceTable(pairs: [21: [[22, 20]]]),
                                 malIDs: [], candidates: [], now: now.addingTimeInterval(-8 * 86400))
        let store = CoOccurrenceStore(directory: dir, clock: { now })
        let provider = CoOccurrenceCandidateProvider(isEnabled: { true }, fetchTable: {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return nil
        }, loadWorks: { [seed] }, titles: { _ in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return []
        },
            resolve: { _ in [:] }, store: store)
        let start = Date()
        let result = try await provider.candidates(for: profile(seed), excluding: [], limit: 10)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(result.isEmpty)
    }

    func testScoresBySeedWeightAndPosition() async throws {
        let now = Date()
        let first = work(21)
        let second = work(22)
        let dir = directory()
        let table = CoOccurrenceTable(pairs: [21: [[30, 20], [31, 20]], 22: [[31, 20]]])
        let cache = try await store(dir, table: table, malIDs: [30, 31], candidates: [manga(30), manga(31)], now: now)
        let weights = [first.id: 2.0, second.id: 1.0]
        let profile = TasteProfile(weights: [:], tagName: [:], orderedTagKeys: [], taggedMangaCount: 0,
                                   seeds: [], workWeights: weights)
        let provider = CoOccurrenceCandidateProvider(isEnabled: { true }, fetchTable: { nil },
            loadWorks: { [first, second] }, titles: { _ in [] }, resolve: { _ in [:] }, store: cache)
        let result = try await provider.candidates(for: profile, excluding: [], limit: 10)
        XCTAssertEqual(result.map(\.manga.malId), [30, 31])
        XCTAssertEqual(result.map(\.score), [2.0, 2.0])
        try? FileManager.default.removeItem(at: dir)
    }

    func testResolutionFailureWritesNothing() async throws {
        let dir = directory()
        let store = CoOccurrenceStore(directory: dir)
        let task = await store.refreshPoolIfNeeded(malIDs: [22], enabled: { true },
            titles: { _ in throw AniListError.notFound }, resolve: { _ in [:] })
        await task?.value
        let record = await store.pool(malIDs: [22])
        XCTAssertNil(record)
    }

    func testPoolExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let table = CoOccurrenceTable(pairs: [:])
        let full = try await store(directory(), table: table, malIDs: [22], candidates: [manga(22)], now: now)
        let empty = try await store(directory(), table: table, malIDs: [22], candidates: [], now: now)
        for (store, hours, fresh) in [(full, 13.9 * 24, true), (full, 14.1 * 24, false),
                                      (empty, 23.9, true), (empty, 24.1, false)] {
            let record = await store.pool(malIDs: [22], now: now.addingTimeInterval(hours * 3600))
            XCTAssertEqual(record != nil, fresh, "after \(hours) h")
        }
    }

    func testASuccessfulTableIsKeptForSevenDays() async throws {
        let dir = directory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = CoOccurrenceStore(directory: dir, clock: { now })
        let body = Data(#"{"v":1,"k":20,"pairs":{}}"#.utf8)
        await store.refreshTableIfNeeded(enabled: { true }, fetch: { body })?.value
        let reopened = CoOccurrenceStore(directory: dir, clock: { now })
        let early = await reopened.refreshTableIfNeeded(now: now.addingTimeInterval(6.9 * 86400),
                                                        enabled: { true }, fetch: { body })
        XCTAssertNil(early)
        let due = await reopened.refreshTableIfNeeded(now: now.addingTimeInterval(7.1 * 86400),
                                                      enabled: { true }, fetch: { body })
        XCTAssertNotNil(due)
        await due?.value
    }

    func testPoolResolutionStopsWhenConsentIsWithdrawn() async throws {
        for answers in [[false], [true, false], [true, true, false]] {
            let dir = directory()
            let store = CoOccurrenceStore(directory: dir)
            let consent = TestConsentSequence(answers)
            let asked = TestCounter()
            let resolved = TestCounter()
            await store.refreshPoolIfNeeded(malIDs: [22], enabled: { await consent.next() }, titles: { _ in
                await asked.add(1)
                return []
            }, resolve: { _ in
                await resolved.add(1)
                return [22: self.manga(22)]
            })?.value
            let askedCount = await asked.value
            let resolvedCount = await resolved.value
            XCTAssertEqual(askedCount, answers.count > 1 ? 1 : 0)
            XCTAssertEqual(resolvedCount, answers.count > 2 ? 1 : 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cooccurrence-pool.json").path))
        }
    }

}

final class CoOccurrenceTransportTests: XCTestCase {
    @MainActor
    func testRequestShape() async throws {
        CoOccurrenceTransportStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoOccurrenceTransportStub.self]
        let transport = URLSessionAnalyticsTransport(host: "analytics.example.test", configuration: config)
        CoOccurrenceTransportStub.statusCode = 200
        CoOccurrenceTransportStub.responseBody = Data(#"{"v":1,"k":20,"pairs":{}}"#.utf8)
        let accepted = await transport.fetchCoOccurrenceTable()
        XCTAssertNotNil(accepted)
        let request = try XCTUnwrap(CoOccurrenceTransportStub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://analytics.example.test/v1/cooccurrence-v1.json")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(request.url!.absoluteString.contains("install"))
        CoOccurrenceTransportStub.statusCode = 404
        let rejected = await transport.fetchCoOccurrenceTable()
        XCTAssertNil(rejected)
        CoOccurrenceTransportStub.statusCode = 200
        CoOccurrenceTransportStub.responseBody = Data(repeating: 1, count: CoOccurrenceTable.maximumBytes + 1)
        let oversized = await transport.fetchCoOccurrenceTable()
        XCTAssertNil(oversized)
    }
}

private final class CoOccurrenceTransportStub: URLProtocol {
    static var statusCode = 200
    static var responseBody = Data()
    static var requests: [URLRequest] = []

    static func reset() {
        statusCode = 200
        responseBody = Data()
        requests = []
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor TestCounter {
    private(set) var value = 0

    func add(_ amount: Int) {
        value += amount
    }
}

private actor TestConsentSequence {
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        values.isEmpty ? false : values.removeFirst()
    }
}
