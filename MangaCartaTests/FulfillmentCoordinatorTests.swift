//
//  FulfillmentCoordinatorTests.swift
//  MangaCartaTests
//
//  ADR-0004's "optimistic render, then reconcile": choose from cached counts and
//  paint at once; refresh the counts in the background. First paint never blocks
//  on N sources.
//

import XCTest
@testable import MangaCarta

@MainActor
final class FulfillmentCoordinatorTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = makeTestDirectory("FulfillmentCoordinatorTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func listing(_ sourceId: String, _ mangaId: String) -> Manga {
        Manga(id: mangaId, sourceId: sourceId, title: "One Piece", description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: nil)
    }

    /// Builds a Work carrying both Listings, the way two sources converging on one
    /// manga leaves it.
    private func workWithBothListings(_ works: WorkStore) -> WorkID {
        let first = works.mint(from: listing("mangadex", "op"))
        let second = works.mint(from: listing("weebcentral", "one-piece"))
        works.merge(second, into: first)
        return first
    }

    /// The optimistic render: everything the detail page needs to pick a Listing is
    /// already on hand, so this must answer from the cache alone.
    func testCandidatesComeBackRankedFromCachedCountsAlone() {
        let works = WorkStore(directory: directory)
        let counts = ListingCountCache(directory: directory)
        let registry = SourceRegistry(sources: [StubCountingSource(id: "mangadex"),
                                                StubCountingSource(id: "weebcentral")])
        let workID = workWithBothListings(works)

        counts.record(40, for: ListingKey(sourceId: "mangadex", mangaId: "op"))
        counts.record(120, for: ListingKey(sourceId: "weebcentral", mangaId: "one-piece"))

        let coordinator = FulfillmentCoordinator(
            works: works, registry: registry, counts: counts,
            preferences: SourcePreferenceStore(
                defaults: makeTestDefaults("FulfillmentCoordinatorTests"), works: works))

        XCTAssertEqual(coordinator.candidates(for: workID).map(\.key.sourceId),
                       ["weebcentral", "mangadex"])
    }

    // MARK: - Preferences

    private func coordinator(_ works: WorkStore,
                             _ registry: SourceRegistry,
                             _ counts: ListingCountCache,
                             _ preferences: SourcePreferenceStore) -> FulfillmentCoordinator {
        FulfillmentCoordinator(works: works, registry: registry, counts: counts,
                               preferences: preferences)
    }

    /// The pieces a preference test needs, as a named bag rather than a tuple --
    /// five members is past the point where positional destructuring reads.
    private struct Setup {
        let works: WorkStore
        let registry: SourceRegistry
        let counts: ListingCountCache
        let preferences: SourcePreferenceStore
        let workID: WorkID
    }

    private func standardSetup() -> Setup {
        let works = WorkStore(directory: directory)
        let registry = SourceRegistry(sources: [StubCountingSource(id: "mangadex"),
                                                StubCountingSource(id: "weebcentral")])
        return Setup(works: works,
                     registry: registry,
                     counts: ListingCountCache(directory: directory),
                     preferences: SourcePreferenceStore(
                        defaults: makeTestDefaults("FulfillmentCoordinatorTests"), works: works),
                     workID: workWithBothListings(works))
    }

    /// The reader's primary source settles the tie, in place of MangaDex.
    func testThePrimarySourceDecidesTiesInTheRanking() {
        let setup = standardSetup()
        setup.counts.record(120, for: ListingKey(sourceId: "mangadex", mangaId: "op"))
        setup.counts.record(120, for: ListingKey(sourceId: "weebcentral", mangaId: "one-piece"))
        setup.preferences.primarySourceId = "weebcentral"

        let coordinator = coordinator(setup.works, setup.registry, setup.counts, setup.preferences)

        XCTAssertEqual(coordinator.candidates(for: setup.workID).first?.key.sourceId,
                       "weebcentral")
    }

    /// A per-title pick beats the ranking outright. The reader looked at this manga
    /// and chose; the app must not talk them out of it because a count moved.
    func testAPerWorkChoiceDecidesWhatOpensEvenWhenRankedLower() {
        let setup = standardSetup()
        setup.counts.record(400, for: ListingKey(sourceId: "mangadex", mangaId: "op"))
        setup.counts.record(10, for: ListingKey(sourceId: "weebcentral", mangaId: "one-piece"))

        let chosen = ListingKey(sourceId: "weebcentral", mangaId: "one-piece")
        setup.preferences.choose(chosen, for: setup.workID)

        XCTAssertEqual(coordinator(setup.works, setup.registry, setup.counts, setup.preferences)
            .chosenListing(for: setup.workID), chosen)
    }

    /// Without a pick, the ranking decides — the ordinary case.
    func testWithoutAChoiceTheRankingDecidesWhatOpens() {
        let setup = standardSetup()
        setup.counts.record(400, for: ListingKey(sourceId: "mangadex", mangaId: "op"))
        setup.counts.record(10, for: ListingKey(sourceId: "weebcentral", mangaId: "one-piece"))

        XCTAssertEqual(coordinator(setup.works, setup.registry, setup.counts, setup.preferences)
            .chosenListing(for: setup.workID)?.sourceId, "mangadex")
    }

    /// A pinned Listing whose source is gone — the reader deleted the extension, or
    /// adult gating hid it — must not strand the Work on a dead end. The ranking
    /// takes over, and the pin is left alone in case the source comes back.
    func testAChoiceOnAnUnregisteredSourceFallsBackToTheRanking() {
        let setup = standardSetup()
        let mangaDexOnly = SourceRegistry(sources: [StubCountingSource(id: "mangadex")])
        setup.counts.record(400, for: ListingKey(sourceId: "mangadex", mangaId: "op"))
        setup.preferences.choose(ListingKey(sourceId: "weebcentral", mangaId: "one-piece"),
                           for: setup.workID)

        let chosen = coordinator(setup.works, mangaDexOnly, setup.counts, setup.preferences)
            .chosenListing(for: setup.workID)

        XCTAssertEqual(chosen?.sourceId, "mangadex")
    }

    /// The reconcile half: counts every Listing nobody has counted, caches the
    /// result, and so changes the ranking the next render reads.
    func testReconcileCountsUncountedListingsAndRanksOnTheResult() async {
        let works = WorkStore(directory: directory)
        let counts = ListingCountCache(directory: directory)
        let registry = SourceRegistry(sources: [
            StubCountingSource(id: "mangadex", chapterNumbers: ["1", "2"]),
            StubCountingSource(id: "weebcentral", chapterNumbers: ["1", "2", "3", "4"])
        ])
        let workID = workWithBothListings(works)
        let coordinator = FulfillmentCoordinator(
            works: works, registry: registry, counts: counts,
            preferences: SourcePreferenceStore(
                defaults: makeTestDefaults("FulfillmentCoordinatorTests"), works: works))

        await coordinator.reconcile(workID)

        XCTAssertEqual(coordinator.candidates(for: workID).map(\.key.sourceId),
                       ["weebcentral", "mangadex"])
        XCTAssertEqual(counts.count(for: ListingKey(sourceId: "mangadex", mangaId: "op")), 2)
    }

    /// The cost guarantee. A reconcile that re-counted everything on every detail
    /// page would be the eager strategy ADR-0004 rejects — network, battery and rate
    /// limit spent on counts we already have.
    func testReconcileDoesNotRecountAListingAlreadyCached() async {
        let works = WorkStore(directory: directory)
        let counts = ListingCountCache(directory: directory)
        let mangadex = StubCountingSource(id: "mangadex", chapterNumbers: ["1", "2"])
        let weebcentral = StubCountingSource(id: "weebcentral", chapterNumbers: ["1"])
        let registry = SourceRegistry(sources: [mangadex, weebcentral])
        let workID = workWithBothListings(works)

        counts.record(2, for: ListingKey(sourceId: "mangadex", mangaId: "op"))

        let coordinator = FulfillmentCoordinator(
            works: works, registry: registry, counts: counts,
            preferences: SourcePreferenceStore(
                defaults: makeTestDefaults("FulfillmentCoordinatorTests"), works: works))
        await coordinator.reconcile(workID)

        let askedMangaDex = await mangadex.asked.ids
        let askedWeebCentral = await weebcentral.asked.ids
        XCTAssertEqual(askedMangaDex, [])
        XCTAssertEqual(askedWeebCentral, ["one-piece"])
    }

    /// Per-Listing failure isolation, the same shape as `LibraryStore.refresh`.
    /// One source being down — a Cloudflare challenge, a redesign, an outage — must
    /// not cost the counts of the sources that answered.
    func testOneSourceFailingLeavesTheOtherListingCounted() async {
        let works = WorkStore(directory: directory)
        let counts = ListingCountCache(directory: directory)
        let registry = SourceRegistry(sources: [
            StubCountingSource(id: "mangadex", failing: true),
            StubCountingSource(id: "weebcentral", chapterNumbers: ["1", "2", "3"])
        ])
        let workID = workWithBothListings(works)
        let coordinator = FulfillmentCoordinator(
            works: works, registry: registry, counts: counts,
            preferences: SourcePreferenceStore(
                defaults: makeTestDefaults("FulfillmentCoordinatorTests"), works: works))

        await coordinator.reconcile(workID)

        XCTAssertEqual(counts.count(for: ListingKey(sourceId: "weebcentral",
                                                    mangaId: "one-piece")), 3)
        XCTAssertNil(counts.count(for: ListingKey(sourceId: "mangadex", mangaId: "op")),
                     "a source that could not answer must stay uncounted, not be recorded as zero")
    }
}

/// A source that reports a fixed chapter list and records what it was asked for, so
/// a test can tell an answered-from-cache render from one that hit the network.
private struct StubCountingSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    let chapterNumbers: [String]
    let failing: Bool
    let asked = AskedIds()

    init(id: String, chapterNumbers: [String] = [], failing: Bool = false) {
        self.id = id
        self.chapterNumbers = chapterNumbers
        self.failing = failing
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        await asked.record(mangaId)
        if failing { throw URLError(.timedOut) }
        return chapterNumbers.map {
            Chapter(id: UUID().uuidString, number: $0, title: nil, date: nil)
        }
    }

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

private actor AskedIds {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}
