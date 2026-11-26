import Foundation
import Testing
@testable import MangaCarta

/// The Updates screen's grouping (spec 2026-11-09, slice 1). Every test pins the calendar,
/// time zone and "now", so none depends on the machine running it.
@Suite("Updates presentation")
struct UpdatesPresentationTests {
    // 2026-11-25 12:00 in Los Angeles (UTC-8 in November) is 20:00 UTC.
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test("Works group by the local day of their newest discovery, then newest ordinal first")
    func groupsWorksByNewestDiscoveryLocalDayThenOrdinal() {
        let calendar = Self.calendar(Self.losAngeles)
        let now = Self.date("2026-11-25T12:00:00-08:00")
        let today = Self.summary("Today Work", discoveredAt: Self.date("2026-11-25T09:00:00-08:00"))
        let older = Self.summary("Older Work", discoveredAt: Self.date("2026-11-20T09:00:00-08:00"))

        let timeline = UpdatesTimeline(
            summaries: [older, today],
            newlyDiscovered: [today.id: [Self.ordinal("10"), Self.ordinal("12"), Self.ordinal("11")],
                              older.id: [Self.ordinal("3")]],
            calendar: calendar, now: now, locale: Locale(identifier: "en_US"))

        #expect(timeline.sections.map(\.day) == [
            .today, .date(calendar.startOfDay(for: Self.date("2026-11-20T09:00:00-08:00")))
        ])
        #expect(timeline.sections.map(\.title) == ["Today", "Nov 20, 2026"])
        #expect(timeline.sections.map { $0.works.map(\.id) } == [[today.id], [older.id]])
        #expect(timeline.sections.first?.works.first?.ordinals
            == [Self.ordinal("12"), Self.ordinal("11"), Self.ordinal("10")])
        #expect(timeline.newChapterCount == 4)
        #expect(timeline.workIds == [today.id, older.id])
    }

    @Test("Just before local midnight is yesterday; just after is today")
    func localMidnightBoundary() {
        let calendar = Self.calendar(Self.losAngeles)
        let now = Self.date("2026-11-25T08:00:00-08:00")
        let before = Self.summary("Before", discoveredAt: Self.date("2026-11-24T23:59:59-08:00"))
        let after = Self.summary("After", discoveredAt: Self.date("2026-11-25T00:00:01-08:00"))

        let timeline = Self.timeline([before, after], calendar: calendar, now: now)

        #expect(timeline.sections.map(\.day) == [.today, .yesterday])
        #expect(timeline.sections.map(\.title) == ["Today", "Yesterday"])
        #expect(timeline.sections.map { $0.works.map(\.id) } == [[after.id], [before.id]])
    }

    @Test("The day follows the device's current time zone, not the one the discovery happened in")
    func timeZoneChangeRegroups() {
        // 2026-11-25 07:30 UTC: still the 24th in Los Angeles, already the 25th in Tokyo.
        let discovered = Self.date("2026-11-25T07:30:00Z")
        let now = Self.date("2026-11-25T10:00:00Z")
        let work = Self.summary("Traveller", discoveredAt: discovered)

        let inLosAngeles = Self.timeline([work], calendar: Self.calendar(Self.losAngeles), now: now)
        let inTokyo = Self.timeline([work], calendar: Self.calendar(Self.tokyo), now: now)

        #expect(inLosAngeles.sections.map(\.day) == [.yesterday])
        #expect(inTokyo.sections.map(\.day) == [.today])
    }

    @Test("Within a day, newest discovery first, then title; days newest first")
    func orderingWithinAndBetweenGroups() {
        let calendar = Self.calendar(Self.losAngeles)
        let now = Self.date("2026-11-25T20:00:00-08:00")
        let morning = Self.summary("Alpha", discoveredAt: Self.date("2026-11-25T08:00:00-08:00"))
        let evening = Self.summary("Zeta", discoveredAt: Self.date("2026-11-25T19:00:00-08:00"))
        let tieB = Self.summary("Bravo", discoveredAt: Self.date("2026-11-25T08:00:00-08:00"))
        let twoDaysAgo = Self.summary("Delta", discoveredAt: Self.date("2026-11-23T08:00:00-08:00"))
        let yesterday = Self.summary("Echo", discoveredAt: Self.date("2026-11-24T08:00:00-08:00"))

        let timeline = Self.timeline([twoDaysAgo, morning, tieB, yesterday, evening],
                                     calendar: calendar, now: now)

        #expect(timeline.sections.map(\.day) == [
            .today, .yesterday, .date(calendar.startOfDay(for: twoDaysAgo.newestDiscoveryAt!))
        ])
        #expect(timeline.sections.first?.works.map(\.summary.displayManga.title) == ["Zeta", "Alpha", "Bravo"])
    }

    @Test("A Work with discoveries but no discovery date goes last, by title")
    func undatedWorksGoLast() {
        let calendar = Self.calendar(Self.losAngeles)
        let now = Self.date("2026-11-25T12:00:00-08:00")
        let undatedB = Self.summary("Bravo", discoveredAt: nil)
        let undatedA = Self.summary("Alpha", discoveredAt: nil)
        let dated = Self.summary("Charlie", discoveredAt: Self.date("2026-01-01T12:00:00-08:00"))

        let timeline = Self.timeline([undatedB, dated, undatedA], calendar: calendar, now: now)

        #expect(timeline.sections.map(\.day).last == .unknown)
        #expect(timeline.sections.last?.title == "Date unknown")
        #expect(timeline.sections.last?.works.map(\.summary.displayManga.title) == ["Alpha", "Bravo"])
    }

    @Test("Nothing newly discovered is the empty state, even with discovery dates on record")
    func emptyState() {
        let calendar = Self.calendar(Self.losAngeles)
        let now = Self.date("2026-11-25T12:00:00-08:00")
        let seen = Self.summary("Seen", discoveredAt: Self.date("2026-11-25T09:00:00-08:00"))

        let timeline = UpdatesTimeline(summaries: [seen], newlyDiscovered: [seen.id: []],
                                       calendar: calendar, now: now)
        let none = UpdatesTimeline(summaries: [], newlyDiscovered: [:], calendar: calendar, now: now)

        #expect(timeline.isEmpty)
        #expect(timeline.workIds.isEmpty)
        #expect(timeline.newChapterCount == 0)
        #expect(none.isEmpty)
    }

    @Test("A muted Work still appears in the in-app inbox")
    func mutedWorkStillAppears() {
        let calendar = Self.calendar(Self.losAngeles)
        let now = Self.date("2026-11-25T12:00:00-08:00")
        let muted = Self.summary("Muted", discoveredAt: Self.date("2026-11-25T09:00:00-08:00"), isMuted: true)

        let timeline = Self.timeline([muted], calendar: calendar, now: now)

        #expect(timeline.workIds == [muted.id])
        #expect(timeline.sections.first?.works.first?.summary.isMuted == true)
    }

    @MainActor
    @Test("Two Listings of one Work produce one group and one count")
    func multipleListingsProduceOneWorkGroup() throws {
        let fixture = try StoreFixture()
        fixture.save("listing-a", sourceId: "mangadex")
        fixture.save("listing-b", sourceId: "weebcentral")
        let firstKey = ListingKey(sourceId: "mangadex", mangaId: "listing-a")
        let secondKey = ListingKey(sourceId: "weebcentral", mangaId: "listing-b")
        let winner = try #require(fixture.works.workId(for: firstKey))
        let loser = try #require(fixture.works.workId(for: secondKey))
        #expect(winner != loser, "the merge below is what makes them one Work")
        let discovered = Self.date("2026-11-25T09:00:00-08:00")
        _ = fixture.updates.absorb(workId: winner, listing: firstKey, rawNumbers: ["1"], now: discovered)
        _ = fixture.updates.absorb(workId: winner, listing: firstKey, rawNumbers: ["1", "2"], now: discovered)
        _ = fixture.updates.absorb(workId: loser, listing: secondKey, rawNumbers: ["1"], now: discovered)
        _ = fixture.updates.absorb(workId: loser, listing: secondKey, rawNumbers: ["1", "2"], now: discovered)
        #expect(fixture.works.merge(loser, into: winner))
        fixture.updates.reconcileMerges(using: fixture.works)

        let summaries = LibraryUpdatesPresentation.summaries(
            works: fixture.works, library: fixture.library, history: fixture.history,
            updates: fixture.updates, registry: fixture.registry, now: discovered)
        let timeline = UpdatesTimeline(summaries: summaries, updates: fixture.updates,
                                       calendar: Self.calendar(Self.losAngeles), now: discovered)

        #expect(timeline.workIds == [winner])
        #expect(timeline.sections.first?.works.first?.ordinals == [Self.ordinal("2")])
        #expect(timeline.newChapterCount == 1)
    }

    @Test("Two Works with the same title and the same discovery time order by id, whatever the input order")
    func sameTitleSameTimeTieBreaksOnId() {
        let calendar = Self.calendar(Self.losAngeles)
        let now = Self.date("2026-11-25T12:00:00-08:00")
        let at = Self.date("2026-11-25T09:00:00-08:00")
        let first = Self.summary("Twin", discoveredAt: at)
        let second = Self.summary("Twin", discoveredAt: at)
        let expected = [first.id, second.id].sorted { $0.raw.uuidString < $1.raw.uuidString }

        let forward = Self.timeline([first, second], calendar: calendar, now: now)
        let backward = Self.timeline([second, first], calendar: calendar, now: now)

        #expect(forward.workIds == expected)
        #expect(backward.workIds == expected)
    }

    // MARK: - Helpers

    private static func timeline(_ summaries: [WorkUpdateSummary],
                                 calendar: Calendar, now: Date) -> UpdatesTimeline {
        UpdatesTimeline(summaries: summaries,
                        newlyDiscovered: Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, [ordinal("1")]) }),
                        calendar: calendar, now: now, locale: Locale(identifier: "en_US"))
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// A malformed literal is a typo in this file; `distantPast` makes every expectation on it fail.
    private static func date(_ iso: String) -> Date {
        (try? Date(iso, strategy: .iso8601)) ?? .distantPast
    }

    private static func ordinal(_ raw: String) -> ChapterOrdinal {
        ChapterOrdinal.parse(raw) ?? ChapterOrdinal(value: 0)
    }

    private static func summary(_ title: String, discoveredAt: Date?, isMuted: Bool = false) -> WorkUpdateSummary {
        WorkUpdateSummary(
            id: WorkID(),
            displayManga: Manga(id: title, sourceId: "mangadex", title: title, description: "",
                                status: "ongoing", year: nil, coverURL: nil, malId: nil),
            unreadChapterCount: 0,
            newlyDiscoveredCount: 1,
            newestDiscoveryAt: discoveredAt,
            lastSuccessfulCheck: nil,
            freshness: .fresh,
            recoverySummaries: [],
            isMuted: isMuted)
    }
}

@MainActor
private final class StoreFixture {
    let testDirectory = TestDirectory("UpdatesPresentationTests")
    let suite = TestDefaults("UpdatesPresentationTests")
    let works: WorkStore
    let library: LibraryStore
    let history: HistoryStore
    let updates: UpdateStateStore
    let registry: SourceRegistry

    deinit { testDirectory.remove() }

    init() throws {
        let directory = testDirectory.url
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry = SourceRegistry(sources: [StubSource(id: "mangadex", name: "MangaDex"),
                                            StubSource(id: "weebcentral", name: "WeebCentral")],
                                  defaults: suite.defaults)
        works = WorkStore(directory: directory)
        library = LibraryStore(defaults: suite.defaults, works: works, registry: registry)
        history = HistoryStore(defaults: suite.defaults, works: works)
        updates = UpdateStateStore(directory: directory, works: works)
    }

    func save(_ id: String, sourceId: String) {
        library.toggle(Manga(id: id, sourceId: sourceId, title: "Shared Title", description: "",
                             status: "ongoing", year: nil, coverURL: nil, malId: nil))
    }
}

private struct StubSource: MangaSource {
    let id: String
    let name: String
    let isNSFW = false
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { throw SourceError.unsupported("detail") }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    func webURL(forManga id: String) async throws -> URL? { nil }
}

// MARK: - Updates screen (slice 2)

/// The screen's chapter loader, row mapping and Mark all seen (spec 2026-11-09, slice 2).
@MainActor
@Suite("Updates screen")
struct UpdatesScreenTests {

    @Test("At most four chapter requests run at once; the rest start as slots free up")
    func loaderCapsConcurrentRequestsAtFour() async throws {
        let gate = ChapterGate()
        let loader = UpdatesChapterLoader(resolve: Self.resolver(GatedSource(gate: gate)))
        let works = (0..<6).map { _ in WorkID() }
        for (index, work) in works.enumerated() {
            loader.request(work, displayManga: Self.manga("work-\(index)"))
        }

        try await Self.until { await gate.started.count == 4 }
        #expect(loader.inFlight == 4)
        await Self.settle()
        #expect(await gate.started.count == 4, "a fifth request must wait for a free slot")

        await gate.releaseOne()
        try await Self.until { await gate.started.count == 5 }
        await Self.settle()
        #expect(await gate.started.count == 5)
        #expect(loader.inFlight == 4)

        await gate.openAndReleaseAll()
        try await Self.until { loader.inFlight == 0 }
        #expect(await gate.peak == 4)
        #expect(await gate.started == (0..<6).map { "work-\($0)" }, "queued requests start in arrival order")
        for work in works {
            guard case .loaded? = loader.resolutions[work] else {
                Issue.record("every queued Work eventually loads"); return
            }
        }
    }

    @Test("Nothing is fetched until a Work is asked for, and an answered Work is not fetched twice")
    func loaderFetchesLazilyAndOnce() async throws {
        let gate = ChapterGate(open: true)
        let loader = UpdatesChapterLoader(resolve: Self.resolver(GatedSource(gate: gate)))
        let asked = WorkID()
        let notAsked = WorkID()
        await Self.settle()
        #expect(await gate.started.isEmpty, "building the loader fetches nothing")

        loader.request(asked, displayManga: Self.manga("asked"))
        loader.request(asked, displayManga: Self.manga("asked"))
        try await Self.until { loader.inFlight == 0 }
        loader.request(asked, displayManga: Self.manga("asked"))
        await Self.settle()

        #expect(await gate.started == ["asked"])
        #expect(loader.resolutions[notAsked] == nil)
        guard case .loaded(let manga, let chapters)? = loader.resolutions[asked] else {
            Issue.record("the asked Work loads"); return
        }
        #expect(manga.id == "asked")
        #expect(chapters.map(\.number) == ["1", "2", "3"])
    }

    @Test("A failing Source is a failure, not an empty list, and Try Again fetches again")
    func loaderKeepsFailuresAndRetries() async throws {
        let gate = ChapterGate(open: true)
        let work = WorkID()
        let loader = UpdatesChapterLoader(resolve: Self.resolver(GatedSource(gate: gate, fails: true)))

        loader.request(work, displayManga: Self.manga("broken"))
        try await Self.until { loader.inFlight == 0 }
        guard case .failed? = loader.resolutions[work] else {
            Issue.record("a thrown error is a failure"); return
        }

        loader.request(work, displayManga: Self.manga("broken"))
        await Self.settle()
        #expect(await gate.started.count == 1, "a plain request does not retry a failure")
        loader.retry(work, displayManga: Self.manga("broken"))
        try await Self.until { await gate.started.count == 2 }
    }

    @Test("No registered Source is unavailable, with no request made")
    func loaderReportsUnavailableSource() async {
        let loader = UpdatesChapterLoader(resolve: { _, _ in nil })
        let work = WorkID()
        loader.request(work, displayManga: Self.manga("gone"))
        guard case .sourceUnavailable? = loader.resolutions[work] else {
            Issue.record("an unresolvable Work is unavailable"); return
        }
        #expect(loader.inFlight == 0)
    }

    @Test("After a refresh, shown Works fetch again while keeping their rows; others are forgotten")
    func loaderInvalidatesAfterRefresh() async throws {
        let gate = ChapterGate(open: true)
        let loader = UpdatesChapterLoader(resolve: Self.resolver(GatedSource(gate: gate)))
        let kept = WorkID()
        let dropped = WorkID()
        loader.request(kept, displayManga: Self.manga("kept"))
        loader.request(dropped, displayManga: Self.manga("dropped"))
        try await Self.until { loader.inFlight == 0 }

        loader.invalidate(keeping: [kept])
        #expect(loader.resolutions[dropped] == nil)
        guard case .loaded? = loader.resolutions[kept] else {
            Issue.record("a stale answer stays until replaced"); return
        }
        loader.request(kept, displayManga: Self.manga("kept"))
        guard case .loaded? = loader.resolutions[kept] else {
            Issue.record("refetching does not blank the rows"); return
        }
        try await Self.until { loader.inFlight == 0 }
        #expect(await gate.started == ["kept", "dropped", "kept"])
    }

    @Test("An ordinal missing from fetched chapters stays visible; order is discovery order, not the Source's")
    func keepsUnknownChapterOrdinalVisible() {
        let ordinals = ["4", "3", "2"].compactMap(ChapterOrdinal.parse)
        let chapters = [
            Chapter(id: "c2-group-a", number: "2", title: nil),
            Chapter(id: "c3", number: "3", title: nil),
            Chapter(id: "c2-group-b", number: "2.0", title: nil),
        ]

        let rows = UpdatesChapterRow.rows(ordinals: ordinals, chapters: chapters)

        #expect(rows.map(\.ordinal) == ordinals)
        guard rows.count == 3,
              case .unmatched = rows[0],
              case .chapter(_, let three) = rows[1],
              case .chapter(_, let two) = rows[2] else {
            Issue.record("unexpected rows: \(rows)"); return
        }
        #expect(three.id == "c3")
        #expect(two.id == "c2-group-a", "the Source's first chapter for an ordinal wins")

        let pending = UpdatesChapterRow.rows(ordinals: ordinals, chapters: nil)
        #expect(pending.allSatisfy { if case .pending = $0 { true } else { false } })
    }

    @Test("Mark all seen clears exactly the displayed Works, once, and touches nothing read")
    func markAllSeenIsIdempotentAndScopedToLibrary() throws {
        let fixture = try ScreenFixture()
        let saved = Self.manga("saved", source: "stub")
        fixture.library.toggle(saved)
        let savedWork = fixture.works.mint(from: saved)
        let unsaved = Self.manga("unsaved", source: "stub")
        let unsavedWork = fixture.works.mint(from: unsaved)
        for (work, manga) in [(savedWork, saved), (unsavedWork, unsaved)] {
            _ = fixture.updates.absorb(workId: work, listing: ListingKey(manga), rawNumbers: ["1"])
            _ = fixture.updates.absorb(workId: work, listing: ListingKey(manga), rawNumbers: ["1", "2"])
        }
        fixture.history.markRead(manga: saved, chapter: Chapter(id: "saved-1", number: "1", title: nil))
        let frontier = fixture.updates.state(for: savedWork)?.frontier
        let readBefore = fixture.history.readOrdinals(forListings: [ListingKey(saved)])

        let timeline = fixture.timeline()
        #expect(timeline.workIds == [savedWork], "precondition: only the saved Work is shown")
        timeline.markAllSeen(in: fixture.updates)
        timeline.markAllSeen(in: fixture.updates)

        #expect(fixture.updates.state(for: savedWork)?.newlyDiscovered.isEmpty == true)
        #expect(fixture.updates.state(for: unsavedWork)?.newlyDiscovered.isEmpty == false,
                "a Work outside the Library keeps its discoveries")
        #expect(fixture.updates.state(for: savedWork)?.frontier == frontier)
        #expect(fixture.history.readOrdinals(forListings: [ListingKey(saved)]) == readBefore)
        #expect(fixture.timeline().isEmpty, "the screen falls to its up-to-date state")
        let summary = try #require(fixture.summaries().first)
        #expect(summary.unreadChapterCount == 1, "chapter 2 is seen, not read")
    }

    @Test("The live resolver follows the Work's pinned Listing, and is nil when no Source serves it")
    func liveResolverUsesFulfillment() throws {
        let fixture = try ScreenFixture()
        let display = Self.manga("primary", source: "stub")
        let alternate = Self.manga("alternate", source: "alt")
        let work = fixture.works.mint(from: display)
        let alternateWork = fixture.works.mint(from: alternate)
        #expect(fixture.works.merge(alternateWork, into: work))
        let resolve = UpdatesChapterLoader.live(registry: fixture.registry, fulfillment: fixture.fulfillment)

        fixture.preferences.choose(ListingKey(alternate), for: work)
        let pinned = try #require(resolve(work, display))
        #expect(ListingKey(pinned.manga) == ListingKey(alternate))
        #expect(pinned.source.id == "alt")
        #expect(pinned.manga.title == display.title, "the Work's identity is kept")

        let orphan = Self.manga("orphan", source: "uninstalled")
        #expect(resolve(fixture.works.mint(from: orphan), orphan) == nil)
    }

    // MARK: Helpers

    private static func manga(_ id: String, source: String = "gated") -> Manga {
        Manga(id: id, sourceId: source, title: id.capitalized, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: nil)
    }

    private static func resolver(_ source: MangaSource) -> (WorkID, Manga) -> UpdatesChapterTarget? {
        { _, manga in UpdatesChapterTarget(manga: manga, source: source) }
    }

    /// Lets queued tasks run without asserting anything happened.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    private static func until(_ condition: () async -> Bool,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition never became true", sourceLocation: sourceLocation)
    }
}

/// Holds every chapter request until released, and records what started and the peak.
private actor ChapterGate {
    private(set) var started: [String] = []
    private(set) var peak = 0
    private var running = 0
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) { isOpen = open }

    func enter(_ id: String) async {
        started.append(id)
        running += 1
        peak = max(peak, running)
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        running -= 1
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func openAndReleaseAll() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private struct GatedSource: MangaSource {
    let gate: ChapterGate
    var fails = false
    let id = "gated"
    let name = "Gated"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { throw SourceError.unsupported("detail") }
    func chapters(mangaId: String) async throws -> [Chapter] {
        await gate.enter(mangaId)
        if fails { throw URLError(.notConnectedToInternet) }
        return (1...3).map { Chapter(id: "\(mangaId)-\($0)", number: "\($0)", title: nil) }
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

@MainActor
private final class ScreenFixture {
    let testDirectory = TestDirectory("UpdatesScreenTests")
    let suite = TestDefaults("UpdatesScreenTests")
    let works: WorkStore
    let library: LibraryStore
    let history: HistoryStore
    let updates: UpdateStateStore
    let registry: SourceRegistry
    let preferences: SourcePreferenceStore
    let fulfillment: FulfillmentCoordinator

    deinit { testDirectory.remove() }

    init() throws {
        let directory = testDirectory.url
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry = SourceRegistry(sources: [StubSource(id: "stub", name: "Stub"),
                                            StubSource(id: "alt", name: "Alt")],
                                  defaults: suite.defaults)
        works = WorkStore(directory: directory)
        library = LibraryStore(defaults: suite.defaults, works: works, registry: registry)
        history = HistoryStore(defaults: suite.defaults, works: works)
        updates = UpdateStateStore(directory: directory, works: works)
        preferences = SourcePreferenceStore(defaults: suite.defaults, works: works)
        fulfillment = FulfillmentCoordinator(works: works, registry: registry,
                                             counts: ListingCountCache(directory: directory),
                                             preferences: preferences)
    }

    func summaries() -> [WorkUpdateSummary] {
        LibraryUpdatesPresentation.summaries(works: works, library: library, history: history,
                                             updates: updates, registry: registry)
    }

    func timeline() -> UpdatesTimeline {
        UpdatesTimeline(summaries: summaries(), updates: updates)
    }
}
