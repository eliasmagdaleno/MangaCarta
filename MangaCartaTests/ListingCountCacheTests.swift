//
//  ListingCountCacheTests.swift
//  MangaCartaTests
//
//  ADR-0004's counts: "cache with a ~24h TTL". Disposable by construction — losing
//  the file costs one recount, so it lives in `Caches/` rather than beside the
//  authoritative stores in Application Support (WorkStore says so out loud).
//

import XCTest
@testable import MangaCarta

@MainActor
final class ListingCountCacheTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = makeTestDirectory("ListingCountCacheTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let listing = ListingKey(sourceId: "mangadex", mangaId: "one-piece")

    /// The whole point of the cache: a count recorded is a count the router can
    /// rank on without a network round-trip.
    func testRecordedCountReadsBack() {
        let cache = ListingCountCache(directory: directory)
        let now = Date()

        cache.record(201, for: listing, now: now)

        XCTAssertEqual(cache.count(for: listing, now: now), 201)
    }

    /// ADR-0004's "~24h TTL". A stale count reads as **unknown**, not as the old
    /// number — the router's uncounted tier exists precisely so a Listing we have
    /// no current evidence about is treated as un-counted rather than as fact.
    func testACountOlderThanTheTTLReadsAsUnknown() {
        let cache = ListingCountCache(directory: directory)
        let counted = Date()

        cache.record(201, for: listing, now: counted)

        let later = counted.addingTimeInterval(ListingCountCache.ttl + 1)
        XCTAssertNil(cache.count(for: listing, now: later))
    }

    /// The boundary, stated so a later refactor cannot quietly move it: a count is
    /// good right up until the TTL elapses.
    func testACountInsideTheTTLIsStillGood() {
        let cache = ListingCountCache(directory: directory)
        let counted = Date()

        cache.record(201, for: listing, now: counted)

        let later = counted.addingTimeInterval(ListingCountCache.ttl - 1)
        XCTAssertEqual(cache.count(for: listing, now: later), 201)
    }

    /// A cache that dies with the process would put a spinner in front of every
    /// detail page on every launch, which is the exact failure ADR-0004 rejects.
    func testCountsSurviveANewInstanceOnTheSameDirectory() {
        let now = Date()
        ListingCountCache(directory: directory).record(201, for: listing, now: now)

        let reopened = ListingCountCache(directory: directory)

        XCTAssertEqual(reopened.count(for: listing, now: now), 201)
    }

    /// `Caches/` can be emptied by the system at any time, and on a real device it
    /// will be. Losing the file must cost one recount, not a crash or a wrong
    /// answer — so an absent file reads as an empty cache.
    func testAMissingFileReadsAsAnEmptyCache() {
        let cache = ListingCountCache(directory: directory.appendingPathComponent("gone"))

        XCTAssertNil(cache.count(for: listing))
    }
}
