import Foundation
import Testing
@testable import MangaCarta

@Suite("Update state store")
struct UpdateStateStoreTests {
    @MainActor
    @Test("The first successful observation establishes a silent baseline")
    func firstObservationIsBaseline() {
        let fixture = fixture()

        let released = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                    rawNumbers: ["1", "2"], now: date(1))

        #expect(released.isEmpty)
        #expect(fixture.updates.state(for: fixture.workId)?.hasBaseline == true)
        #expect(fixture.updates.state(for: fixture.workId)?.newlyDiscovered.isEmpty == true)
    }

    @MainActor
    @Test("A later chapter is emitted and retained for presentation")
    func secondObservationEmitsRelease() {
        let fixture = fixture()
        _ = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                   rawNumbers: ["1"], now: date(1))

        let released = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                    rawNumbers: ["1", "2"], now: date(2))

        #expect(released == [ordinal("2")])
        #expect(fixture.updates.state(for: fixture.workId)?.newlyDiscovered == [ordinal("2")])
        #expect(fixture.updates.state(for: fixture.workId)?.newestDiscoveryAt == date(2))
    }

    @MainActor
    @Test("Forgetting then re-adding establishes a new baseline")
    func forgettingRebaselines() {
        let fixture = fixture()
        _ = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                   rawNumbers: ["1"], now: date(1))
        let identifier = fixture.updates.forget(workId: fixture.workId)

        let released = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                    rawNumbers: ["1", "2"], now: date(2))

        #expect(identifier == "work-\(fixture.workId.raw.uuidString)")
        #expect(released.isEmpty)
    }

    @MainActor
    @Test("Muting retains the frontier and newly discovered chapters")
    func mutingRetainsState() throws {
        let fixture = fixture()
        _ = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                   rawNumbers: ["1"], now: date(1))
        _ = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                   rawNumbers: ["2"], now: date(2))
        let before = try #require(fixture.updates.state(for: fixture.workId))

        fixture.updates.setMuted(true, workId: fixture.workId)

        let after = try #require(fixture.updates.state(for: fixture.workId))
        #expect(after.isMuted)
        #expect(after.frontier == before.frontier)
        #expect(after.newlyDiscovered == before.newlyDiscovered)
    }

    @MainActor
    @Test("Listing backoff doubles and a success clears it")
    func backoffDoublesAndClears() throws {
        let fixture = fixture()
        fixture.updates.recordFailure(workId: fixture.workId, listing: fixture.listing, now: date(0))
        let first = try #require(fixture.updates.state(for: fixture.workId)?.listings[fixture.listing])
        fixture.updates.recordFailure(workId: fixture.workId, listing: fixture.listing, now: date(10))
        let second = try #require(fixture.updates.state(for: fixture.workId)?.listings[fixture.listing])

        #expect(first.blockedUntil == date(0).addingTimeInterval(2 * UpdateTuning.backoffBase))
        #expect(second.blockedUntil == date(10).addingTimeInterval(4 * UpdateTuning.backoffBase))

        _ = fixture.updates.absorb(workId: fixture.workId, listing: fixture.listing,
                                   rawNumbers: ["1"], now: date(20))
        let cleared = try #require(fixture.updates.state(for: fixture.workId)?.listings[fixture.listing])
        #expect(cleared.consecutiveFailures == 0)
        #expect(cleared.blockedUntil == nil)
    }

    @MainActor
    @Test("Flushed state survives a JSON round trip")
    func jsonRoundTrip() {
        let directory = temporaryDirectory()
        let works = WorkStore(directory: directory)
        let listing = ListingKey(sourceId: "mangadex", mangaId: "roundtrip")
        let workId = works.mint(from: manga(listing))
        let first = UpdateStateStore(directory: directory, works: works)
        _ = first.absorb(workId: workId, listing: listing, rawNumbers: ["1"], now: date(1))
        _ = first.absorb(workId: workId, listing: listing, rawNumbers: ["2", "Extra"], now: date(2))
        first.setMuted(true, workId: workId)
        first.flush()

        let reloaded = UpdateStateStore(directory: directory, works: works)

        #expect(reloaded.state(for: workId) == first.state(for: workId))
    }

    @MainActor
    @Test("An empty directory behaves as no update state")
    func emptyDirectoryIsEmpty() {
        let store = UpdateStateStore(directory: temporaryDirectory())
        #expect(store.state(for: WorkID()) == nil)
    }

    @MainActor
    @Test("A synthesized legacy updates blob loads without losing any state")
    func synthesizedLegacyBlobLoadsWithoutLosingState() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let listing = ListingKey(sourceId: "mangadex", mangaId: "legacy")
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let blob = """
        {
          "records": [{
            "workId": {"raw": "\(workID.uuidString)"},
            "state": {
              "frontier": {
                "known": [{"value": 0.07000000000000001}],
                "max": {"value": 0.07000000000000001},
                "unnumbered": ["Extra"]
              },
              "hasBaseline": true,
              "newlyDiscovered": [{"value": 0.07000000000000001}],
              "newestDiscoveryAt": 1700000000,
              "lastSuccessfulCheck": 1700000001,
              "isMuted": true,
              "listings": [
                {"sourceId": "\(listing.sourceId)", "mangaId": "\(listing.mangaId)"},
                {"lastSuccess": 1700000000, "lastFailure": 1700000002,
                 "consecutiveFailures": 3, "blockedUntil": 1700000010}
              ]
            }
          }],
          "refreshCursor": {"raw": "\(workID.uuidString)"}
        }
        """
        try Data(blob.utf8).write(to: directory.appendingPathComponent("updates.json"))

        let store = UpdateStateStore(directory: directory)
        let state = try #require(store.state(for: WorkID(raw: workID)))

        #expect(state.frontier.known == [ordinal("0.07")])
        #expect(state.frontier.max == ordinal("0.07"))
        #expect(state.frontier.unnumbered == ["Extra"])
        #expect(state.hasBaseline)
        #expect(state.newlyDiscovered == [ordinal("0.07")])
        #expect(state.newestDiscoveryAt == timestamp)
        #expect(state.lastSuccessfulCheck == timestamp.addingTimeInterval(1))
        #expect(state.isMuted)
        #expect(state.listings[listing]?.consecutiveFailures == 3)
        #expect(state.listings[listing]?.lastFailure == timestamp.addingTimeInterval(2))
        #expect(store.refreshCursor == WorkID(raw: workID))
    }

    @MainActor
    @Test("Reconciliation unions a real WorkStore merge without emitting")
    func reconciliationUnionsMerge() throws {
        let directory = temporaryDirectory()
        let works = WorkStore(directory: directory)
        let winnerListing = ListingKey(sourceId: "mangadex", mangaId: "winner")
        let loserListing = ListingKey(sourceId: "weebcentral", mangaId: "loser")
        let winner = works.mint(from: manga(winnerListing))
        let loser = works.mint(from: manga(loserListing))
        let updates = UpdateStateStore(directory: directory, works: works)
        _ = updates.absorb(workId: winner, listing: winnerListing, rawNumbers: ["1"], now: date(1))
        _ = updates.absorb(workId: winner, listing: winnerListing, rawNumbers: ["2"], now: date(2))
        _ = updates.absorb(workId: loser, listing: loserListing, rawNumbers: ["1", "3"], now: date(3))
        _ = updates.absorb(workId: loser, listing: loserListing, rawNumbers: ["4"], now: date(4))
        works.merge(loser, into: winner)

        updates.reconcileMerges(using: works)
        let merged = try #require(updates.state(for: winner))

        #expect(updates.state(for: loser) == nil)
        #expect(merged.frontier.known == [ordinal("1"), ordinal("2"), ordinal("3"), ordinal("4")])
        #expect(merged.newlyDiscovered == [ordinal("2"), ordinal("4")])
        let once = merged
        updates.reconcileMerges(using: works)
        #expect(updates.state(for: winner) == once)
    }

    @MainActor
    @Test("Reconciliation drops state for a Work that no longer resolves")
    func reconciliationDropsMissingWork() {
        let directory = temporaryDirectory()
        let works = WorkStore(directory: directory)
        let updates = UpdateStateStore(directory: directory)
        let missing = WorkID()
        let listing = ListingKey(sourceId: "mangadex", mangaId: "missing")
        _ = updates.absorb(workId: missing, listing: listing, rawNumbers: ["1"], now: date(1))

        updates.reconcileMerges(using: works)

        #expect(updates.state(for: missing) == nil)
    }

    @MainActor
    private func fixture() -> Fixture {
        let directory = temporaryDirectory()
        let works = WorkStore(directory: directory)
        let listing = ListingKey(sourceId: "mangadex", mangaId: UUID().uuidString)
        let workId = works.mint(from: manga(listing))
        return Fixture(updates: UpdateStateStore(directory: directory, works: works),
                       workId: workId,
                       listing: listing)
    }

    private func manga(_ listing: ListingKey) -> Manga {
        Manga(id: listing.mangaId, sourceId: listing.sourceId, title: listing.mangaId,
              description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateStateStoreTests-\(UUID().uuidString)")
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func ordinal(_ raw: String) -> ChapterOrdinal {
        ChapterOrdinal.parse(raw) ?? ChapterOrdinal(value: 0)
    }
}

private struct Fixture {
    let updates: UpdateStateStore
    let workId: WorkID
    let listing: ListingKey
}
