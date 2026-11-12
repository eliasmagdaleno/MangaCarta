import XCTest
@testable import MangaCarta

@MainActor
final class PerTitleSourcesTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        directory = makeTestDirectory("PerTitleSourcesTests-\(UUID().uuidString)")
        defaults = makeTestDefaults("PerTitleSourcesTests")
    }

    private func manga(_ id: String, source: String, mal: Int? = 7) -> Manga {
        Manga(id: id, sourceId: source, title: "Title", description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: mal)
    }

    private struct Fixture {
        let works: WorkStore; let a: Manga; let b: Manga; let work: WorkID
        let fulfillment: FulfillmentCoordinator; let preferences: SourcePreferenceStore
        let library: LibraryStore; let updates: UpdateStateStore; let choices: MALSourceChoiceStore
    }

    private func setup() -> Fixture {
        let works = WorkStore(directory: directory)
        let a = manga("a", source: "a"); let b = manga("b", source: "b")
        let work = works.mint(from: a); _ = works.mint(from: b)
        let registry = SourceRegistry(sources: [
            PerTitleStubSource(id: "a", chapterNumbers: ["1"]),
            PerTitleStubSource(id: "b", chapterNumbers: ["1", "2", "3"])
        ], defaults: defaults)
        let counts = ListingCountCache(directory: directory)
        let preferences = SourcePreferenceStore(defaults: defaults, works: works)
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry, counts: counts, preferences: preferences)
        let library = LibraryStore(defaults: defaults, works: works, registry: registry)
        let updates = UpdateStateStore(directory: directory, works: works)
        let choices = MALSourceChoiceStore(directory: directory)
        return Fixture(works: works, a: a, b: b, work: work, fulfillment: fulfillment,
                       preferences: preferences, library: library, updates: updates, choices: choices)
    }

    func testRetiredListingReadStateStillCountsForWork() {
        let works = WorkStore(directory: directory); let a = manga("a", source: "a"); let b = manga("b", source: "b")
        let work = works.mint(from: a); _ = works.mint(from: b)
        let history = HistoryStore(defaults: defaults, works: works)
        history.record(manga: b, chapter: Chapter(id: "b7", number: "7", title: nil), position: ReadingPosition(page: 4), pageCount: 5)
        XCTAssertEqual(works.removeListing(ListingKey(b), from: work, keepingReadState: true), .removed)
        let library = LibraryStore(defaults: defaults, works: works); library.toggle(a); library.setChapterNumbers(["7"], for: "a")
        XCTAssertTrue(history.isRead(Chapter(id: "a7", number: "7", title: nil), in: a))
        XCTAssertEqual(history.unreadCount(for: library.item(for: ListingKey(a))!), 0)
    }

    func testDifferentTitleRemovalStopsCountingReads() {
        let works = WorkStore(directory: directory); let a = manga("a", source: "a"); let b = manga("b", source: "b")
        let work = works.mint(from: a); _ = works.mint(from: b)
        let history = HistoryStore(defaults: defaults, works: works)
        history.record(manga: b, chapter: Chapter(id: "b7", number: "7", title: nil), position: ReadingPosition(page: 4), pageCount: 5)
        XCTAssertEqual(works.removeListing(ListingKey(b), from: work, keepingReadState: false), .removed)
        XCTAssertFalse(history.isRead(Chapter(id: "a7", number: "7", title: nil), in: a))
    }

    func testRemoveClearsPinOnRemovedListing() async {
        let f = setup(); f.preferences.choose(ListingKey(f.b), for: f.work)
        let coordinator = WorkSourcesCoordinator(works: f.works, preferences: f.preferences,
                                                 fulfillment: f.fulfillment, library: f.library,
                                                 malChoices: f.choices, updates: f.updates)
        _ = await coordinator.remove(ListingKey(f.b), from: f.work, keepingReadState: true)
        XCTAssertNil(f.preferences.choice(for: f.work))
    }

    func testRemoveKeepsPinOnOtherListing() async {
        let f = setup(); f.preferences.choose(ListingKey(f.a), for: f.work)
        let coordinator = WorkSourcesCoordinator(works: f.works, preferences: f.preferences,
                                                 fulfillment: f.fulfillment, library: f.library,
                                                 malChoices: f.choices, updates: f.updates)
        _ = await coordinator.remove(ListingKey(f.b), from: f.work, keepingReadState: true)
        XCTAssertEqual(f.preferences.choice(for: f.work), ListingKey(f.a))
    }

    func testRemovingActivePinnedListingChoosesRemainingListing() async {
        let f = setup()
        f.preferences.choose(ListingKey(f.b), for: f.work)
        let coordinator = WorkSourcesCoordinator(works: f.works, preferences: f.preferences,
                                                 fulfillment: f.fulfillment, library: f.library,
                                                 malChoices: f.choices, updates: f.updates)
        _ = await coordinator.remove(ListingKey(f.b), from: f.work, keepingReadState: true)
        await f.fulfillment.reconcile(f.work)
        XCTAssertEqual(f.fulfillment.chosenListing(for: f.work), ListingKey(f.a))
    }

    func testRemoveRepointsLibraryItemKeepingCollections() async {
        let f = setup(); f.library.toggle(f.b)
        f.library.setCollections(for: f.b, collectionIds: [LibraryCollection.readingID, "custom"])
        f.library.setChapterNumbers(["1", "2"], for: "b")
        let coordinator = WorkSourcesCoordinator(works: f.works, preferences: f.preferences,
                                                 fulfillment: f.fulfillment, library: f.library,
                                                 malChoices: f.choices, updates: f.updates)
        _ = await coordinator.remove(ListingKey(f.b), from: f.work, keepingReadState: true)
        let item = f.library.item(for: ListingKey(f.a)); XCTAssertEqual(f.library.items.count, 1)
        XCTAssertEqual(item?.collectionIds, [LibraryCollection.readingID, "custom"])
        XCTAssertNil(item?.chapterNumbers)
    }

    func testRemoveForgetsMALHubChoiceForRemovedListing() async {
        let f = setup(); await f.choices.confirm(malId: 7, sourceId: "b", manga: f.b, title: "Title")
        let coordinator = WorkSourcesCoordinator(works: f.works, preferences: f.preferences,
                                                 fulfillment: f.fulfillment, library: f.library,
                                                 malChoices: f.choices, updates: f.updates)
        _ = await coordinator.remove(ListingKey(f.b), from: f.work, keepingReadState: true)
        let choice = await f.choices.choice(for: 7)
        XCTAssertNil(choice)
    }

    func testRemoveKeepsMALHubChoiceForAnotherListing() async {
        let f = setup(); await f.choices.confirm(malId: 7, sourceId: "a", manga: f.a, title: "Title")
        let coordinator = WorkSourcesCoordinator(works: f.works, preferences: f.preferences,
                                                 fulfillment: f.fulfillment, library: f.library,
                                                 malChoices: f.choices, updates: f.updates)
        _ = await coordinator.remove(ListingKey(f.b), from: f.work, keepingReadState: true)
        let choice = await f.choices.choice(for: 7)
        XCTAssertEqual(choice?.sourceId, "a")
    }

    func testRemoveDropsUpdateCheckStateForRemovedListingOnly() async {
        let f = setup(); _ = f.updates.absorb(workId: f.work, listing: ListingKey(f.a), rawNumbers: ["1"])
        _ = f.updates.absorb(workId: f.work, listing: ListingKey(f.a), rawNumbers: ["1", "2"])
        _ = f.updates.absorb(workId: f.work, listing: ListingKey(f.b), rawNumbers: ["1"])
        let before = f.updates.state(for: f.work)!
        let coordinator = WorkSourcesCoordinator(works: f.works, preferences: f.preferences,
                                                 fulfillment: f.fulfillment, library: f.library,
                                                 malChoices: f.choices, updates: f.updates)
        _ = await coordinator.remove(ListingKey(f.b), from: f.work, keepingReadState: true)
        let after = f.updates.state(for: f.work)!
        XCTAssertNil(after.listings[ListingKey(f.b)])
        XCTAssertNotNil(after.listings[ListingKey(f.a)])
        XCTAssertEqual(after.frontier, before.frontier); XCTAssertEqual(after.newlyDiscovered, before.newlyDiscovered)
    }

    func testRemoveRefusedChangesNothing() async {
        let f = setup()
        let single = WorkStore(directory: makeTestDirectory("single"))
        let solo = manga("solo", source: "a"); let soloWork = single.mint(from: solo)
        let soloPreferences = SourcePreferenceStore(defaults: defaults, works: single)
        let soloCounts = ListingCountCache(directory: directory)
        let soloFulfillment = FulfillmentCoordinator(works: single,
            registry: SourceRegistry(sources: [], defaults: defaults), counts: soloCounts,
            preferences: soloPreferences)
        let coordinator = WorkSourcesCoordinator(works: single, preferences: soloPreferences,
            fulfillment: soloFulfillment, library: LibraryStore(defaults: defaults, works: single),
            malChoices: f.choices, updates: UpdateStateStore(directory: directory, works: single))
        let result = await coordinator.remove(ListingKey(solo), from: soloWork, keepingReadState: true)
        XCTAssertEqual(result, .refusedLastListing)
        XCTAssertEqual(single.work(soloWork)?.listings, [ListingKey(solo)])
    }

    func testAddReconcilesAndReportsAdded() async {
        let works = WorkStore(directory: directory)
        let a = manga("a", source: "a"); let b = manga("b", source: "b", mal: nil)
        let work = works.mint(from: a)
        let registry = SourceRegistry(sources: [
            PerTitleStubSource(id: "a"),
            PerTitleStubSource(id: "b", chapterNumbers: ["1", "2", "3"])
        ], defaults: defaults)
        let preferences = SourcePreferenceStore(defaults: defaults, works: works); let counts = ListingCountCache(directory: directory)
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry, counts: counts, preferences: preferences)
        let coordinator = WorkSourcesCoordinator(works: works, preferences: preferences,
            fulfillment: fulfillment, library: LibraryStore(defaults: defaults, works: works),
            malChoices: MALSourceChoiceStore(directory: directory),
            updates: UpdateStateStore(directory: directory, works: works))
        let result = await coordinator.add(b, to: work, recordExternalIds: false)
        XCTAssertEqual(result, .added)
        XCTAssertEqual(counts.count(for: ListingKey(b)), 3)
    }

    func testMoveCleansSourceAndKeepsLibraryCollections() async {
        let works = WorkStore(directory: directory)
        let targetListing = manga("target", source: "a", mal: 1)
        let moved = manga("moved", source: "b", mal: 2)
        let remaining = manga("remaining", source: "c", mal: 3)
        let target = works.mint(from: targetListing)
        let source = works.mint(from: moved); XCTAssertEqual(works.addListing(remaining, to: source, recordExternalIds: false), .added)
        let registry = SourceRegistry(sources: [PerTitleStubSource(id: "a"),
                                                PerTitleStubSource(id: "b"),
                                                PerTitleStubSource(id: "c")], defaults: defaults)
        let preferences = SourcePreferenceStore(defaults: defaults, works: works)
        preferences.choose(ListingKey(moved), for: source)
        let counts = ListingCountCache(directory: directory)
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry, counts: counts, preferences: preferences)
        let library = LibraryStore(defaults: defaults, works: works, registry: registry)
        library.toggle(moved); library.setCollections(for: moved, collectionIds: [LibraryCollection.readingID, "custom"])
        let coordinator = WorkSourcesCoordinator(works: works, preferences: preferences,
            fulfillment: fulfillment, library: library,
            malChoices: MALSourceChoiceStore(directory: directory),
            updates: UpdateStateStore(directory: directory, works: works))
        let moveResult = await coordinator.move(ListingKey(moved), from: source, to: target)
        XCTAssertEqual(moveResult, .removed)
        XCTAssertNil(preferences.choice(for: source))
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.item(for: ListingKey(remaining))?.collectionIds, [LibraryCollection.readingID, "custom"])
        XCTAssertTrue(works.work(target)?.listings.contains(ListingKey(moved)) == true)
        XCTAssertTrue(works.work(target)?.handLinkedListings.contains(ListingKey(moved)) == true)
        XCTAssertEqual(works.work(source)?.removedListings.first?.key, ListingKey(moved))
        XCTAssertEqual(works.work(source)?.removedListings.first?.keepsReadState, true)
    }
}

private struct PerTitleStubSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    let chapterNumbers: [String]

    init(id: String, chapterNumbers: [String] = []) {
        self.id = id; self.chapterNumbers = chapterNumbers
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        chapterNumbers.map { Chapter(id: UUID().uuidString, number: $0, title: nil, date: nil) }
    }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
