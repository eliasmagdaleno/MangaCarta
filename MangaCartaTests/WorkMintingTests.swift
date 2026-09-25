//
//  WorkMintingTests.swift
//  MangaCartaTests
//
//  Slice 3 of ADR-0007: minting at the commitment points. A Work comes into
//  existence when the user commits to a manga — reads it, saves it, or gives it
//  explicit feedback — and never from browsing (ADR-0007, "Minting").
//
//  These tests pin the *wiring*: that each commitment path reaches `WorkStore`.
//  `WorkStoreTests` covers what minting itself does.
//

import XCTest
@testable import MangaCarta

final class WorkMintingTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeWorkStore() -> WorkStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkMintingTests-\(UUID().uuidString)")
        return WorkStore(directory: dir)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.minting.\(UUID().uuidString)")!
    }

    /// A Listing. `Manga` *is* a Listing despite the name (ADR-0001).
    private func listing(_ id: String,
                         source: String = "weebcentral",
                         title: String = "Untitled",
                         malId: Int? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: title, description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: malId)
    }

    // MARK: - Read

    /// The bug ADR-0001 documented: a manga read on a non-MangaDex source was
    /// structurally invisible to the recommender. Minting on the read is the first
    /// half of the fix — the read now has a Work to hang tags off.
    @MainActor
    func testReadingAChapterOnANonMangaDexSourceMintsAWork() throws {
        let works = makeWorkStore()
        let history = HistoryStore(defaults: makeDefaults(), works: works)

        history.record(manga: listing("wc-1", title: "Omniscient Reader"),
                       chapter: Chapter(id: "c1", number: "1", title: nil),
                       position: ReadingPosition(page: 0), pageCount: 20)

        let id = try XCTUnwrap(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-1")))
        XCTAssertEqual(works.work(id)?.displayTitle, "Omniscient Reader")
    }

    /// `record` runs on every page turn, so this is the common case by far.
    @MainActor
    func testReadingTheSameMangaRepeatedlyMintsOneWork() throws {
        let works = makeWorkStore()
        let history = HistoryStore(defaults: makeDefaults(), works: works)
        let orv = listing("wc-1", title: "Omniscient Reader")

        history.record(manga: orv, chapter: Chapter(id: "c1", number: "1", title: nil),
                       position: ReadingPosition(page: 0), pageCount: 20)
        history.record(manga: orv, chapter: Chapter(id: "c1", number: "1", title: nil),
                       position: ReadingPosition(page: 5), pageCount: 20)
        history.record(manga: orv, chapter: Chapter(id: "c2", number: "2", title: nil),
                       position: ReadingPosition(page: 0), pageCount: 18)

        let id = try XCTUnwrap(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-1")))
        XCTAssertEqual(works.work(id)?.listings.count, 1)
    }

    // MARK: - Save

    @MainActor
    func testSavingToTheLibraryMintsAWork() throws {
        let works = makeWorkStore()
        let library = LibraryStore(defaults: makeDefaults(), works: works)

        library.toggle(listing("wc-2", title: "Solo Leveling"))

        let id = try XCTUnwrap(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-2")))
        XCTAssertEqual(works.work(id)?.displayTitle, "Solo Leveling")
    }

    /// Unsaving is not an anti-commitment. The Work records that the user once
    /// cared; the *library* records whether they still do. Deleting the Work would
    /// also throw away external ids and any snapshot the upgrade queue had fetched.
    @MainActor
    func testUnsavingLeavesTheWorkInPlace() {
        let works = makeWorkStore()
        let library = LibraryStore(defaults: makeDefaults(), works: works)
        let solo = listing("wc-2", title: "Solo Leveling")

        library.toggle(solo)
        library.toggle(solo)

        XCTAssertFalse(library.contains("wc-2"))
        XCTAssertNotNil(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-2")))
    }

    /// `toggle` is not the only save-shaped entry point: adding straight to a
    /// collection from the detail sheet skips it entirely.
    @MainActor
    func testAddingToACollectionMintsAWork() {
        let works = makeWorkStore()
        let library = LibraryStore(defaults: makeDefaults(), works: works)

        library.toggleCollection(for: listing("wc-3", title: "Berserk"),
                                 collectionId: LibraryCollection.readingID)

        XCTAssertNotNil(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-3")))
    }

    @MainActor
    func testSettingCollectionsMintsAWork() {
        let works = makeWorkStore()
        let library = LibraryStore(defaults: makeDefaults(), works: works)

        library.setCollections(for: listing("wc-4", title: "Vinland Saga"),
                               collectionIds: [LibraryCollection.readingID])

        XCTAssertNotNil(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-4")))
    }

    /// Clearing every collection removes the item, and must not mint on the way out:
    /// there is no commitment in a removal.
    @MainActor
    func testClearingEveryCollectionDoesNotMint() {
        let works = makeWorkStore()
        let library = LibraryStore(defaults: makeDefaults(), works: works)

        library.setCollections(for: listing("wc-5", title: "Gantz"), collectionIds: [])

        XCTAssertNil(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-5")))
    }

    // MARK: - Feedback

    /// Under Listing-keyed edges, *Not interested* on a MangaDex Listing would not
    /// suppress the same manga surfaced from WeebCentral. Minting on the tap is what
    /// eventually makes suppression cross-source (ADR-0007).
    @MainActor
    func testNotInterestedMintsAWork() {
        let works = makeWorkStore()
        let engine = makeEngine(works: works)

        engine.markNotInterested(listing("wc-6", title: "Gantz"))

        XCTAssertNotNil(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-6")))
    }

    @MainActor
    func testMoreLikeThisMintsAWork() {
        let works = makeWorkStore()
        let engine = makeEngine(works: works)

        engine.markMoreLikeThis(listing("wc-7", title: "Vagabond"))

        XCTAssertNotNil(works.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-7")))
    }

    /// The engine must hand the Work's MAL id to the profile, or every seed arrives at
    /// `MoreLikeThisProvider` as a resolution question the Work already answered — a live
    /// MAL title search per seed, up to five per For You refresh, for an id held since the
    /// Work was minted (ADR-0018).
    ///
    /// Asserted on the profile the **real engine** builds and hands to its provider, not on
    /// `TasteProfile.build` in isolation: the wiring is the part that can silently go
    /// missing, and it is one `?.externalIds.mal` away from doing so.
    @MainActor
    func testTheEngineStampsSeedsWithTheWorksMalId() async throws {
        let works = makeWorkStore()
        let defaults = makeDefaults()
        let history = HistoryStore(defaults: defaults, works: works, saveInterval: 0)

        // Three tagged Works, because the rail refuses to build below the cold-start gate
        // (ADR-0015) and a refusal never reaches the provider. Only the first carries a MAL
        // id; the other two are here to open the gate.
        // **No listing publishes a MAL id.** The id reaches the Work the way the upgrade
        // queue delivers it, so the reading entries carry none — otherwise this passes on
        // `makeSeeds`' entry fallback and says nothing about the engine. (Mutation-checked:
        // with the entry carrying the id, blanking the engine's stamp still passed.)
        let seeded = [("md-death-note", "Death Note"), ("md-berserk", "Berserk"),
                      ("md-vagabond", "Vagabond")]
        for (mangaId, title) in seeded {
            let listing = Manga(id: mangaId, sourceId: "mangadex", title: title,
                                description: "", status: "completed", year: nil,
                                coverURL: nil, malId: nil)
            history.record(manga: listing,
                           chapter: Chapter(id: "\(mangaId)-c1", number: "1", title: nil),
                           position: ReadingPosition(page: 19), pageCount: 20)
            let id = try XCTUnwrap(works.workId(for: ListingKey(sourceId: "mangadex",
                                                               mangaId: mangaId)))
            works.applyProvisionalSnapshot(tags: [Tag(id: "t1", name: "Action", group: "genre")],
                                           to: id)
            if mangaId == "md-death-note" {
                works.apply(AniListWork(anilistId: 30021, malId: 21,
                                        knownTitles: [title], genres: ["Action"], tags: [],
                                        publicationStatus: .finished, chapterTotal: 108),
                            to: id)
            }
        }
        history.flush()

        let capture = CapturingProvider()
        let engine = RecommendationEngine(history: history,
                                          library: LibraryStore(defaults: defaults, works: works),
                                          profileStore: TasteProfileStore(defaults: defaults),
                                          workStore: works,
                                          source: { MockSource() },
                                          makeProvider: { _ in capture })
        await engine.refresh()

        let profile = try XCTUnwrap(capture.seen, "the engine never called its provider")
        let seed = try XCTUnwrap(profile.seeds.first { $0.manga.id == "md-death-note" },
                                 "no seed built from the read Work")
        XCTAssertEqual(seed.manga.malId, 21,
                       "the engine dropped the Work's MAL id on the way to the seed")
    }

    @MainActor
    private final class CapturingProvider: CandidateProvider {
        var seen: TasteProfile?
        func candidates(for profile: TasteProfile,
                        excluding: Set<String>, limit: Int) async throws -> [ScoredManga] {
            seen = profile
            return []
        }
    }

    @MainActor
    private func makeEngine(works: WorkStore) -> RecommendationEngine {
        RecommendationEngine(history: HistoryStore(defaults: makeDefaults()),
                             library: LibraryStore(defaults: makeDefaults()),
                             profileStore: TasteProfileStore(defaults: makeDefaults()),
                             workStore: works,
                             source: { MockSource() },
                             makeProvider: { _ in EmptyProvider() })
    }

    private struct EmptyProvider: CandidateProvider {
        func candidates(for profile: TasteProfile, excluding: Set<String>, limit: Int) async throws -> [ScoredManga] { [] }
    }

    private struct MockSource: MangaSource {
        let id = "mock"
        let name = "Mock"
        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }
        func chapters(mangaId: String) async throws -> [Chapter] { [] }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }
}
