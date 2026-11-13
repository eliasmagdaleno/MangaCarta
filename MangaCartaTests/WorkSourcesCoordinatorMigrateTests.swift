import XCTest
@testable import MangaCarta

@MainActor
final class WorkSourcesCoordinatorMigrateTests: XCTestCase {
    private struct Fixture {
        let works: WorkStore; let prefs: SourcePreferenceStore; let library: LibraryStore
        let coordinator: WorkSourcesCoordinator; let a: Manga; let b: Manga; let work: WorkID
        let registry: SourceRegistry; let sourceB: CountingMigrationSource
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
        let a = manga("a", source: "a", cover: URL(string: "https://a/cover"))
        let b = manga("b", source: "b", cover: URL(string: "https://b/cover"))
        let work = works.mint(from: a)
        let prefs = SourcePreferenceStore(defaults: defaults, works: works)
        let sourceA = CountingMigrationSource(id: "a")
        let sourceB = CountingMigrationSource(id: "b")
        let registry = SourceRegistry(sources: [sourceA, sourceB], defaults: defaults)
        let counts = ListingCountCache(directory: directory)
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry,
            counts: counts, preferences: prefs)
        let library = LibraryStore(defaults: defaults, works: works, registry: registry)
        let coordinator = WorkSourcesCoordinator(works: works, preferences: prefs,
            fulfillment: fulfillment, library: library,
            malChoices: MALSourceChoiceStore(directory: directory),
            updates: UpdateStateStore(directory: directory, works: works))
        return Fixture(works: works, prefs: prefs, library: library, coordinator: coordinator,
                       a: a, b: b, work: work, registry: registry, sourceB: sourceB)
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
        XCTAssertTrue(f.works.work(f.work)!.removedListings.allSatisfy(\.keepsReadState))
    }
    func testLibraryItemMovesToTargetWithTargetCover() async {
        let f = fixture(); f.library.toggle(f.a)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.library.items.count, 1)
        XCTAssertEqual(f.library.item(for: ListingKey(f.b))?.coverURL, f.b.coverURL)
        XCTAssertEqual(f.library.item(for: ListingKey(f.b))?.title, f.a.title)
        XCTAssertNotEqual(f.a.coverURL, f.b.coverURL)
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
        XCTAssertEqual(f.library.item(for: ListingKey(f.b))?.coverURL, f.b.coverURL)
    }
    func testStalePinOnThirdSourceIsReplacedByTarget() async {
        let f = fixture(); let c = manga("c", source: "c")
        _ = f.works.addListing(c, to: f.work, recordExternalIds: false)
        f.prefs.choose(ListingKey(c), for: f.work)
        _ = f.works.removeListing(ListingKey(c), from: f.work, keepingReadState: true)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(f.prefs.choice(for: f.work), ListingKey(f.b))
    }
    func testTargetOwnedByAnotherWorkIsSkipped() async {
        let f = fixture(); let b = manga("b", source: "b", mal: 8); let other = f.works.mint(from: b)
        f.prefs.choose(ListingKey(f.a), for: f.work); f.library.toggle(f.a)
        let result = await f.coordinator.migrate(f.work, to: b, from: "a", removingOld: true)
        XCTAssertEqual(result, .skipped(.belongsToOtherWork(other))); XCTAssertEqual(f.prefs.choice(for: f.work), ListingKey(f.a))
        XCTAssertNotNil(f.library.item(for: ListingKey(f.a)))
        XCTAssertEqual(f.works.work(f.work)!.listings, [ListingKey(f.a)])
        XCTAssertTrue(f.works.work(f.work)!.removedListings.isEmpty)
    }
    func testLocalLibraryItemIsNotRepointed() async {
        let f = fixture(); let local = manga("local-copy", source: LocalSource.sourceID, mal: nil)
        _ = f.works.addListing(local, to: f.work, recordExternalIds: false)
        f.library.toggle(local)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated)
        XCTAssertNotNil(f.library.item(for: ListingKey(local)))
        XCTAssertNil(f.library.item(for: ListingKey(f.b)))
    }
    func testMigratedTitleStaysInRefreshQueue() async {
        let f = fixture(); f.library.toggle(f.a)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: true)
        XCTAssertEqual(result, .migrated)
        let refresh = LibraryRefreshCoordinator(works: f.works, library: f.library,
            history: HistoryStore(defaults: defaults, works: f.works),
            updates: UpdateStateStore(directory: directory, works: f.works), registry: f.registry)
        _ = await refresh.run(budget: .foreground)
        let asked = await f.sourceB.askedIds()
        XCTAssertEqual(asked, [f.b.id])
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
        let asked = await f.sourceB.askedIds()
        XCTAssertEqual(asked, [])
    }
    func testKeepAddsTargetAndPinsItWhenAlreadyLinked() async {
        let f = fixture(); _ = f.works.addListing(f.b, to: f.work, recordExternalIds: false)
        let result = await f.coordinator.migrate(f.work, to: f.b, from: "a", removingOld: false)
        XCTAssertEqual(result, .migrated); XCTAssertEqual(f.prefs.choice(for: f.work), ListingKey(f.b))
    }
    func testRepointItemNilCoverKeepsOldCover() {
        let f = fixture(); f.library.toggle(f.a)
        let other = manga("other", source: "other", cover: URL(string: "https://old/cover"))
        f.library.repointItem(from: ListingKey(f.a), to: ListingKey(other), coverURL: nil)
        XCTAssertEqual(f.library.item(for: ListingKey(other))?.coverURL, f.a.coverURL)
        f.library.toggle(f.b)
        let passed = URL(string: "https://passed/cover")!
        f.library.repointItem(from: ListingKey(other), to: ListingKey(f.b), coverURL: passed)
        XCTAssertEqual(f.library.items.count, 1)
        XCTAssertEqual(f.library.item(for: ListingKey(f.b))?.coverURL, passed)
    }
}

private actor MigrationCallLog {
    var chapters: [String] = []
    func record(_ id: String) { chapters.append(id) }
}

private struct CountingMigrationSource: MangaSource, @unchecked Sendable {
    let id: String
    let log = MigrationCallLog()
    var name: String { id }
    func askedIds() async -> [String] { await log.chapters }
    func chapters(mangaId: String) async throws -> [Chapter] {
        await log.record(mangaId)
        return [Chapter(id: "\(mangaId)-1", number: "1", title: nil)]
    }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
