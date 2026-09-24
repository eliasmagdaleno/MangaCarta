//
//  WorkStoreTests.swift
//  MangaCartaTests
//
//  Slice 2 of ADR-0007: Work identity. Each test gets its own temp directory, so
//  the JSON file under test is never shared and never the real one.
//

import XCTest
@testable import MangaCarta

final class WorkStoreTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeStore() -> WorkStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkStoreTests-\(UUID().uuidString)")
        return WorkStore(directory: dir)
    }

    /// A Listing. `Manga` *is* a Listing despite the name (ADR-0001).
    private func listing(_ id: String,
                         source: String = "mangadex",
                         title: String = "Untitled",
                         malId: Int? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: title, description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: malId)
    }

    // MARK: - Minting

    @MainActor func testMintCreatesAWorkFindableByItsListingKey() {
        let store = makeStore()
        let solo = listing("md-1", title: "Solo Leveling")

        let id = store.mint(from: solo)

        XCTAssertEqual(store.work(id)?.displayTitle, "Solo Leveling")
        XCTAssertEqual(store.workId(for: ListingKey(sourceId: "mangadex", mangaId: "md-1")), id)
    }

    /// Minting is on the read path, so it runs every time a chapter is opened.
    /// It has to be idempotent or the store grows without bound.
    @MainActor func testMintingTheSameListingTwiceReturnsTheSameWork() {
        let store = makeStore()
        let solo = listing("md-1", title: "Solo Leveling")

        let first = store.mint(from: solo)
        let second = store.mint(from: solo)

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.work(first)?.listings.count, 1)
    }

    @MainActor func testRemoveListingKeepsWorkWithAnotherListing() {
        let store = makeStore()
        let local = listing("local", source: "local", malId: 1)
        let remote = listing("remote", source: "mangadex", malId: 1)
        let id = store.mint(from: local)
        _ = store.mint(from: remote)
        store.removeListing(ListingKey(local))
        XCTAssertNil(store.workId(for: ListingKey(local)))
        XCTAssertNotNil(store.work(id))
        XCTAssertEqual(store.work(id)?.listings.count, 1)
    }

    /// The free dedupe path: MangaDex publishes `attributes.links.mal`, so a Work
    /// minted from a MangaDex Listing already carries an external id. A Listing
    /// from another source with the same malId is the same Work — no request, no
    /// title matching.
    @MainActor func testMintDedupesOnASharedExternalId() {
        let store = makeStore()
        let onMangaDex = listing("md-1", source: "mangadex", title: "Solo Leveling", malId: 121_496)
        let onWeebCentral = listing("wc-9", source: "weebcentral", title: "Solo Leveling", malId: 121_496)

        let first = store.mint(from: onMangaDex)
        let second = store.mint(from: onWeebCentral)

        XCTAssertEqual(first, second, "same malId ⇒ same Work")
        XCTAssertEqual(store.work(first)?.listings.count, 2)
        XCTAssertEqual(store.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-9")), first)
    }

    /// The precision bias, at the store level: two Listings that merely *look*
    /// alike are two Works. Nothing here guesses — a wrong link corrupts identity,
    /// history, and recommendations, while a missing one only omits something
    /// (ADR-0005). Linking them is resolution's job, or the user's.
    @MainActor func testMintDoesNotGuessAcrossSourcesWithoutAnExternalId() {
        let store = makeStore()
        let onMangaDex = listing("md-1", source: "mangadex", title: "Solo Leveling")
        let onWeebCentral = listing("wc-9", source: "weebcentral", title: "Solo Leveling")

        let first = store.mint(from: onMangaDex)
        let second = store.mint(from: onWeebCentral)

        XCTAssertNotEqual(first, second, "identical titles are not evidence of identity")
    }

    // MARK: - Merging

    /// The losing id stays **resolvable forever**. A stale Work id — from a screen
    /// already open when a background reconcile merged underneath it, which
    /// ADR-0004's optimistic render makes routine — must redirect, not resolve to
    /// nil. A nil Work degrades exactly like the cross-source invisibility bug this
    /// whole line of work exists to fix, which makes it hard to notice.
    @MainActor func testMergeAliasesTheLoserRatherThanErasingIt() {
        let store = makeStore()
        let winner = store.mint(from: listing("md-1", title: "Solo Leveling"))
        let loser = store.mint(from: listing("wc-9", source: "weebcentral", title: "Only I Level Up"))

        store.merge(loser, into: winner)

        XCTAssertEqual(store.work(loser)?.id, winner, "the loser's id must still resolve")
    }

    @MainActor func testMergeUnionsListingsTitlesAndExternalIdsKeepingTheWinnersDisplayTitle() {
        let store = makeStore()
        let winner = store.mint(from: listing("md-1", title: "Solo Leveling", malId: 121_496))
        let loser = store.mint(from: listing("wc-9", source: "weebcentral", title: "Only I Level Up"))
        store.setExternalIds(ExternalIDs(mal: nil, anilist: 105_398), on: loser)

        store.merge(loser, into: winner)

        let merged = store.work(winner)
        XCTAssertEqual(merged?.displayTitle, "Solo Leveling", "surviving Work keeps its own title")
        XCTAssertEqual(merged?.knownTitles, ["Solo Leveling", "Only I Level Up"])
        XCTAssertEqual(merged?.externalIds, ExternalIDs(mal: 121_496, anilist: 105_398))
        XCTAssertEqual(merged?.listings.count, 2)
        // The loser's Listing now routes to the winner.
        XCTAssertEqual(store.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-9")), winner)
    }

    /// Merges chain in practice: a Work merged away can later have *its* survivor
    /// merged away too, as sources link up over time. Every id in the chain has to
    /// keep resolving to the one live Work at the end of it.
    @MainActor func testAliasChainsResolveToTheSurvivingWork() {
        let store = makeStore()
        let first = store.mint(from: listing("md-1", title: "A"))
        let second = store.mint(from: listing("wc-9", source: "weebcentral", title: "B"))
        let third = store.mint(from: listing("xx-3", source: "other", title: "C"))

        store.merge(first, into: second)
        store.merge(second, into: third)

        XCTAssertEqual(store.work(first)?.id, third, "two hops must still resolve")
        XCTAssertEqual(store.work(second)?.id, third)
        XCTAssertEqual(store.work(third)?.listings.count, 3)
    }

    // MARK: - Learning an external id after mint (ADR-0009)

    /// ADR-0008's trace, which the pre-fix store gets wrong. Work-level resolution is the
    /// first thing that ever learns an external id *after* mint, so this collision was
    /// unreachable until the upgrade queue — which is why slice 2 shipped without it.
    /// Before the fix, `externalIdIndex["mal:123"]` simply flipped to the newly-resolved
    /// Work and the incumbent survived unreachable by external id, splitting engagement
    /// across two Works for one manga.
    @MainActor func testLearningAnExternalIdAnotherWorkOwnsMergesRatherThanStealingTheIndex() {
        let store = makeStore()
        // Read on WeebCentral first: nothing to dedupe on, so a Work is minted bare.
        let scraped = store.mint(from: listing("wc-solo", source: "weebcentral",
                                               title: "Only I Level Up"))
        // Then on MangaDex: a different Listing key, and the scraped Work has no id to
        // match on, so a second Work is minted. Expected — this is what merge exists for.
        let canonical = store.mint(from: listing("md-solo", title: "Solo Leveling", malId: 123))
        XCTAssertNotEqual(scraped, canonical)

        // The queue resolves the scraped Work by title and learns the same id.
        store.setExternalIds(ExternalIDs(mal: 123, anilist: nil), on: scraped)

        XCTAssertEqual(store.work(scraped)?.id, canonical, "the incumbent index owner survives")
        XCTAssertEqual(store.workId(externalId: ExternalIDs(mal: 123, anilist: nil)), canonical)
        XCTAssertEqual(store.work(canonical)?.listings.count, 2, "both Listings on one Work")
        XCTAssertEqual(store.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-solo")),
                       canonical)
    }

    /// Identity and metadata are decided by different rules. The incumbent wins identity,
    /// but the snapshot goes to whichever ranks higher — otherwise the Work the user
    /// actually read hands its tags to a bare mint and the reading is wasted.
    @MainActor func testAMergeKeepsTheBetterSnapshotNotTheSurvivorsOwn() {
        let store = makeStore()
        let scraped = store.mint(from: listing("wc-solo", source: "weebcentral",
                                               title: "Only I Level Up"))
        store.applyProvisionalSnapshot(tags: [Tag(id: "t1", name: "Action", group: "genre")],
                                       to: scraped)
        let canonical = store.mint(from: listing("md-solo", title: "Solo Leveling", malId: 123))
        XCTAssertNil(store.work(canonical)?.snapshot, "the MangaDex mint carries nothing")

        store.setExternalIds(ExternalIDs(mal: 123, anilist: nil), on: scraped)

        XCTAssertEqual(store.work(canonical)?.snapshot?.genres.map(\.name), ["Action"])
    }

    /// …and not the other way round: a real provider's snapshot outranks a provisional
    /// one, so a merge must never drag a resolved Work back down to Listing tags.
    @MainActor func testAMergeDoesNotDowngradeAProviderSnapshotToAProvisionalOne() {
        let store = makeStore()
        let winner = store.mint(from: listing("md-solo", title: "Solo Leveling"))
        store.apply(AniListWork(anilistId: 1, malId: nil, knownTitles: [],
                                genres: ["Fantasy"], tags: [],
                                publicationStatus: .releasing, chapterTotal: nil),
                    to: winner)
        let loser = store.mint(from: listing("wc-solo", source: "weebcentral", title: "Only I"))
        store.applyProvisionalSnapshot(tags: [Tag(id: "t1", name: "Action", group: "genre")],
                                       to: loser)

        store.merge(loser, into: winner)

        XCTAssertEqual(store.work(winner)?.snapshot?.provider, .anilist)
        XCTAssertEqual(store.work(winner)?.snapshot?.genres.map(\.name), ["Fantasy"])
    }

    /// A merge reindexes the winner, so the winner of one merge can become the loser of
    /// the next when it absorbs an id a third Work already owns. Consistent with
    /// incumbent-survives, and bounded: every merge removes one Work.
    /// It takes two *providers* to build the chain: `ExternalIDs.absorb` never overwrites
    /// a known id, so one Work can only ever hold one MAL id. AniList supplies the second
    /// axis — one `apply` yields both `id` and `idMal`, which is why it was chosen.
    @MainActor func testAbsorbingAThirdPartysIdChainsTheMerge() {
        let store = makeStore()
        let third = store.mint(from: listing("md-a", title: "A"))
        store.setExternalIds(ExternalIDs(mal: nil, anilist: 456), on: third)
        let incumbent = store.mint(from: listing("md-b", title: "B", malId: 123))
        let newcomer = store.mint(from: listing("wc-c", source: "weebcentral", title: "C"))

        // Resolution finds mal:123 → the newcomer merges into `incumbent`.
        store.setExternalIds(ExternalIDs(mal: 123, anilist: nil), on: newcomer)
        // AniList then hands back anilist:456, which `third` already owns → `incumbent`,
        // the winner of the first merge, becomes the loser of the second.
        store.setExternalIds(ExternalIDs(mal: nil, anilist: 456), on: newcomer)

        XCTAssertEqual(store.work(newcomer)?.id, third)
        XCTAssertEqual(store.work(incumbent)?.id, third)
        XCTAssertEqual(store.work(third)?.listings.count, 3)
    }

    /// The upgrade queue scans this. Merged-away losers must not appear, or the queue
    /// would spend budget resolving Works that no longer exist.
    @MainActor func testAllWorkIdsReturnsOnlyLiveWorks() {
        let store = makeStore()
        let loser = store.mint(from: listing("md-1", title: "A"))
        let winner = store.mint(from: listing("wc-2", source: "weebcentral", title: "B"))
        store.merge(loser, into: winner)

        XCTAssertEqual(store.allWorkIds(), [winner])
    }

    // MARK: - Metadata snapshots

    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private var mangaDexTags: [Tag] {
        [Tag(id: "t1", name: "Action", group: "genre"),
         Tag(id: "t2", name: "Isekai", group: "theme"),
         Tag(id: "t3", name: "Long Strip", group: "format")]
    }

    /// The provisional tier: MangaDex's tags arrive free with the detail fetch the UI
    /// already makes, so the recommender works from launch with no request and no
    /// rate limit. They carry no rank, and their `group` is preserved because
    /// `TasteProfile.groupWeight` still weights genre above theme above format.
    @MainActor func testProvisionalSnapshotUsesTheListingsOwnTagsAndCarriesNoRank() {
        let store = makeStore()
        let id = store.mint(from: listing("md-1", title: "Solo Leveling"))

        store.applyProvisionalSnapshot(tags: mangaDexTags, to: id, now: noon)

        let snapshot = store.work(id)?.snapshot
        XCTAssertEqual(snapshot?.provider, .mangadex)
        XCTAssertEqual(snapshot?.genres, [QueryableTag(name: "Action", group: "genre"),
                                         QueryableTag(name: "Isekai", group: "theme"),
                                         QueryableTag(name: "Long Strip", group: "format")])
        XCTAssertEqual(snapshot?.tags, [], "MangaDex publishes no tag rank")
        XCTAssertEqual(snapshot?.fetchedAt, noon)
    }

    // MARK: - Tags seen on a detail screen (slice 3, step 2)

    /// Tags only ever exist on the detail screen, and every source has them — this
    /// is the half of the ADR-0001 bug that made non-MangaDex reading contribute no
    /// tag signal at all.
    @MainActor func testDetailTagsLandOnAWorkTheUserHasAlreadyCommittedTo() {
        let store = makeStore()
        let orv = listing("wc-1", source: "weebcentral", title: "Omniscient Reader")
        let id = store.mint(from: orv)

        store.noteListingTags(mangaDexTags, for: orv, now: noon)

        XCTAssertEqual(store.work(id)?.snapshot?.genres.map(\.name),
                       ["Action", "Isekai", "Long Strip"])
    }

    /// **Browsing must not mint** (ADR-0007): opening a detail page is not a
    /// commitment, and minting per detail view would grow the store with browsing.
    @MainActor func testDetailTagsAloneDoNotMintAWork() {
        let store = makeStore()

        store.noteListingTags(mangaDexTags, for: listing("wc-2", source: "weebcentral"), now: noon)

        XCTAssertNil(store.workId(for: ListingKey(sourceId: "weebcentral", mangaId: "wc-2")))
    }

    /// The flow that actually happens: open the detail page, then tap a chapter
    /// seconds later. The tags were on screen before the Work existed, and dropping
    /// them would leave the first read of every manga with no signal until the user
    /// happened to revisit the page.
    @MainActor func testDetailTagsSeenBeforeCommitmentAreAppliedWhenTheWorkIsMinted() {
        let store = makeStore()
        let orv = listing("wc-3", source: "weebcentral", title: "Omniscient Reader")

        store.noteListingTags(mangaDexTags, for: orv, now: noon)
        let id = store.mint(from: orv)

        XCTAssertEqual(store.work(id)?.snapshot?.genres.map(\.name),
                       ["Action", "Isekai", "Long Strip"])
    }

    /// The provisional tier is a *floor*, not an overwrite. Re-opening a detail page
    /// for a Work the upgrade queue has already resolved must not drag it back down
    /// to MangaDex tags — that would silently undo a real fetch and make the
    /// snapshot's provider depend on which screen the user last visited.
    @MainActor func testDetailTagsDoNotDowngradeAProviderSnapshot() {
        let store = makeStore()
        let solo = listing("md-1", title: "Solo Leveling", malId: 121_496)
        let id = store.mint(from: solo)
        store.apply(AniListWork(anilistId: 105_398, malId: 121_496,
                                knownTitles: ["Solo Leveling"],
                                genres: ["Action", "Adventure", "Fantasy"],
                                tags: [RankedTag(name: "Dungeon", rank: 95)],
                                publicationStatus: .finished, chapterTotal: 201),
                    to: id, now: noon)

        store.noteListingTags(mangaDexTags, for: solo, now: noon)

        XCTAssertEqual(store.work(id)?.snapshot?.provider, .anilist)
        XCTAssertEqual(store.work(id)?.snapshot?.genres.map(\.name),
                       ["Action", "Adventure", "Fantasy"])
    }

    /// An AniList snapshot **replaces** the provisional one wholesale — one
    /// authority per Work, never a per-field merge — but external ids accumulate.
    @MainActor func testAniListSnapshotReplacesTheProvisionalOneAndAccumulatesIds() {
        let store = makeStore()
        let id = store.mint(from: listing("md-1", title: "Solo Leveling", malId: 121_496))
        store.applyProvisionalSnapshot(tags: mangaDexTags, to: id, now: noon)

        let fromAniList = AniListWork(anilistId: 105_398,
                                      malId: 121_496,
                                      knownTitles: ["Na Honjaman Level Up", "Solo Leveling"],
                                      genres: ["Action", "Adventure", "Fantasy"],
                                      tags: [RankedTag(name: "Dungeon", rank: 95)],
                                      publicationStatus: .finished,
                                      chapterTotal: 201)
        store.apply(fromAniList, to: id, now: noon)

        let work = store.work(id)
        XCTAssertEqual(work?.snapshot?.provider, .anilist)
        XCTAssertEqual(work?.snapshot?.genres.map(\.name), ["Action", "Adventure", "Fantasy"],
                       "wholesale replacement, so Isekai and Long Strip are gone")
        XCTAssertEqual(work?.snapshot?.tags, [RankedTag(name: "Dungeon", rank: 95)])
        XCTAssertEqual(work?.snapshot?.chapterTotal, 201)
        XCTAssertEqual(work?.externalIds, ExternalIDs(mal: 121_496, anilist: 105_398))
        // Provider titles become matcher fuel; the display title stays put.
        XCTAssertEqual(work?.displayTitle, "Solo Leveling")
        XCTAssertTrue(work?.knownTitles.contains("Na Honjaman Level Up") == true)
        // And the Work is now reachable by its AniList id.
        XCTAssertEqual(store.workId(externalId: ExternalIDs(mal: nil, anilist: 105_398)), id)
    }

    /// Wholesale replacement can lose information, so it's guarded: a provider
    /// snapshot with nothing on the searchable axis doesn't get to discard tags we
    /// already had. The *ids* still accumulate — learning the AniList id is useful
    /// even when the metadata behind it isn't.
    ///
    /// ADR-0007 calls this the one rule of its kind; a third such rule means
    /// per-field provenance was the right design after all.
    @MainActor func testAnEmptyProviderSnapshotDoesNotDiscardTheProvisionalOne() {
        let store = makeStore()
        let id = store.mint(from: listing("md-1", title: "Solo Leveling", malId: 121_496))
        store.applyProvisionalSnapshot(tags: mangaDexTags, to: id, now: noon)

        let emptyish = AniListWork(anilistId: 105_398, malId: 121_496, knownTitles: [],
                                   genres: [], tags: [], publicationStatus: .finished,
                                   chapterTotal: nil)
        store.apply(emptyish, to: id, now: noon)

        let work = store.work(id)
        XCTAssertEqual(work?.snapshot?.provider, .mangadex, "kept the snapshot that had content")
        XCTAssertEqual(work?.snapshot?.genres.count, 3)
        XCTAssertEqual(work?.externalIds.anilist, 105_398, "ids accumulate regardless")
    }

    // MARK: - Snapshot staleness

    /// TTL derives from the data's own semantics rather than a guessed constant.
    @MainActor func testStalenessFollowsPublicationStatus() {
        let day: TimeInterval = 86_400

        // FINISHED is terminal: the chapter total will never change again.
        let finished = MetadataSnapshot(provider: .anilist, fetchedAt: noon, genres: [],
                                       tags: [], publicationStatus: .finished, chapterTotal: 201)
        XCTAssertFalse(finished.isStale(now: noon.addingTimeInterval(3650 * day)))

        // RELEASING is known-incomplete -- `chapters` is null by definition -- so it
        // is re-checked on a 14-day cycle, mirroring EntityResolutionStore's miss TTL.
        let releasing = MetadataSnapshot(provider: .anilist, fetchedAt: noon, genres: [],
                                        tags: [], publicationStatus: .releasing, chapterTotal: nil)
        XCTAssertFalse(releasing.isStale(now: noon.addingTimeInterval(13 * day)))
        XCTAssertTrue(releasing.isStale(now: noon.addingTimeInterval(15 * day)))

        // A provisional snapshot is *always* stale: it is a placeholder, and this is
        // how the upgrade queue knows there is work to do.
        let provisional = MetadataSnapshot(provider: .mangadex, fetchedAt: noon, genres: [],
                                          tags: [], publicationStatus: .unknown, chapterTotal: nil)
        XCTAssertTrue(provisional.isStale(now: noon))
    }

    // MARK: - Persistence

    @MainActor func testWorksSurviveAReload() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkStoreTests-\(UUID().uuidString)")
        let first = WorkStore(directory: dir)
        let id = first.mint(from: listing("md-1", title: "Solo Leveling", malId: 121_496))
        first.applyProvisionalSnapshot(tags: mangaDexTags, to: id, now: noon)
        first.flush()

        let reloaded = WorkStore(directory: dir)

        XCTAssertEqual(reloaded.work(id)?.displayTitle, "Solo Leveling")
        XCTAssertEqual(reloaded.work(id)?.snapshot?.genres.count, 3)
        // Both indexes are rebuilt on load rather than persisted, so they cannot
        // drift out of sync with the Works they point at.
        XCTAssertEqual(reloaded.workId(for: ListingKey(sourceId: "mangadex", mangaId: "md-1")), id)
        XCTAssertEqual(reloaded.workId(externalId: ExternalIDs(mal: 121_496, anilist: nil)), id)
    }

    /// Aliases have to persist. A Work id from before a relaunch is exactly the
    /// stale id aliasing exists to protect — a manual link override (ADR-0005) is
    /// permanent and may name a Work that was later merged away.
    @MainActor func testAliasesSurviveAReload() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkStoreTests-\(UUID().uuidString)")
        let first = WorkStore(directory: dir)
        let winner = first.mint(from: listing("md-1", title: "Solo Leveling"))
        let loser = first.mint(from: listing("wc-9", source: "weebcentral", title: "Only I Level Up"))
        first.merge(loser, into: winner)
        first.flush()

        let reloaded = WorkStore(directory: dir)

        XCTAssertEqual(reloaded.work(loser)?.id, winner, "a merged-away id must still resolve after relaunch")
    }

    /// Slice 3 put `mint` on the read path, where it runs on **every page turn**.
    /// A re-mint that learns nothing must therefore not re-arm the debounce: if it
    /// does, each page turn pushes the write further out and a long reading session
    /// never persists at all — the write is deferred for as long as the user reads.
    @MainActor func testAReMintThatLearnsNothingDoesNotDeferThePendingSave() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkStoreTests-\(UUID().uuidString)")
        let store = WorkStore(directory: dir, saveDebounce: 0.2)
        let solo = listing("md-1", title: "Solo Leveling")
        _ = store.mint(from: solo)              // arms a save for t ≈ 0.2

        for _ in 0..<4 {                        // "page turns" at 0.15s intervals
            try await Task.sleep(nanoseconds: 150_000_000)
            _ = store.mint(from: solo)
        }

        // t ≈ 0.6, so the save armed by the first mint is long overdue.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("works.json").path),
                      "re-minting an unchanged Listing kept rescheduling the debounced save")
    }

    @MainActor func testAnEmptyDirectoryLoadsAsAnEmptyStore() {
        let store = makeStore()

        XCTAssertNil(store.work(WorkID()))
        XCTAssertNil(store.workId(for: ListingKey(sourceId: "mangadex", mangaId: "nope")))
    }

    @MainActor func testMergingAWorkIntoItselfIsANoOp() {
        let store = makeStore()
        let id = store.mint(from: listing("md-1", title: "Solo Leveling"))

        store.merge(id, into: id)

        XCTAssertEqual(store.work(id)?.listings.count, 1)
        XCTAssertEqual(store.work(id)?.displayTitle, "Solo Leveling")
    }

    /// A `works.json` from a build without the reindex fix: two Works, one manga, both
    /// claiming `mal:123`. This file *will* exist in the wild — it is precisely what
    /// shipping the queue without the fix produces. Loading it faithfully would preserve
    /// the split, so the load path repairs it instead (ADR-0009).
    @MainActor func testLoadingAStoreThatAlreadySplitOneMangaRepairsIt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkStoreTests-\(UUID().uuidString)")
        let ids = ExternalIDs(mal: 123, anilist: nil)
        let canonical = Work(id: WorkID(), displayTitle: "Solo Leveling",
                             knownTitles: ["Solo Leveling"], externalIds: ids,
                             listings: [ListingKey(sourceId: "mangadex", mangaId: "md-solo")],
                             snapshot: nil)
        let scraped = Work(id: WorkID(), displayTitle: "Only I Level Up",
                           knownTitles: ["Only I Level Up"], externalIds: ids,
                           listings: [ListingKey(sourceId: "weebcentral", mangaId: "wc-solo")],
                           snapshot: MetadataSnapshot(
                            provider: .mangadex, fetchedAt: noon,
                            genres: [QueryableTag(name: "Action", group: "genre")],
                            tags: [], publicationStatus: .unknown, chapterTotal: nil))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(PersistedFixture(works: [canonical, scraped], aliases: []))
            .write(to: dir.appendingPathComponent("works.json"))

        let store = WorkStore(directory: dir)

        XCTAssertEqual(store.allWorkIds(), [canonical.id], "first indexed is the incumbent")
        XCTAssertEqual(store.work(scraped.id)?.id, canonical.id, "the stale id redirects")
        XCTAssertEqual(store.work(canonical.id)?.listings.count, 2)
        XCTAssertEqual(store.work(canonical.id)?.snapshot?.genres.map(\.name), ["Action"],
                       "the reading that produced these tags is not thrown away")
    }

    // MARK: - noteTitles (ADR-0016 Decision 5)

    /// The count comes back from the store rather than being re-read by the caller, because
    /// the caller is holding a pre-harvest `Work` value and would fingerprint an `.unmatched`
    /// outcome against a number that is already stale.
    @MainActor func testNoteTitlesUnionsAndReturnsThePostAdditionCount() {
        let store = makeStore()
        let id = store.mint(from: listing("wc-1", source: "weebcentral", title: "Girlfriend, Girlfriend"))

        let grown = store.noteTitles(["Kanojo mo Kanojo", "Girlfriend Girlfriend"], on: id)

        XCTAssertEqual(grown, 3)
        XCTAssertEqual(store.work(id)?.knownTitles.sorted(),
                       ["Girlfriend Girlfriend", "Girlfriend, Girlfriend", "Kanojo mo Kanojo"])
    }

    /// Idempotent, which is what makes it safe for a queue that re-drains the same Work: a
    /// second harvest of the same spellings must not keep nudging the count upward, or the
    /// `.unmatched` fingerprint would change without anything having been learned.
    @MainActor func testNoteTitlesIsIdempotentAndReturnsTheUnchangedCount() {
        let store = makeStore()
        let id = store.mint(from: listing("wc-1", source: "weebcentral", title: "Berserk"))

        XCTAssertEqual(store.noteTitles(["Beruseruku"], on: id), 2)
        XCTAssertEqual(store.noteTitles(["Beruseruku"], on: id), 2, "already known — a no-op")
        XCTAssertEqual(store.noteTitles([], on: id), 2)
        XCTAssertEqual(store.work(id)?.knownTitles.count, 2)
    }

    /// Follows the alias, like every other mutator here: a merged-away id must still land on
    /// the survivor rather than silently dropping the harvest.
    @MainActor func testNoteTitlesFollowsAMergeAlias() {
        let store = makeStore()
        let loser = store.mint(from: listing("wc-1", source: "weebcentral", title: "Sinui Tap"))
        let winner = store.mint(from: listing("md-1", title: "Tower of God"))
        store.merge(loser, into: winner)

        XCTAssertEqual(store.noteTitles(["Kami no Tou"], on: loser), store.work(winner)?.knownTitles.count)
        XCTAssertTrue(store.work(winner)?.knownTitles.contains("Kami no Tou") == true)
    }
}

// MARK: - On-disk fixture

/// The store's on-disk shape, mirrored so a test can plant a file the fixed code would
/// never write. File-scope rather than nested in the test class so `Alias` stays one
/// level deep — the same reason `WorkStore.swift` keeps `Persisted` out of the class.
private struct PersistedFixture: Codable {
    struct Alias: Codable {
        let from: WorkID
        let to: WorkID
    }
    var works: [Work]
    var aliases: [Alias]
}
