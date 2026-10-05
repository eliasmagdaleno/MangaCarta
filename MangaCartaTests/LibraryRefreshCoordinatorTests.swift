import Foundation
import Testing
@testable import MangaCarta

@Suite("Library refresh coordinator")
struct LibraryRefreshCoordinatorTests {
    @MainActor
    @Test("Mixed remote and local refresh only fetches participating remote")
    func mixedRemoteAndLocalRefreshOnlyFetchesParticipatingRemote() async {
        let remote = StubSource(id: "remote", chapters: ["remote": ["1"]])
        let local = StubSource(id: "local", chapters: ["local": ["1"]], participatesInUpdates: false)
        let other = StubSource(id: "not-local", chapters: ["other": ["1"]], participatesInUpdates: false)
        let fixture = Fixture(sources: [remote, local, other])
        defer { fixture.suite.remove() }
        _ = fixture.mint("remote", source: "remote")
        _ = fixture.mint("local", source: "local")
        _ = fixture.mint("other", source: "not-local")

        await fixture.coordinator.refreshLibrary()

        #expect(await remote.askedIds() == ["remote"])
        #expect(await local.askedIds().isEmpty)
        #expect(await other.askedIds().isEmpty)
    }

    @MainActor
    @Test("One failing listing does not hide another listing's release")
    func partialFailureStillAdvances() async throws {
        let good = StubSource(id: "good", chapters: ["shared": ["1", "2"]])
        let bad = StubSource(id: "bad", failures: ["shared"])
        let fixture = Fixture(sources: [good, bad])
        defer { fixture.suite.remove() }
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
        defer { fixture.suite.remove() }
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
        let mangaDex = StubSource(id: "mangadex")
        let weebCentral = StubSource(id: WeebCentralIdentityMigration.qualifiedID,
                                     chapters: ["wc-slug": ["1"]])
        let fixture = Fixture(sources: [mangaDex, weebCentral])
        defer { fixture.suite.remove() }
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
        defer { fixture.suite.remove() }
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
        defer { fixture.suite.remove() }
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
        defer { fixture.suite.remove() }
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
        defer { fixture.suite.remove() }
        fixture.library.toggle(fixture.manga("saved", source: "mangadex"))

        await fixture.library.refresh()

        #expect(fixture.library.item(for: "saved")?.chapterNumbers == ["1", "2"])
        #expect(await source.askedIds() == ["saved"])
    }

    @MainActor
    @Test("A foreground run applies fetched chapter numbers to the Library (#330)")
    func testForegroundRunAppliesChapterNumbersToLibrary() async throws {
        let source = StubSource(id: "mangadex", chapters: ["saved": ["1", "2", "3"]])
        let fixture = Fixture(sources: [source])
        defer { fixture.suite.remove() }
        fixture.save("saved", source: "mangadex", numbers: ["1"])

        _ = await fixture.coordinator.run(budget: .foreground)

        let item = try #require(fixture.library.item(for: "saved"))
        #expect(item.chapterNumbers == ["1", "2", "3"])
        #expect(item.unreadCount(readNumbers: ["1"]) == 2)
    }

    @MainActor
    @Test("A background-task run applies fetched chapter numbers to the Library (#330)")
    func testBackgroundRunAppliesChapterNumbersToLibrary() async throws {
        let source = StubSource(id: "mangadex", chapters: ["saved": ["1", "2", "3"]])
        let fixture = Fixture(sources: [source])
        defer { fixture.suite.remove() }
        fixture.save("saved", source: "mangadex", numbers: ["1"])
        let coordinator = fixture.coordinator
        let scheduler = UpdateScheduler(backgroundTasks: NoopBackgroundTasks(),
                                        runRefresh: { await coordinator.run(budget: $0) },
                                        notify: { _ in },
                                        now: { fixture.now })

        await scheduler.handle(CompletingBackgroundTask()).value

        let item = try #require(fixture.library.item(for: "saved"))
        #expect(item.chapterNumbers == ["1", "2", "3"])
        #expect(item.unreadCount(readNumbers: ["1"]) == 2)
    }

    @MainActor
    @Test("A run cut off by its budget keeps the chapter numbers of Works it completed (#330)")
    func testCutOffRunKeepsAppliedChapterNumbersForCompletedWorks() async throws {
        let source = StubSource(id: "mangadex", chapters: ["one": ["1", "2"], "two": ["1", "2"]])
        let fixture = Fixture(sources: [source])
        defer { fixture.suite.remove() }
        fixture.save("one", source: "mangadex", numbers: ["1"])
        fixture.save("two", source: "mangadex", numbers: ["1"])

        _ = await fixture.coordinator.run(budget: .background(
            deadline: fixture.now.addingTimeInterval(3_600), maxWorks: 1
        ))

        let asked = await source.askedIds()
        let completed = try #require(asked.first)
        #expect(asked.count == 1)
        let unprocessed = completed == "one" ? "two" : "one"
        #expect(fixture.library.item(for: completed)?.chapterNumbers == ["1", "2"])
        #expect(fixture.library.item(for: unprocessed)?.chapterNumbers == ["1"])
    }

    @MainActor
    @Test("Applying one Listing's numbers leaves every other Library item untouched (#330)")
    func testPartialApplyLeavesOtherLibraryItemsUntouched() {
        let fixture = Fixture(sources: [])
        defer { fixture.suite.remove() }
        fixture.save("fetched", source: "mangadex", numbers: ["1"])
        fixture.save("other", source: "mangadex", numbers: ["1", "2"])
        fixture.save("unknown", source: "mangadex", numbers: nil)

        fixture.library.applyRefreshedChapterNumbers([
            .init(sourceId: "mangadex", mangaId: "fetched"): ["1", "2", "3"]
        ])

        #expect(fixture.library.item(for: "fetched")?.chapterNumbers == ["1", "2", "3"])
        #expect(fixture.library.item(for: "other")?.chapterNumbers == ["1", "2"])
        #expect(fixture.library.item(for: "unknown")?.chapterNumbers == nil)
    }

    @MainActor
    @Test("Cancellation persists progress and the next run resumes at another Work")
    func cancellationPersistsCursorAndResumes() async throws {
        let source = StubSource(id: "mangadex", chapters: ["one": ["1"], "two": ["1"]])
        let fixture = Fixture(sources: [source], cancelAfterFirst: true)
        defer { fixture.suite.remove() }
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
        defer { fixture.suite.remove() }
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
    @Test("A Work minted only by reading is neither fetched nor notified (#342)")
    func readOnlyWorkIsNeitherFetchedNorNotified() async {
        let source = StubSource(id: "mangadex", chapters: ["read-only": ["1"]])
        let fixture = Fixture(sources: [source])
        defer { fixture.suite.remove() }
        let manga = fixture.manga("read-only", source: "mangadex")
        fixture.history.record(manga: manga, chapter: Chapter(id: "read-only-1", number: "1", title: nil),
                               position: ReadingPosition(page: 4), pageCount: 5)
        #expect(fixture.works.workId(for: ListingKey(manga)) != nil)

        let first = await fixture.coordinator.run(budget: .foreground)
        await source.setChapters(["1", "2"], for: "read-only")
        let second = await fixture.coordinator.run(budget: .foreground)

        #expect(await source.askedIds().isEmpty)
        #expect(first.isEmpty)
        #expect(second.isEmpty)
    }

    @MainActor
    @Test("A renumbering burst caps the event while absorbing the full frontier")
    func notificationCapDoesNotCapFrontier() async throws {
        let numbers = (1...101).map(String.init)
        let source = StubSource(id: "mangadex", chapters: ["long": numbers])
        let fixture = Fixture(sources: [source])
        defer { fixture.suite.remove() }
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
    let testDirectory = TestDirectory("LibraryRefreshCoordinatorTests")
    var directory: URL { testDirectory.url }
    let suite: TestDefaults
    let works: WorkStore
    let updates: UpdateStateStore
    let library: LibraryStore
    let history: HistoryStore
    let coordinator: LibraryRefreshCoordinator
    let now: Date

    deinit { testDirectory.remove() }

    init(sources: [StubSource],
         now: Date = Date(timeIntervalSince1970: 1_000),
         cancelAfterFirst: Bool = false) {
        let directory = testDirectory.url
        self.now = now
        suite = TestDefaults("LibraryRefreshCoordinatorTests")
        let defaults = suite.defaults
        works = WorkStore(directory: directory)
        updates = UpdateStateStore(directory: directory, works: works)
        let registry = SourceRegistry(sources: sources, defaults: defaults)
        library = LibraryStore(defaults: defaults, works: works, registry: registry)
        let history = HistoryStore(defaults: defaults, works: works)
        self.history = history
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

    /// Mints the Work and saves the Listing, since refresh covers saved Works only (#342).
    /// The Library keys items by manga id, so a second source's copy of a saved id is
    /// minted without a second item; its Work is saved through the first.
    func mint(_ id: String, source: String, malId: Int? = nil) -> WorkID {
        let listing = manga(id, source: source, malId: malId)
        let workId = works.mint(from: listing)
        if !library.contains(id) { library.toggle(listing) }
        return workId
    }

    func manga(_ id: String, source: String, malId: Int? = nil) -> Manga {
        Manga(id: id, sourceId: source, title: id, description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: malId)
    }

    /// Saves a title to the Library, optionally with the chapter numbers it was last refreshed with.
    func save(_ id: String, source: String, numbers: [String]?) {
        library.toggle(manga(id, source: source))
        guard let numbers else { return }
        library.applyRefreshedChapterNumbers([.init(sourceId: source, mangaId: id): numbers])
    }

    func seed(_ workId: WorkID, listing: ListingKey, numbers: [String]) {
        _ = updates.absorb(workId: workId, listing: listing, rawNumbers: numbers,
                           now: Date(timeIntervalSince1970: 1))
    }
}

@MainActor
private struct NoopBackgroundTasks: BackgroundTaskScheduling {
    func register(identifier: String, handler: @escaping (BGTaskLike) -> Void) -> Bool { true }
    func submit(identifier: String, earliestBeginDate: Date) throws {}
    func cancel(identifier: String) {}
}

@MainActor
private final class CompletingBackgroundTask: BGTaskLike {
    var expirationHandler: (() -> Void)?
    func setTaskCompleted(success: Bool) {}
}

private struct StubSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    let state: StubSourceState
    let participatesInUpdates: Bool

    init(id: String, chapters: [String: [String]] = [:], failures: Set<String> = [], participatesInUpdates: Bool = true) {
        self.id = id
        state = StubSourceState(chapters: chapters, failures: failures)
        self.participatesInUpdates = participatesInUpdates
    }

    func askedIds() async -> [String] { await state.asked }
    func clearAsked() async { await state.clearAsked() }
    func setChapters(_ numbers: [String], for mangaId: String) async {
        await state.setChapters(numbers, for: mangaId)
    }
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
    private(set) var chapters: [String: [String]]
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
    func setChapters(_ numbers: [String], for mangaId: String) { chapters[mangaId] = numbers }
}
