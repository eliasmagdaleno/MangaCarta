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
