import XCTest
@testable import MangaCarta

@MainActor
final class LibraryMigrationModelTests: XCTestCase {
    private func fixture(_ entries: [(String, Int?, [Manga])], bAvailable: Bool = true,
                         concurrency: Int = 4, gate: SearchGate? = nil, mintWork: Bool = true,
                         registerA: Bool = true, extraLibraryItems: [MangaCarta.LibraryItem] = []) -> Fixture {
        Fixture(entries: entries, bAvailable: bAvailable, concurrency: concurrency, gate: gate,
                mintWork: mintWork, registerA: registerA, directory: makeTestDirectory("LibraryMigration"),
                defaults: makeTestDefaults("LibraryMigration"), extraLibraryItems: extraLibraryItems)
    }

    private func assertStatus(_ results: [Manga], _ expected: LibraryMigrationStatus, referenceMAL: Int? = 1,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let f = fixture([("a1", referenceMAL, results)])
        await f.model.start(from: "a", to: "b")
        let rows = f.model.rows
        let actual = try XCTUnwrap(rows.first).status
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testOffersOnlySavedTitlesWithACopyOnFrom() async throws {
        let f = fixture([("a1", 1, [])])
        _ = f.works.mint(from: f.manga("unsaved", "a", 77))
        f.library.toggle(f.manga("c1", "c", 2))
        f.model.candidates(from: "a", to: "b")
        XCTAssertEqual(f.model.rows.map(\.item.id), ["a1"])
    }

    func testUninstalledFromIsOffered() async throws {
        let legacy = try XCTUnwrap(InstalledSourceIDMigration.legacyIDs.first)
        let f = fixture([("a1", 1, [])], registerA: false, extraLibraryItems: [
            LibraryItem(id: "local", title: "Local", coverURL: nil, sourceId: LocalSource.sourceID),
            LibraryItem(id: "legacy", title: "Legacy", coverURL: nil, sourceId: legacy),
            LibraryItem(id: "nil-source", title: "Old", coverURL: nil, sourceId: nil)
        ])
        f.model.refreshFromOptions()
        let option = try XCTUnwrap(f.model.fromOptions.first(where: { $0.sourceId == "a" }))
        XCTAssertEqual(option.name, "Source A")
        XCTAssertEqual(option.savedCount, 1)
        XCTAssertFalse(option.isInstalled)
        XCTAssertFalse(f.model.fromOptions.contains { $0.sourceId == LocalSource.sourceID })
        XCTAssertFalse(f.model.fromOptions.contains { $0.sourceId == legacy })
        XCTAssertFalse(f.model.fromOptions.contains { $0.sourceId == LegacySourceID.unattributed })
    }

    func testAlreadyOnTargetSkipsSearchAndIsReady() async throws {
        let f = fixture([("a1", 1, [filler()])])
        let work = try XCTUnwrap(f.works.workId(for: ListingKey(f.saved[0])))
        _ = f.works.addListing(f.manga("b1", "b", 1), to: work, recordExternalIds: false)
        await f.model.start(from: "a", to: "b")
        let row = try XCTUnwrap(f.model.rows.first)
        XCTAssertEqual(row.status, .ready); XCTAssertTrue(row.isTicked)
        let searches = await f.sourceB.searches()
        XCTAssertEqual(searches, [])
    }

    func testOneSameEntryIsReady() async throws { try await assertStatus([filler()], .ready) }
    func testTwoSameEntriesNeedPick() async throws { try await assertStatus([filler("b1"), filler("b2")], .needsPick) }
    func testOneLikelyIsReady() async throws {
        let likely = Manga(id: "b1", sourceId: "b", title: "Title a1", description: "", status: "unknown",
                           year: nil, coverURL: nil, malId: nil)
        try await assertStatus([likely], .ready, referenceMAL: nil)
    }
    func testLikelyBesideDifferentEntryNeedsPick() async throws {
        let likely = Manga(id: "likely", sourceId: "b", title: "Title a1", description: "", status: "unknown",
                           year: nil, coverURL: nil, malId: nil)
        try await assertStatus([likely, filler("different", mal: 9)], .needsPick)
    }

    func testRemovedEarlierIsNeverReady() async throws {
        let f = fixture([("a1", 1, [filler()])])
        let work = try XCTUnwrap(f.works.workId(for: ListingKey(f.saved[0])))
        let match = filler()
        _ = f.works.addListing(match, to: work, recordExternalIds: false)
        _ = f.works.removeListing(ListingKey(match), from: work, keepingReadState: true)
        await f.model.start(from: "a", to: "b")
        XCTAssertEqual(try XCTUnwrap(f.model.rows.first).status, .notFound)
    }

    func testMatchOwnedByOtherWorkIsNeverReady() async throws {
        let ownedResult = Manga(id: "b-owned", sourceId: "b", title: "Title a1", description: "",
                                status: "unknown", year: nil, coverURL: nil, malId: nil)
        let f = fixture([("a1", nil, [ownedResult])])
        let other = f.works.mint(from: f.manga("owned", "c", 9, title: "Other title"))
        _ = f.works.addListing(ownedResult, to: other, recordExternalIds: false)
        await f.model.start(from: "a", to: "b")
        let row = try XCTUnwrap(f.model.rows.first)
        XCTAssertNotEqual(row.status, .ready)
        XCTAssertEqual(row.choiceDetails.first?.otherWorkTitle, "Other title")
        XCTAssertEqual(f.model.pick(row.id, choice: try XCTUnwrap(row.choices.first)), .refusedOwnedByOtherWork)
        XCTAssertNotNil(f.works.work(other))
    }

    func testMatchWhoseMalIdAnotherWorkOwnsIsNeverReady() async throws {
        let malOwnedResult = Manga(id: "b1", sourceId: "b", title: "Title a1", description: "",
                                   status: "unknown", year: nil, coverURL: nil, malId: 1)
        let f = fixture([("a1", nil, [malOwnedResult])])
        _ = f.works.mint(from: f.manga("owner", "c", 1))
        await f.model.start(from: "a", to: "b")
        XCTAssertNotEqual(try XCTUnwrap(f.model.rows.first).status, .ready)
    }

    func testNoMoreThanFourTitlesSearchAtOnce() async throws {
        let gate = SearchGate(); let f = fixture((0..<10).map { ("a\($0)", $0 + 1, [filler("b\($0)", mal: $0 + 1)]) }, gate: gate)
        let task = Task { await f.model.start(from: "a", to: "b") }
        try await waitUntil { await gate.peakCount() >= 4 }
        try await Task.sleep(nanoseconds: 200_000_000)
        let peak = await gate.peakCount()
        XCTAssertEqual(peak, 4)
        await gate.releaseAll(); await task.value
    }

    func testCancelKeepsResultsAndWritesNothing() async throws {
        let gate = SearchGate()
        let f = fixture((0..<10).map { ("a\($0)", $0 + 1, [filler("b\($0)", mal: $0 + 1)]) }, gate: gate)
        let before = f.snapshot()
        let task = Task { await f.model.start(from: "a", to: "b") }
        try await waitUntil { await gate.startedCount() >= 4 }
        await gate.releaseFirst()
        try await waitUntil { f.model.searchedCount == 1 }
        let searchesAtCancel = await f.sourceB.searchedIds().count
        f.model.cancel(); await task.value
        XCTAssertEqual(f.model.searchedCount, 1)
        XCTAssertEqual(f.model.rows.filter { $0.status == LibraryMigrationStatus.ready }.count, 1)
        XCTAssertEqual(f.model.rows.filter { $0.status == LibraryMigrationStatus.notSearched }.count, 9)
        let searches = await f.sourceB.searchedIds()
        XCTAssertEqual(searches.count, searchesAtCancel)
        XCTAssertEqual(f.snapshot(), before)
    }

    func testCancellingTheStartTaskCancelsSearches() async throws {
        let gate = SearchGate()
        let f = fixture((0..<10).map { ("a\($0)", $0 + 1, [filler("b\($0)", mal: $0 + 1)]) }, gate: gate)
        let before = f.snapshot()
        let task = Task { await f.model.start(from: "a", to: "b") }
        try await waitUntil { await gate.startedCount() >= 4 }
        let startedAtCancel = await f.sourceB.searchedIds().count
        task.cancel()
        await task.value
        let searchesAfterCancel = await f.sourceB.searchedIds().count
        XCTAssertEqual(searchesAfterCancel, startedAtCancel)
        XCTAssertEqual(f.model.rows.filter { $0.status == LibraryMigrationStatus.notSearched }.count, 10)
        XCTAssertEqual(f.snapshot(), before)
    }

    func testUnavailableTargetIsCouldNotCheck() async throws {
        let f = fixture([("a1", 1, [])], bAvailable: false)
        await f.model.start(from: "a", to: "b")
        XCTAssertEqual(try XCTUnwrap(f.model.rows.first).status, .couldNotCheck)
    }

    func testCouldNotCheckRetryMergesIn() async throws {
        let f = fixture([("a1", 1, [filler()]), ("a2", 2, [filler("b2", mal: 2)])])
        await f.sourceB.failNext("Title a1")
        await f.model.start(from: "a", to: "b")
        let first = try XCTUnwrap(f.model.rows.first(where: { $0.item.id == "a1" }))
        let oldOther = try XCTUnwrap(f.model.rows.first(where: { $0.item.id == "a2" }))
        XCTAssertEqual(first.status, .couldNotCheck)
        await f.model.retry(first.id, to: "b")
        XCTAssertEqual(f.model.rows.first(where: { $0.id == first.id })?.status, .ready)
        XCTAssertEqual(f.model.rows.first(where: { $0.id == oldOther.id })?.status, oldOther.status)
    }

    func testNeedsPickRowCanBePicked() async throws {
        let f = fixture([("a1", 1, [filler("b1"), filler("b2")])])
        await f.model.start(from: "a", to: "b")
        var row = try XCTUnwrap(f.model.rows.first)
        XCTAssertEqual(f.model.pick(row.id, choice: try XCTUnwrap(row.choices.first)), .picked)
        row = try XCTUnwrap(f.model.rows.first)
        XCTAssertTrue(row.isTicked); XCTAssertNotNil(row.chosen)
        let different = filler("different", mal: 9)
        let f2 = fixture([("a2", 1, [different])])
        await f2.model.start(from: "a", to: "b")
        let row2 = try XCTUnwrap(f2.model.rows.first)
        XCTAssertEqual(f2.model.pick(row2.id, choice: try XCTUnwrap(row2.choices.first)),
                       .confirmDifferentEntry(otherTitle: "Title"))
        XCTAssertEqual(f2.model.pick(row2.id, choice: try XCTUnwrap(row2.choices.first), confirmDifferentEntry: true), .picked)
    }

    func testEveryReadyRowIsCounted() async throws {
        let f = fixture((0..<5).map { ("a\($0)", $0 + 1, [filler("b\($0)", mal: $0 + 1)]) })
        await f.sourceB.setChapterCount(3, except: "b4")
        await f.model.start(from: "a", to: "b")
        let chapterCalls = await f.sourceB.chaptersCount()
        XCTAssertEqual(chapterCalls, 5)
        XCTAssertTrue(f.model.rows.allSatisfy { $0.chosen?.countRequested == true })
        XCTAssertNil(f.model.rows.first(where: { $0.item.id == "a4" })?.chosen?.chapterCount)
    }

    func testApplyRechecksAndReportsSkips() async throws {
        let f = fixture((0..<2).map { ("a\($0)", $0 + 1, [filler("b\($0)", mal: $0 + 1)]) })
        await f.model.start(from: "a", to: "b")
        _ = f.works.mint(from: f.manga("b0", "b", 20))
        let result = await f.model.apply(removingOld: false)
        XCTAssertEqual(result.migratedCount, 1)
        let otherWork = try XCTUnwrap(f.works.workId(for: ListingKey(f.manga("b0", "b", 20))))
        XCTAssertEqual(result.skipped.first?.reason, .belongsToOtherWork(otherWork))
    }

    func testApplyFlushesWorkStore() async throws {
        let f = fixture([("a1", 1, [filler()])])
        await f.model.start(from: "a", to: "b"); _ = await f.model.apply(removingOld: false)
        let fresh = WorkStore(directory: f.directory)
        let work = try XCTUnwrap(fresh.workId(for: ListingKey(f.saved[0])))
        XCTAssertTrue(try XCTUnwrap(fresh.work(work)).listings.contains(ListingKey(f.manga("b1", "b", 1))))
        XCTAssertEqual(f.refreshCalls, 1)
    }

    func testApplyCreatesWorkForItemWithoutOne() async throws {
        let match = Manga(id: "b1", sourceId: "b", title: "Title a1", description: "", status: "unknown",
                          year: nil, coverURL: nil, malId: nil)
        let f = fixture([("a1", nil, [match])], mintWork: false)
        await f.model.start(from: "a", to: "b")
        XCTAssertEqual(f.model.rows.first?.status, .ready)
        XCTAssertTrue(f.model.rows.first?.isTicked == true)
        _ = await f.model.apply(removingOld: false)
        let work = try XCTUnwrap(f.works.workId(for: ListingKey(f.saved[0])))
        XCTAssertTrue(try XCTUnwrap(f.works.work(work)).listings.contains(ListingKey(f.manga("b1", "b", 1))))
        XCTAssertNotNil(f.library.item(for: ListingKey(f.manga("b1", "b", 1))))
    }

    func testSummaryCounts() async throws {
        let f = fixture([("a1", 1, [filler()]), ("a2", 2, [])])
        await f.model.start(from: "a", to: "b")
        let result = await f.model.apply(removingOld: false)
        XCTAssertEqual(result.migratedCount, 1); XCTAssertEqual(result.skipped.count, 0)
    }

    func testSearchMakesNoWrites() async throws {
        let f = fixture((0..<5).map { ("a\($0)", $0 + 1, [filler("b\($0)", mal: $0 + 1)]) }, mintWork: false)
        let before = f.snapshot()
        await f.model.start(from: "a", to: "b")
        XCTAssertEqual(f.snapshot(), before)
        XCTAssertTrue(f.works.allWorkIds().isEmpty)
        let chapterCalls = await f.sourceB.chaptersCount()
        XCTAssertEqual(chapterCalls, 0)
        let searches = await f.sourceB.searches()
        XCTAssertEqual(searches.count, 5)
    }

    func testAlreadyOnTargetAppliesToTargetNotThirdSource() async throws {
        let f = fixture([("a1", 1, [])])
        let work = try XCTUnwrap(f.works.workId(for: ListingKey(f.saved[0])))
        _ = f.works.addListing(f.manga("b1", "b", 1), to: work, recordExternalIds: false)
        _ = f.works.addListing(f.manga("c1", "c", 1), to: work, recordExternalIds: false)
        await f.model.start(from: "a", to: "b"); _ = await f.model.apply(removingOld: false)
        XCTAssertEqual(f.preferences.choice(for: work), ListingKey(f.manga("b1", "b", 1)))
        XCTAssertNotNil(f.library.item(for: ListingKey(f.manga("b1", "b", 1))))
    }

    func testOwnedResultBesideSameEntryStillReady() async throws {
        let owned = filler("b-owned", mal: 9)
        let f = fixture([("a1", 1, [filler("b-same", mal: 1), owned])])
        _ = f.works.mint(from: f.manga(owned.id, "b", 9, title: "Unrelated"))
        await f.model.start(from: "a", to: "b")
        XCTAssertEqual(try XCTUnwrap(f.model.rows.first).status, .ready)
        XCTAssertEqual(f.model.rows.first?.chosen?.id, ListingKey(f.manga("b-same", "b", 1)))
    }

    func testCannotTickRowWithoutMatch() async throws {
        let f = fixture([("a1", 1, []), ("a2", 2, [filler("b1", mal: 2), filler("b2", mal: 2)])])
        await f.model.start(from: "a", to: "b")
        for row in f.model.rows { f.model.toggle(row.id) }
        XCTAssertTrue(f.model.rows.allSatisfy { !$0.isTicked })
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let defaults: UserDefaults
    let works: WorkStore
    let library: LibraryStore
    let preferences: SourcePreferenceStore
    let model: LibraryMigrationModel
    let saved: [Manga]
    let sourceB: MigrationFakeSource
    private let refreshCounter = MigrationRefreshCounter()
    var refreshCalls: Int { refreshCounter.value }

    init(entries: [(String, Int?, [Manga])], bAvailable: Bool, concurrency: Int,
         gate: SearchGate?, mintWork: Bool, registerA: Bool, directory: URL, defaults: UserDefaults,
         extraLibraryItems: [MangaCarta.LibraryItem]) {
        self.directory = directory; self.defaults = defaults
        let workStore = WorkStore(directory: directory)
        works = workStore
        let a = MigrationFakeSource(id: "a", name: "Source A")
        let results = Dictionary(uniqueKeysWithValues: entries.map { entry in
            ("Title \(entry.0)", entry.2)
        })
        sourceB = MigrationFakeSource(id: "b", results: results, gate: gate)
        let c = MigrationFakeSource(id: "c")
        let registry = SourceRegistry(sources: (registerA ? [a] : []) + (bAvailable ? [sourceB] : []) + [c], defaults: defaults)
        if !extraLibraryItems.isEmpty,
           let encoded = try? JSONEncoder().encode(extraLibraryItems) {
            defaults.set(encoded, forKey: "library.items")
        }
        let libraryStore = LibraryStore(defaults: defaults, works: mintWork ? workStore : nil, registry: registry)
        library = libraryStore
        saved = entries.map { id, mal, _ in
            let manga = Manga(id: id, sourceId: "a", title: "Title \(id)", description: "", status: "unknown",
                              year: nil, coverURL: nil, malId: mal)
            if mintWork { _ = workStore.mint(from: manga) }
            libraryStore.toggle(manga)
            return manga
        }
        preferences = SourcePreferenceStore(defaults: defaults, works: works)
        let countCache = ListingCountCache(directory: directory)
        let fulfillment = FulfillmentCoordinator(works: workStore, registry: registry, counts: countCache, preferences: preferences)
        let coordinator = WorkSourcesCoordinator(works: workStore, preferences: preferences, fulfillment: fulfillment,
            library: libraryStore, malChoices: MALSourceChoiceStore(directory: directory),
            updates: UpdateStateStore(directory: directory, works: workStore))
        let search = SourceTitleSearch(registry: registry, showAdultContent: false, challengeActive: { false },
                                       deadline: 0.5, probeInterval: 0.01)
        let counts = MALHubChapterCountLoader(registry: registry, cache: countCache,
                                               challengeActive: { false }, deadline: 0.1)
        let refreshCounter = self.refreshCounter
        model = LibraryMigrationModel(library: libraryStore, works: workStore, coordinator: coordinator, registry: registry,
            search: search, counts: counts, sourceName: { $0 == "a" ? "Source A" : nil },
            requestRefresh: { refreshCounter.increment() }, concurrency: concurrency)
    }

    func manga(_ id: String, _ source: String, _ mal: Int?, title: String = "Title") -> Manga {
        Manga(id: id, sourceId: source, title: title, description: "", status: "unknown", year: nil,
              coverURL: nil, malId: mal)
    }
    func snapshot() -> String {
        let lib = library.items.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.sourceId ?? "nil"): \($0.title)"
        }.joined(separator: "|")
        let workData = (try? Data(contentsOf: directory.appendingPathComponent("works.json"))) ?? Data()
        let pins = works.allWorkIds().sorted { $0.raw.uuidString < $1.raw.uuidString }.map { workID in
            let key = preferences.choice(for: workID)
            return "\(workID.raw.uuidString)=\(key?.sourceId ?? "nil")/\(key?.mangaId ?? "nil")"
        }.joined(separator: "|")
        return "\(lib)|\(workData.base64EncodedString())|\(pins)"
    }
}

private func filler(_ id: String = "b1", mal: Int? = 1) -> Manga {
    Manga(id: id, sourceId: "b", title: "Title", description: "", status: "unknown", year: nil, coverURL: nil, malId: mal)
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
        guard Date() < deadline else { throw NSError(domain: "LibraryMigrationTests", code: 1) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private actor SearchGate {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var started = 0
    private(set) var peak = 0
    private var active = 0
    func wait(_ id: Int) async {
        if Task.isCancelled { return }
        started += 1; active += 1; peak = max(peak, active)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuations[id] = $0 }
        } onCancel: {
            Task { await self.release(id) }
        }
        active -= 1
    }
    func release(_ id: Int) { continuations.removeValue(forKey: id)?.resume() }
    func releaseFirst() { continuations.keys.sorted().first.map(release) }
    func releaseAll() { for continuation in continuations.values { continuation.resume() }; continuations.removeAll() }
    func startedCount() -> Int { started }
    func peakCount() -> Int { peak }
}

private struct MigrationFakeSource: MangaSource, @unchecked Sendable {
    let id: String
    let name: String
    let state: MigrationFakeState
    init(id: String, name: String? = nil, results: [String: [Manga]] = [:], gate: SearchGate? = nil) {
        self.id = id; self.name = name ?? id
        state = MigrationFakeState(results: results, gate: gate)
    }
    func searches() async -> [String] { await state.searches }
    func searchedIds() async -> [String] { await state.searchedIds }
    func chaptersCount() async -> Int { await state.chapterCalls }
    func failNext(_ title: String) async { await state.addFailure(title) }
    func setChapterCount(_ count: Int, except: String? = nil) async { await state.configureCount(count, except: except) }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        let configured = await state.begin(title)
        if let number = Int(title.replacingOccurrences(of: "Title a", with: "")), let gate = state.gate { await gate.wait(number) }
        if configured.1 { throw URLError(.notConnectedToInternet) }
        return configured.0
    }
    func chapters(mangaId: String) async throws -> [Chapter] {
        let config = await state.countConfig(mangaId)
        guard let count = config else { throw URLError(.notConnectedToInternet) }
        return (0..<count).map { Chapter(id: "\($0)", number: "\($0)", title: nil) }
    }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { MangaDetail(description: "", authors: [], tags: [], contentRating: nil) }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

private actor MigrationFakeState {
    let results: [String: [Manga]]
    let gate: SearchGate?
    var failures: Set<String> = []
    var searches: [String] = []
    var searchedIds: [String] = []
    var chapterCalls = 0
    var chapterCount: Int?
    var missingCountId: String?
    init(results: [String: [Manga]], gate: SearchGate?) { self.results = results; self.gate = gate }
    func begin(_ title: String) -> ([Manga], Bool) {
        searches.append(title); searchedIds.append(title)
        return (results[title] ?? [], failures.remove(title) != nil)
    }
    func addFailure(_ title: String) { failures.insert(title) }
    func configureCount(_ count: Int, except: String?) { chapterCount = count; missingCountId = except }
    func countConfig(_ id: String) -> Int? {
        chapterCalls += 1
        return id == missingCountId ? nil : chapterCount
    }
}

private final class MigrationRefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
