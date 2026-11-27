import XCTest
@testable import MangaCarta

private final class LocalMatchDelivery: MALProgressDelivering, @unchecked Sendable {
    func listStatus(mangaID: Int) async throws -> MALListStatus? { nil }
    func updateProgress(mangaID: Int, update: MALListStatusUpdate) async throws -> MALListStatus {
        MALListStatus(status: "reading", numChaptersRead: update.numChaptersRead)
    }
}

@MainActor private final class LocalMatchAccount: MALSyncAccount {
    var syncUserID: Int? = 7
    var syncEnabled = true
    var automaticallyAddsTitles = true
    func reauthorizationRequired() {}
    func syncActivityChanged(skipped: Int) {}
}

final class LocalMatchingCoordinatorTests: XCTestCase {
    func testLocalEvidenceUsesTitlesNotChapterNumbers() {
        let item = LocalItemRecord(itemId: "x", title: "ignored", sourceFilename: "Series_12.cbz",
                                   sha256: "", byteSize: 1, importedAt: Date(), chapters: [],
                                   comicInfo: ComicInfo(series: " Series ", title: "Chapter 12", number: "12",
                                                        volume: "3", summary: nil, writer: nil, genres: [],
                                                        frontCoverPageIndex: nil))
        XCTAssertEqual(LocalTitleEvidence(items: [item]).titles, ["Series", "Chapter 12", "Series 12"])
    }

    func testEvidenceDeduplicatesAndKeepsOrder() {
        let item = LocalItemRecord(itemId: "x", title: "", sourceFilename: "Series.cbz", sha256: "",
                                   byteSize: 1, importedAt: Date(), chapters: [],
                                   comicInfo: ComicInfo(series: "Series", title: "Series", number: "1", volume: "1",
                                                        summary: nil, writer: nil, genres: [], frontCoverPageIndex: nil))
        XCTAssertEqual(LocalTitleEvidence(items: [item]).titles, ["Series"])
    }

    @MainActor func testCancelledCombineDoesNotWrite() {
        let dir = makeTestDirectory("LocalMatchCancel")
        let works = WorkStore(directory: dir)
        let incumbent = works.mint(from: manga("inc", mal: 41))
        let local = works.mint(from: manga("local", source: LocalSource.sourceID))
        let store = LocalMatchStore(directory: dir)
        let progress = progressCoordinator(outbox: MALProgressOutbox(directory: dir))
        let coordinator = LocalMatchingCoordinator(works: works, matches: store, progress: progress,
                                                   metadataChanged: { _ in XCTFail("must not notify") })
        guard case .combineRequired(let owner, let warning) = coordinator.confirm(
            localWorkID: local, ids: ExternalIDs(mal: 41, anilist: nil)) else {
            return XCTFail("expected combine decision")
        }
        XCTAssertEqual(owner, incumbent)
        XCTAssertTrue(warning.contains("can't be undone"))
        XCTAssertNil(store.record(for: local))
        XCTAssertNil(works.work(local)?.externalIds.mal)
        XCTAssertEqual(works.work(incumbent)?.listings, [ListingKey(manga("inc", mal: 41))])
    }

    @MainActor func testUnmatchPreservesLocalData() {
        let dir = makeTestDirectory("LocalMatchUnmatch")
        let works = WorkStore(directory: dir)
        let local = manga("local", source: LocalSource.sourceID)
        let id = works.mint(from: local)
        let store = LocalMatchStore(directory: dir)
        let coordinator = LocalMatchingCoordinator(works: works, matches: store,
                                                   progress: progressCoordinator(outbox: MALProgressOutbox(directory: dir)),
                                                   metadataChanged: { _ in })
        _ = coordinator.confirm(localWorkID: id, ids: ExternalIDs(mal: 51, anilist: nil))
        XCTAssertNil(coordinator.unmatch(workID: id))
        XCTAssertEqual(works.work(id)?.listings, [ListingKey(local)])
        XCTAssertNil(works.work(id)?.externalIds.mal)
        XCTAssertEqual(store.record(for: id)?.status, .unmatched)
    }

    @MainActor func testConfirmPostsMetadataChangeForCanonicalSurvivor() {
        let dir = makeTestDirectory("LocalMatchMetadataChanged")
        let works = WorkStore(directory: dir)
        let incumbent = works.mint(from: manga("incumbent", mal: 52))
        let local = works.mint(from: manga("local", source: LocalSource.sourceID))
        let coordinator = LocalMatchingCoordinator(works: works, matches: LocalMatchStore(directory: dir),
            progress: progressCoordinator(outbox: MALProgressOutbox(directory: dir)),
            metadataChanged: { XCTAssertEqual($0, incumbent) })
        XCTAssertEqual(coordinator.confirm(localWorkID: local,
            ids: ExternalIDs(mal: 52, anilist: nil), combine: true), .confirmed(incumbent))
        XCTAssertEqual(LocalMatchStore(directory: dir).record(for: incumbent)?.status, .confirmed)
    }

    @MainActor func testConfirmPromotesDeferredProgressThroughMergedAlias() throws {
        let dir = makeTestDirectory("LocalMatchProgressPromotion")
        let works = WorkStore(directory: dir)
        let incumbent = works.mint(from: manga("incumbent", mal: 92))
        let local = works.mint(from: manga("local", source: LocalSource.sourceID))
        let outbox = MALProgressOutbox(directory: dir)
        try outbox.defer(userID: 7, workID: local, desiredProgress: 7, completedAt: Date())
        let progress = MALProgressCoordinator(outbox: outbox, client: LocalMatchDelivery(),
            account: LocalMatchAccount(), malID: { works.work($0)?.externalIds.mal },
            canonicalWorkID: { works.canonicalWorkID($0) })
        let coordinator = LocalMatchingCoordinator(works: works, matches: LocalMatchStore(directory: dir),
            progress: progress, metadataChanged: { _ in })
        XCTAssertEqual(coordinator.confirm(localWorkID: local,
            ids: ExternalIDs(mal: 92, anilist: nil), combine: true), .confirmed(incumbent))
        XCTAssertEqual(outbox.summary(userID: 7).deferred, 0)
        XCTAssertEqual(outbox.nextEligible(userID: 7, at: .distantFuture)?.mangaID, 92)
        XCTAssertEqual(outbox.nextEligible(userID: 7, at: .distantFuture)?.desiredProgress, 7)
    }

    @MainActor func testUnmatchAfterMergeDoesNotSplitWorks() {
        let dir = makeTestDirectory("LocalMatchMergedUnmatch")
        let works = WorkStore(directory: dir)
        let incumbentListing = manga("inc", mal: 61)
        let localListing = manga("local", source: LocalSource.sourceID)
        let incumbent = works.mint(from: incumbentListing)
        let local = works.mint(from: localListing)
        let store = LocalMatchStore(directory: dir)
        let coordinator = LocalMatchingCoordinator(works: works, matches: store,
                                                   progress: progressCoordinator(outbox: MALProgressOutbox(directory: dir)),
                                                   metadataChanged: { _ in })
        guard case .confirmed(let survivor) = coordinator.confirm(localWorkID: local,
            ids: ExternalIDs(mal: 61, anilist: nil), combine: true) else { return XCTFail("confirmation failed") }
        XCTAssertEqual(survivor, incumbent)
        XCTAssertNil(coordinator.unmatch(workID: local))
        XCTAssertEqual(works.work(local)?.id, incumbent)
        XCTAssertEqual(Set(works.work(incumbent)?.listings ?? []), Set([ListingKey(incumbentListing), ListingKey(localListing)]))
        XCTAssertNil(works.work(incumbent)?.externalIds.mal)
    }

    @MainActor func testFailedMatchDoesNotPersistPartialIdentity() {
        let dir = makeTestDirectory("LocalMatchFailure")
        let works = WorkStore(directory: dir)
        let local = manga("local", source: LocalSource.sourceID)
        let id = works.mint(from: local)
        let store = LocalMatchStore(directory: dir)
        let coordinator = LocalMatchingCoordinator(works: works, matches: store,
            progress: progressCoordinator(outbox: MALProgressOutbox(directory: dir)),
            sourceAvailable: { _ in false }, metadataChanged: { _ in XCTFail("must not notify") })
        let remote = manga("remote", source: "disabled")
        guard case .failed = coordinator.confirm(localWorkID: id,
            ids: ExternalIDs(mal: 70, anilist: nil), remoteListing: remote) else { return XCTFail("expected retryable error") }
        XCTAssertNil(store.record(for: id))
        XCTAssertNil(works.work(id)?.externalIds.mal)
        XCTAssertFalse(works.work(id)?.listings.contains(ListingKey(remote)) ?? true)
    }

    @MainActor private func progressCoordinator(outbox: MALProgressOutbox) -> MALProgressCoordinator {
        MALProgressCoordinator(outbox: outbox, client: LocalMatchDelivery(), account: LocalMatchAccount(),
                               malID: { _ in nil })
    }

    private func manga(_ id: String, source: String = "mangadex", mal: Int? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: id, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: mal)
    }
}
