import XCTest
@testable import MangaCarta

@MainActor
final class WorkSourcesCoordinatorMigrateTests: XCTestCase {
    private struct Fixture {
        let works: WorkStore; let prefs: SourcePreferenceStore; let library: LibraryStore
        let coordinator: WorkSourcesCoordinator; let a: Manga; let b: Manga; let work: WorkID
    }
    private var directory: URL!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        directory = makeTestDirectory("Migrate-\(UUID().uuidString)")
        defaults = makeTestDefaults("Migrate-\(UUID().uuidString)")
    }
    private func manga(_ id: String, source: String, mal: Int? = 7, cover: URL? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: "Stable title", description: "", status: "ongoing",
              year: nil, coverURL: cover, malId: mal)
    }
    private func fixture() -> Fixture {
        let works = WorkStore(directory: directory)
        let a = manga("a", source: "a")
        let b = manga("b", source: "b", cover: URL(string: "https://b/cover"))
        let work = works.mint(from: a)
        let prefs = SourcePreferenceStore(defaults: defaults, works: works)
        let registry = SourceRegistry(sources: [], defaults: defaults)
        let counts = ListingCountCache(directory: directory)
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry,
            counts: counts, preferences: prefs)
        let library = LibraryStore(defaults: defaults, works: works, registry: registry)
        let coordinator = WorkSourcesCoordinator(works: works, preferences: prefs,
            fulfillment: fulfillment, library: library,
            malChoices: MALSourceChoiceStore(directory: directory),
            updates: UpdateStateStore(directory: directory, works: works))
        return Fixture(works: works, prefs: prefs, library: library, coordinator: coordinator,
                       a: a, b: b, work: work)
    }
    func testKeepAddsTargetAndPinsIt() async {
        let f = fixture(); let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.prefs.choice(for: f.work), ListingKey(f.b))
        XCTAssertTrue(f.works.work(f.work)!.listings.contains(ListingKey(f.b)))
    }
    func testRemoveWhenOldCopyIsTheOnlyOne() async {
        let f = fixture(); let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: true)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.works.work(f.work)!.listings, [ListingKey(f.b)])
        XCTAssertEqual(f.works.work(f.work)!.removedListings.map(\.key), [ListingKey(f.a)])
    }
    func testRemoveRetiresEveryOldCopyKeepingReadState() async {
        let f = fixture(); let a2 = manga("a2", source: "a", mal: nil)
        _ = f.works.addListing(a2, to: f.work, recordExternalIds: false)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: true)
        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(Set(f.works.work(f.work)!.removedListings.map(\.key)), [ListingKey(f.a), ListingKey(a2)])
    }
    func testLibraryItemMovesToTargetWithTargetCover() async {
        let f = fixture(); f.library.toggle(f.a)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.library.items.count, 1)
        XCTAssertEqual(f.library.item(for: ListingKey(f.b))?.coverURL, f.b.coverURL)
        XCTAssertEqual(f.library.item(for: ListingKey(f.b))?.title, f.a.title)
    }
    func testLibraryItemMovesToTargetWithTargetCoverInRemoveMode() async {
        let f = fixture(); f.library.toggle(f.a)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: true)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.library.items.count, 1)
        XCTAssertEqual(f.library.item(for: ListingKey(f.b))?.coverURL, f.b.coverURL)
    }
    func testPinOnThirdSourceIsKept() async {
        let f = fixture(); let c = manga("c", source: "c")
        _ = f.works.addListing(c, to: f.work, recordExternalIds: false); f.prefs.choose(ListingKey(c), for: f.work)
        f.library.toggle(f.a); let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: true)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.prefs.choice(for: f.work), ListingKey(c))
        XCTAssertNotNil(f.library.item(for: ListingKey(f.b)))
    }
    func testTargetOwnedByAnotherWorkIsSkipped() async {
        let f = fixture(); let b = manga("b", source: "b", mal: 8); let other = f.works.mint(from: b)
        f.prefs.choose(ListingKey(f.a), for: f.work); f.library.toggle(f.a)
        let result = await f.coordinator.migrate(f.work, to: b, from: "a", removingOld: true)
        XCTAssertEqual(result, .skipped(.belongsToOtherWork(other))); XCTAssertEqual(f.prefs.choice(for: f.work), ListingKey(f.a))
        XCTAssertNotNil(f.library.item(for: ListingKey(f.a)))
    }
    func testMigratedTitleStaysInRefreshQueue() async {
        let f = fixture(); f.library.toggle(f.a)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: true)
        XCTAssertEqual(result, .migrated)
        XCTAssertNotNil(f.library.item(for: ListingKey(f.b)))
    }
    func testChapterReadOnOldSourceStillReadAfterRemove() async {
        let f = fixture()
        let history = HistoryStore(defaults: defaults, works: f.works)
        history.record(manga: f.a, chapter: Chapter(id: "a7", number: "7", title: nil),
                       position: ReadingPosition(page: 4), pageCount: 5)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: true)
        XCTAssertEqual(result, .migrated)
        XCTAssertTrue(history.isRead(Chapter(id: "b7", number: "7", title: nil), in: f.b))
    }
    func testMigrateMakesNoNetworkCall() async {
        let f = fixture(); let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated)
    }
    func testKeepAddsTargetAndPinsItWhenAlreadyLinked() async {
        let f = fixture(); _ = f.works.addListing(f.b, to: f.work, recordExternalIds: false)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.prefs.choice(for: f.work), ListingKey(f.b))
    }
    func testRepointItemNilCoverKeepsOldCover() {
        let f = fixture(); f.library.toggle(f.a); f.library.repointItem(from: ListingKey(f.a), to: ListingKey(f.a))
        XCTAssertEqual(f.library.item(for: ListingKey(f.a))?.coverURL, f.a.coverURL)
    }
}
