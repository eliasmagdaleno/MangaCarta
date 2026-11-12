import XCTest
@testable import MangaCarta

@MainActor
final class AddSourceModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        directory = makeTestDirectory("AddSourceModel-\(UUID().uuidString)")
        defaults = makeTestDefaults("AddSourceModel-\(UUID().uuidString)")
    }

    private func manga(_ id: String, source: String, title: String = "Title", mal: Int? = nil,
                       alts: [String]? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: title, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: mal, altTitles: alts)
    }

    private func model(current: Manga, sources: [AddModelSource], mint: Bool = true,
                       deadline: TimeInterval = 0.4) -> (AddSourceModel, WorkStore, SourcePreferenceStore) {
        let works = WorkStore(directory: directory)
        if mint { _ = works.mint(from: current) }
        let registry = SourceRegistry(sources: sources, defaults: defaults)
        let preferences = SourcePreferenceStore(defaults: defaults, works: works)
        let counts = ListingCountCache(directory: directory)
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry, counts: counts, preferences: preferences)
        let coordinator = WorkSourcesCoordinator(works: works, preferences: preferences, fulfillment: fulfillment,
            library: LibraryStore(defaults: defaults, works: works, registry: registry),
            malChoices: MALSourceChoiceStore(directory: directory), updates: UpdateStateStore(directory: directory, works: works))
        let search = SourceTitleSearch(registry: registry, showAdultContent: false, deadline: deadline, probeInterval: 0.01)
        let loader = MALHubChapterCountLoader(registry: registry, cache: counts, deadline: 0.1)
        return (AddSourceModel(listing: current, registry: registry, works: works, coordinator: coordinator,
                               search: search, counts: loader), works, preferences)
    }

    func testGradesAndOrdersRows() async {
        let current = manga("current", source: "current", mal: 1)
        let source = AddModelSource(id: "other", results: [
            manga("same", source: "other", title: "Other", mal: 1),
            manga("likely", source: "other", title: "Title"),
            manga("different", source: "other", title: "Else", mal: 2),
            manga("unrelated", source: "other", title: "Completely unrelated")
        ])
        let (model, _, _) = model(current: current, sources: [AddModelSource(id: "current"), source])
        await model.start()
        XCTAssertEqual(model.groups[0].rows.map(\.grade), [.sameEntry, .likely, .ungraded, .differentEntry])
    }

    func testServingSourcesAreExcludedAndNoOtherSourcesIsReported() async {
        let current = manga("current", source: "current", mal: 1)
        let (model, _, _) = model(current: current, sources: [AddModelSource(id: "current")])
        await model.start()
        XCTAssertEqual(model.phase, .noOtherSources)
        XCTAssertEqual(model.emptyMessage, "No other Sources to search")
    }

    func testSubmitSearchesOnlyEditedQuery() async {
        let source = AddModelSource(id: "other")
        let current = manga("current", source: "current")
        let (model, _, _) = model(current: current, sources: [AddModelSource(id: "current"), source])
        model.query = "Edited"; await model.submit()
        let titles = await source.titles; XCTAssertEqual(titles, ["Edited"])
    }

    func testRetryReplacesOnlyOneGroup() async {
        let a = AddModelSource(id: "a"); let b = AddModelSource(id: "b")
        let (model, _, _) = model(current: manga("current", source: "current"),
                                  sources: [AddModelSource(id: "current"), a, b])
        await model.start(); let bCalls = await b.calls
        await model.retry(sourceId: "a")
        let calls = await b.calls; XCTAssertEqual(calls, bCalls)
        XCTAssertEqual(model.groups.map(\.sourceId), ["a", "b"])
    }

    func testPreviouslyRemovedCopyIsMarkedAndPickingLiftsRemoval() async {
        let current = manga("current", source: "current", mal: 1)
        let removed = manga("removed", source: "other", mal: nil)
        let (model, works, _) = model(current: current,
            sources: [AddModelSource(id: "current"), AddModelSource(id: "other", results: [removed])])
        let work = unwrap(works.workId(for: ListingKey(current)))
        XCTAssertEqual(works.addListing(removed, to: work, recordExternalIds: false), .added)
        _ = works.removeListing(ListingKey(removed), from: work, keepingReadState: true)
        await model.start()
        let row = unwrap(model.groups.flatMap(\.rows).first)
        XCTAssertTrue(row.wasRemovedEarlier); _ = await model.pick(row)
        XCTAssertTrue(works.work(work)?.listings.contains(ListingKey(removed)) == true)
    }

    func testPickingFreshRowMintsAndDoesNotPin() async {
        let current = manga("current", source: "current")
        let fresh = manga("fresh", source: "other", title: "Title")
        let (model, works, preferences) = model(current: current,
            sources: [AddModelSource(id: "current"), AddModelSource(id: "other", results: [fresh])], mint: false)
        await model.start()
        let row = unwrap(model.groups.flatMap(\.rows).first)
        let result = await model.pick(row); XCTAssertEqual(result, .added)
        let work = unwrap(works.workId(for: ListingKey(current)))
        XCTAssertTrue(works.work(work)?.listings.contains(ListingKey(fresh)) == true)
        XCTAssertNil(preferences.choice(for: work))
    }

    func testDifferentMALAsksAndAddAnywayPreservesWorkMAL() async {
        let current = manga("current", source: "current", mal: 1)
        let rowManga = manga("row", source: "other", mal: 2)
        let (model, works, _) = model(current: current,
            sources: [AddModelSource(id: "current"), AddModelSource(id: "other", results: [rowManga])])
        await model.start(); let row = unwrap(model.groups.flatMap(\.rows).first)
        let picked = await model.pick(row); XCTAssertEqual(picked, .confirmDifferentEntry(otherTitle: rowManga.title))
        let added = await model.addAnyway(row); XCTAssertEqual(added, .added)
        let work = unwrap(works.workId(for: ListingKey(current))); XCTAssertEqual(works.work(work)?.externalIds.mal, 1)
    }

    func testSingleCopyConflictConfirmsCombine() async {
        let current = manga("current", source: "current", mal: 1); let rowManga = manga("row", source: "other", mal: 1)
        let (model, works, _) = model(current: current,
            sources: [AddModelSource(id: "current"), AddModelSource(id: "other", results: [rowManga])])
        let targetBefore = unwrap(works.workId(for: ListingKey(current)))
        _ = works.mint(from: manga("row", source: "other", mal: 2))
        await model.start(); let row = unwrap(model.groups.flatMap(\.rows).first)
        let picked = await model.pick(row)
        XCTAssertEqual(picked, .confirmCombine(otherTitle: rowManga.title))
        let combined = await model.combine(row); XCTAssertEqual(combined, .added)
        XCTAssertTrue(works.allWorkIds().contains(targetBefore))
        XCTAssertEqual(works.allWorkIds().count, 1)
    }

    func testMultiCopyConflictConfirmsMoveAndRetiresCopy() async {
        let current = manga("current", source: "current", mal: 1); let rowManga = manga("row", source: "other", mal: 1)
        let (model, works, _) = model(current: current,
            sources: [AddModelSource(id: "current"), AddModelSource(id: "other", results: [rowManga])])
        let other = works.mint(from: manga("row", source: "other", mal: 2))
        _ = works.addListing(manga("second", source: "third", mal: 3), to: other, recordExternalIds: false)
        await model.start(); let row = unwrap(model.groups.flatMap(\.rows).first)
        let picked = await model.pick(row)
        XCTAssertEqual(picked, .confirmCombineOrMove(otherTitle: rowManga.title))
        let moved = await model.moveJustThisCopy(row); XCTAssertEqual(moved, .added)
        let target = unwrap(works.workId(for: ListingKey(current)))
        XCTAssertTrue(works.work(target)?.listings.contains(ListingKey(rowManga)) == true)
        XCTAssertTrue(works.work(other)?.removedListings.contains(where: { $0.key == ListingKey(rowManga) && $0.keepsReadState }) == true)
    }

    func testCountsOnlyTopThreeGradedRows() async {
        let current = manga("current", source: "current")
        let sources = (0..<4).map {
            AddModelSource(id: "s\($0)", results: [manga("m\($0)", source: "s\($0)", title: "Title")], chapterCount: 1)
        }
        let (model, _, _) = model(current: current, sources: [AddModelSource(id: "current")] + sources)
        await model.start()
        var calls: [Int] = []; for source in sources { calls.append(await source.chapterCalls) }
        XCTAssertEqual(calls, [1, 1, 1, 0])
    }
}

private func unwrap<T>(_ value: T?) -> T {
    guard let value else { fatalError("expected value") }
    return value
}

private actor AddModelSourceState { var calls = 0; var titles: [String] = []; var chapterCalls = 0 }

private struct AddModelSource: MangaSource, @unchecked Sendable {
    let id: String; let results: [Manga]; let chapterCount: Int?; let state = AddModelSourceState()
    var name: String { id }
    init(id: String, results: [Manga] = [], chapterCount: Int? = nil) { self.id = id; self.results = results; self.chapterCount = chapterCount }
    var calls: Int { get async { await state.calls } }; var titles: [String] { get async { await state.titles } }
    var chapterCalls: Int { get async { await state.chapterCalls } }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { await state.record(title); return results }
    func chapters(mangaId: String) async throws -> [Chapter] {
        await state.recordChapter()
        return (0..<(chapterCount ?? 0)).map { Chapter(id: "\($0)", number: "\($0)", title: nil) }
    }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { MangaDetail(description: "", authors: [], tags: [], contentRating: nil) }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

private extension AddModelSourceState {
    func record(_ title: String) { calls += 1; titles.append(title) }
    func recordChapter() { chapterCalls += 1 }
}
