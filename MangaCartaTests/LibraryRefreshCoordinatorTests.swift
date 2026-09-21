import Foundation
import Testing
@testable import MangaCarta

@Suite("Library refresh coordinator")
struct LibraryRefreshCoordinatorTests {
    @MainActor
    @Test("One failing listing does not hide another listing's release")
    func partialFailureStillAdvances() async throws {
        let good = StubSource(id: "good", chapters: ["shared": ["1", "2"]])
        let bad = StubSource(id: "bad", failures: ["shared"])
        let fixture = Fixture(sources: [good, bad])
        let workId = fixture.mint("shared", source: "good", malId: 7)
        _ = fixture.mint("shared", source: "bad", malId: 7)
        fixture.seed(workId, listing: .init(sourceId: "good", mangaId: "shared"), numbers: ["1"])

        let events = await fixture.coordinator.run(budget: .foreground)

        #expect(events.count == 1)
        #expect(events.first?.newChapterCount == 1)
        let failed = try #require(fixture.updates.state(for: workId)?.listings[
            .init(sourceId: "bad", mangaId: "shared")
        ])
        #expect(failed.consecutiveFailures == 1)
    }

    @MainActor
    @Test("Every listing failing records failure and emits no event")
    func allFailuresEmitNothing() async {
        let source = StubSource(id: "mangadex", failures: ["broken"])
        let fixture = Fixture(sources: [source])
        let workId = fixture.mint("broken", source: "mangadex")

        let step = await fixture.coordinator.step()

        #expect(step == .failed(workId))
        #expect(fixture.updates.state(for: workId)?.listings[
            .init(sourceId: "mangadex", mangaId: "broken")
        ]?.consecutiveFailures == 1)
    }

    @MainActor
    @Test("A WeebCentral slug is never sent to MangaDex")
    func routesEachListingToItsSource() async {
        let mangaDex = StubSource(id: MangaDexSource.sourceID)
        let weebCentral = StubSource(id: WeebCentralIdentityMigration.qualifiedID,
                                     chapters: ["wc-slug": ["1"]])
        let fixture = Fixture(sources: [mangaDex, weebCentral])
        _ = fixture.mint("wc-slug", source: WeebCentralIdentityMigration.qualifiedID)

        _ = await fixture.coordinator.run(budget: .foreground)

        #expect(await mangaDex.askedIds().isEmpty)
        #expect(await weebCentral.askedIds() == ["wc-slug"])
    }

    @MainActor
    @Test("Three new chapters on one Work produce one event")
    func multipleChaptersProduceOneEvent() async {
        let source = StubSource(id: "mangadex", chapters: ["series": ["1", "2", "3", "4"]])
        let fixture = Fixture(sources: [source])
        let workId = fixture.mint("series", source: "mangadex")
        fixture.seed(workId, listing: .init(sourceId: "mangadex", mangaId: "series"), numbers: ["1"])

        let events = await fixture.coordinator.run(budget: .foreground)

        #expect(events == [UpdateEvent(workId: workId, title: "series",
                                      newChapterCount: 3, didExceedCap: false, isAdult: false)])
    }

    @MainActor
    @Test("Two listings reporting the same release produce one event")
    func duplicateListingsDeduplicateRelease() async {
        let first = StubSource(id: "first", chapters: ["same": ["1", "2"]])
        let second = StubSource(id: "second", chapters: ["same": ["1", "2"]])
        let fixture = Fixture(sources: [first, second])
        let workId = fixture.mint("same", source: "first", malId: 9)
        _ = fixture.mint("same", source: "second", malId: 9)
        fixture.seed(workId, listing: .init(sourceId: "first", mangaId: "same"), numbers: ["1"])

        let events = await fixture.coordinator.run(budget: .foreground)

        #expect(events.count == 1)
        #expect(events.first?.newChapterCount == 1)
    }

    @MainActor
    @Test("A Work whose listings are all in backoff costs no request")
    func backoffSkipsNetwork() async {
        let source = StubSource(id: "mangadex", chapters: ["paused": ["1"]])
        let fixture = Fixture(sources: [source], now: Date(timeIntervalSince1970: 100))
        let workId = fixture.mint("paused", source: "mangadex")
        let listing = ListingKey(sourceId: "mangadex", mangaId: "paused")
        fixture.updates.recordFailure(workId: workId, listing: listing,
                                      now: Date(timeIntervalSince1970: 100))

        let step = await fixture.coordinator.step()

        #expect(step == .skipped(workId))
        #expect(await source.askedIds().isEmpty)
    }

    @MainActor
    @Test("Library pull-to-refresh uses the coordinator and keeps chapter badges updated")
    func libraryRefreshUsesCoordinator() async {
        let source = StubSource(id: "mangadex", chapters: ["saved": ["1", "2"]])
        let fixture = Fixture(sources: [source])
        fixture.library.toggle(fixture.manga("saved", source: "mangadex"))

        await fixture.library.refresh()

        #expect(fixture.library.item(for: "saved")?.chapterNumbers == ["1", "2"])
        #expect(await source.askedIds() == ["saved"])
    }

    @MainActor
    @Test("Cancellation persists progress and the next run resumes at another Work")
    func cancellationPersistsCursorAndResumes() async throws {
        let source = StubSource(id: "mangadex", chapters: ["one": ["1"], "two": ["1"]])
        let fixture = Fixture(sources: [source], cancelAfterFirst: true)
        _ = fixture.mint("one", source: "mangadex")
        _ = fixture.mint("two", source: "mangadex")

        let cancelledRun = Task { await fixture.coordinator.run(budget: .foreground) }
        _ = await cancelledRun.value
        let firstRunAsked = await source.askedIds()
        let cursor = try #require(fixture.updates.refreshCursor)
        #expect(firstRunAsked.count == 1)
        #expect(fixture.works.work(cursor) != nil)

        await source.clearAsked()
        _ = await fixture.coordinator.run(budget: .foreground)
        let resumedAsked = await source.askedIds()

        #expect(resumedAsked.first != firstRunAsked.first)
    }

    @MainActor
    @Test("A merge is reconciled before fetching and cannot rediscover known chapters")
    func mergeReconcilesBeforeFetch() async {
        let source = StubSource(id: "mangadex", chapters: ["winner": ["1", "2"]])
        let fixture = Fixture(sources: [source])
        let winner = fixture.mint("winner", source: "mangadex")
        let loser = fixture.mint("loser", source: "mangadex")
        fixture.seed(winner, listing: .init(sourceId: "mangadex", mangaId: "winner"), numbers: ["1"])
        fixture.seed(loser, listing: .init(sourceId: "mangadex", mangaId: "loser"), numbers: ["1", "2"])
        fixture.works.merge(loser, into: winner)

        let events = await fixture.coordinator.run(budget: .foreground)

        #expect(events.isEmpty)
        #expect(fixture.updates.state(for: loser) == nil)
    }

    @MainActor
    @Test("A renumbering burst caps the event while absorbing the full frontier")
    func notificationCapDoesNotCapFrontier() async throws {
        let numbers = (1...101).map(String.init)
        let source = StubSource(id: "mangadex", chapters: ["long": numbers])
        let fixture = Fixture(sources: [source])
        let workId = fixture.mint("long", source: "mangadex")
        fixture.seed(workId, listing: .init(sourceId: "mangadex", mangaId: "long"), numbers: ["1"])

        let first = await fixture.coordinator.run(budget: .foreground)
        let second = await fixture.coordinator.run(budget: .foreground)

        let event = try #require(first.first)
        #expect(event.newChapterCount == UpdateTuning.maxNotifiedChaptersPerWork)
        #expect(event.didExceedCap)
        #expect(fixture.updates.state(for: workId)?.frontier.known.count == 101)
        #expect(second.isEmpty)
    }
}

@MainActor
private final class Fixture {
    let works: WorkStore
    let updates: UpdateStateStore
    let library: LibraryStore
    let coordinator: LibraryRefreshCoordinator

    init(sources: [StubSource],
         now: Date = Date(timeIntervalSince1970: 1_000),
         cancelAfterFirst: Bool = false) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryRefreshCoordinatorTests-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "LibraryRefreshCoordinatorTests-\(UUID().uuidString)")!
        works = WorkStore(directory: directory)
        updates = UpdateStateStore(directory: directory, works: works)
        let registry = SourceRegistry(sources: sources)
        library = LibraryStore(defaults: defaults, works: works, registry: registry)
        let history = HistoryStore(defaults: defaults, works: works)
        var processed = 0
        coordinator = LibraryRefreshCoordinator(
            works: works, library: library, history: history,
            updates: updates, registry: registry, now: { now },
            didProcessWork: { _ in
                processed += 1
                if cancelAfterFirst, processed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
        library.configureRefreshCoordinator(coordinator)
    }

    func mint(_ id: String, source: String, malId: Int? = nil) -> WorkID {
        works.mint(from: manga(id, source: source, malId: malId))
    }

    func manga(_ id: String, source: String, malId: Int? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: id, description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: malId)
    }

    func seed(_ workId: WorkID, listing: ListingKey, numbers: [String]) {
        _ = updates.absorb(workId: workId, listing: listing, rawNumbers: numbers,
                           now: Date(timeIntervalSince1970: 1))
    }
}

private struct StubSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    let state: StubSourceState

    init(id: String, chapters: [String: [String]] = [:], failures: Set<String> = []) {
        self.id = id
        state = StubSourceState(chapters: chapters, failures: failures)
    }

    func askedIds() async -> [String] { await state.asked }
    func clearAsked() async { await state.clearAsked() }
    func chapters(mangaId: String) async throws -> [Chapter] { try await state.fetch(mangaId) }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

private actor StubSourceState {
    enum Failure: Error { case requested }
    let chapters: [String: [String]]
    let failures: Set<String>
    private(set) var asked: [String] = []

    init(chapters: [String: [String]], failures: Set<String>) {
        self.chapters = chapters
        self.failures = failures
    }

    func fetch(_ mangaId: String) throws -> [Chapter] {
        asked.append(mangaId)
        if failures.contains(mangaId) { throw Failure.requested }
        return (chapters[mangaId] ?? []).map { Chapter(id: "\(mangaId)-\($0)", number: $0, title: nil) }
    }

    func clearAsked() { asked = [] }
}
