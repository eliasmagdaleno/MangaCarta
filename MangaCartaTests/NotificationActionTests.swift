import Foundation
import Testing
import UserNotifications
@testable import MangaCarta

/// The notification-actions design's AC 2–5: what "Mark Read" and "Mute" on a delivered
/// new-chapter notification do to the stores, through the same handler the delegate calls.
@Suite("Notification actions")
@MainActor
final class NotificationActionTests {
    private let fixture = Fixture()

    // MARK: - AC 2

    @Test("Mark Read marks every captured ordinal, past the cap, and nothing discovered later")
    func markReadIsScopedToCapturedOrdinals() async throws {
        let f = fixture
        let total = UpdateTuning.maxNotifiedChaptersPerWork + 8
        let work = f.save("scoped", chapters: total + 1)
        f.absorb(work, through: 0)                // baseline
        f.absorb(work, through: total)            // the notification's event: 1…total
        f.absorb(work, through: total + 1)        // a later release, not in the payload
        let captured = (1...total).map(String.init)

        let outcome = await f.perform(.markRead, work, ordinals: captured)

        #expect(outcome == .markedRead)
        for number in 1...total {
            #expect(f.isRead(number, of: "scoped"), "chapter \(number) was captured")
        }
        #expect(!f.isRead(total + 1, of: "scoped"), "the later release was not in this notification")
        #expect(f.updates.state(for: work)?.newlyDiscovered == [f.ordinal(total + 1)])
    }

    // MARK: - AC 3

    @Test("An action on one Work of a grouped thread leaves every other Work alone")
    func groupedNotificationsNeverCrossWorkBoundaries() async throws {
        let f = fixture
        let first = f.save("first", chapters: 2)
        let second = f.save("second", chapters: 2)
        for work in [first, second] {
            f.absorb(work, through: 0)
            f.absorb(work, through: 2)
        }
        let before = f.updates.state(for: second)

        #expect(await f.perform(.markRead, first, ordinals: ["1", "2"]) == .markedRead)
        #expect(await f.perform(.mute, first) == .muted)

        #expect(f.updates.state(for: second) == before)
        #expect(!f.isRead(1, of: "second") && !f.isRead(2, of: "second"))
        #expect(f.isRead(1, of: "first") && f.isRead(2, of: "first"))
        #expect(f.updates.state(for: first)?.isMuted == true)
        #expect(f.center.removed == [[UpdateStateStore.notificationIdentifier(for: first)]])
    }

    // MARK: - AC 4

    @Test("Mark Read writes manual marks on the chosen Listing and fires no completion sink")
    func markReadUsesNormalReadPathWithoutMALProgress() async throws {
        let f = fixture
        // Saved copy A; copy B on the same Work, not saved, pinned as the one to read from.
        let work = f.save("saved-a", chapters: 3)
        let pinned = f.manga("pinned-b", source: Fixture.otherSourceID)
        f.other.chapterCount["pinned-b"] = 3
        let pinnedWork = f.works.mint(from: pinned)
        #expect(f.works.merge(pinnedWork, into: work))
        f.preferences.choose(ListingKey(pinned), for: work)
        #expect(f.fulfillment.chosenListing(for: work) == ListingKey(pinned))
        f.absorb(work, through: 1)
        f.absorb(work, through: 3)

        #expect(await f.perform(.markRead, work, ordinals: ["2", "3"]) == .markedRead)

        let marks = f.readMarks()
        #expect(Set(marks.map(\.mangaId)) == ["pinned-b"], "marks land on the chosen Listing only")
        #expect(Set(marks.map(\.sourceId)) == [Fixture.otherSourceID])
        // Work-wide read state: the saved copy's chapter 2 reads as read by ordinal.
        #expect(f.isRead(2, of: "saved-a"))
        #expect(!f.isRead(1, of: "saved-a"))
        // The sink MAL progress and analytics both hang off. A manual mark never fires it.
        #expect(f.completions.isEmpty)

        // Positive control: the same history does fire the sink when a chapter is read to
        // the end, so the empty list above is a real absence.
        f.history.record(manga: f.manga("saved-a"), chapter: f.chapter(1, of: "saved-a"),
                         position: ReadingPosition(page: 9), pageCount: 10)
        #expect(f.completions.count == 1)
    }

    // MARK: - AC 5

    @Test("Every failure leaves read, discovery and mute state unchanged and still completes",
          arguments: Failure.allCases)
    func failuresAreNoOpsAndComplete(_ failure: Failure) async throws {
        let f = fixture
        let work = failure == .noRegisteredListing
            ? f.save("failing", chapters: 2, source: "not-registered")
            : f.save("failing", chapters: 2)
        f.absorb(work, through: 0)
        f.absorb(work, through: 2)
        let (action, info) = arrange(failure, work: work, in: f)
        let before = f.updates.state(for: work)
        let marksBefore = f.readMarks()
        #expect(before?.newlyDiscovered.count == 2, "precondition: two discoveries to protect")

        var completions = 0
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            f.handler.handle(actionIdentifier: action.identifier, userInfo: info) {
                completions += 1
                resume.resume()
            }
        }

        #expect(completions == 1)
        #expect(f.readMarks() == marksBefore)
        #expect(f.updates.state(for: work) == before)
        #expect(f.center.removed.isEmpty)
    }

    /// Sets up one failure and returns the action and payload that should hit it.
    private func arrange(_ failure: Failure, work: WorkID,
                         in f: Fixture) -> (Action, [AnyHashable: Any]) {
        switch failure {
        case .fetchThrows: f.source.fails = true
        case .cancelled: f.source.cancels = true
        case .unsavedWork, .muteUnsavedWork: f.library.toggle(f.manga("failing"))
        default: break
        }
        let action: Action = failure == .unknownAction ? .unknown
            : failure == .muteUnsavedWork ? .mute : .markRead
        return (action, payload(for: failure, work: work, in: f))
    }

    private func payload(for failure: Failure, work: WorkID,
                         in f: Fixture) -> [AnyHashable: Any] {
        switch failure {
        case .missingWork: f.payload(WorkID(), ordinals: ["1"])
        case .missingOrdinal: f.payload(work, ordinals: ["1", "2", "7"])
        case .malformedOrdinals: f.payload(work, ordinals: ["two"])
        case .emptyOrdinals: f.payload(work, ordinals: [])
        case .malformedWorkId: [UpdateNotifier.workIdUserInfoKey: "not-a-uuid"]
        default: f.payload(work, ordinals: ["1", "2"])
        }
    }

    // MARK: - Owner decision 3, aliases, retries

    @Test("A payload without discoveredOrdinals targets the Work's current discoveries")
    func legacyPayloadFallsBackToNewlyDiscovered() async throws {
        let f = fixture
        let work = f.save("legacy", chapters: 3)
        f.absorb(work, through: 1)
        f.absorb(work, through: 3)

        #expect(await f.perform(.markRead, work) == .markedRead)

        #expect(!f.isRead(1, of: "legacy"), "chapter 1 was the baseline, never newly discovered")
        #expect(f.isRead(2, of: "legacy") && f.isRead(3, of: "legacy"))
        #expect(f.updates.state(for: work)?.newlyDiscovered.isEmpty == true)
    }

    @Test("A merged-away Work id reaches the surviving Work")
    func aliasResolvesToSurvivingWork() async throws {
        let f = fixture
        let winner = f.save("winner", chapters: 2)
        let loser = f.works.mint(from: f.manga("loser", source: Fixture.otherSourceID))
        #expect(f.works.merge(loser, into: winner))
        f.absorb(winner, through: 0)
        f.absorb(winner, through: 2)

        #expect(await f.perform(.markRead, loser, ordinals: ["2"]) == .markedRead)
        #expect(await f.perform(.mute, loser) == .muted)

        #expect(f.isRead(2, of: "winner"))
        #expect(!f.isRead(1, of: "winner"))
        #expect(f.updates.state(for: winner)?.newlyDiscovered == [f.ordinal(1)])
        #expect(f.updates.state(for: winner)?.isMuted == true)
        #expect(f.updates.state(for: loser) == nil, "no record is created under the alias")
    }

    @Test("Repeating Mark Read adds no duplicate marks")
    func markReadIsIdempotent() async throws {
        let f = fixture
        let work = f.save("twice", chapters: 2)
        f.absorb(work, through: 0)
        f.absorb(work, through: 2)

        _ = await f.perform(.markRead, work, ordinals: ["1", "2"])
        let once = f.readMarks()
        _ = await f.perform(.markRead, work, ordinals: ["1", "2"])

        #expect(once.count == 2)
        #expect(f.readMarks() == once)
    }

    enum Failure: CaseIterable, Sendable {
        case fetchThrows, cancelled, missingWork, unsavedWork, noRegisteredListing, missingOrdinal,
             malformedOrdinals, emptyOrdinals, malformedWorkId, unknownAction, muteUnsavedWork
    }
}

// MARK: - Fixture

private enum Action {
    case markRead, mute, unknown

    var identifier: String {
        switch self {
        case .markRead: UpdateNotifier.markReadActionIdentifier
        case .mute: UpdateNotifier.muteActionIdentifier
        case .unknown: "library-update-something-else"
        }
    }
}

@MainActor
private final class Fixture {
    static let sourceID = "action-source"
    static let otherSourceID = "action-other"

    let root = TestDirectory("NotificationActionTests")
    let suite = TestDefaults("NotificationActionTests")
    let source = ActionSource(id: Fixture.sourceID)
    let other = ActionSource(id: Fixture.otherSourceID)
    let center = RecordingCenter()
    let works: WorkStore
    let library: LibraryStore
    let updates: UpdateStateStore
    let history: HistoryStore
    let registry: SourceRegistry
    let preferences: SourcePreferenceStore
    let fulfillment: FulfillmentCoordinator
    let handler: NotificationActionHandler
    private let sink = CompletionSink()
    var completions: [ChapterCompletion] { sink.received }

    init() {
        let directory = root.url
        let defaults = suite.defaults
        works = WorkStore(directory: directory)
        library = LibraryStore(defaults: defaults, works: works)
        updates = UpdateStateStore(directory: directory, works: works)
        let sink = sink
        history = HistoryStore(defaults: defaults, works: works,
                               chapterCompleted: { sink.received.append($0) })
        registry = SourceRegistry(sources: [source, other], defaults: defaults)
        preferences = SourcePreferenceStore(defaults: defaults, works: works)
        fulfillment = FulfillmentCoordinator(
            works: works, registry: registry,
            counts: ListingCountCache(directory: directory.appendingPathComponent("counts")),
            preferences: preferences)
        handler = NotificationActionHandler(works: works, history: history, updates: updates,
                                            library: library, fulfillment: fulfillment,
                                            registry: registry, notifications: center)
    }

    deinit {
        root.remove()
        suite.remove()
    }

    /// Saves a title whose chapter list is 1…`chapters` on `source`.
    func save(_ id: String, chapters: Int, source sourceID: String = Fixture.sourceID) -> WorkID {
        let manga = manga(id, source: sourceID)
        source.chapterCount[id] = chapters
        library.toggle(manga)
        return works.workId(for: ListingKey(manga))!
    }

    func manga(_ id: String, source: String = Fixture.sourceID) -> Manga {
        Manga(id: id, sourceId: source, title: id, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: nil)
    }

    func chapter(_ number: Int, of mangaId: String) -> Chapter {
        Chapter(id: "\(mangaId)-\(number)", number: String(number), title: nil)
    }

    func ordinal(_ number: Int) -> ChapterOrdinal { ChapterOrdinal.parse(String(number))! }

    /// The first absorb baselines; each later one releases what is new since.
    func absorb(_ work: WorkID, through last: Int) {
        let listing = works.work(work)!.listings[0]
        _ = updates.absorb(workId: work, listing: listing, rawNumbers: (0...last).map(String.init))
    }

    func isRead(_ number: Int, of mangaId: String) -> Bool {
        history.isRead(chapter(number, of: mangaId), in: manga(mangaId))
    }

    func readMarks() -> [ReadMark] { history.readMarks }

    func payload(_ work: WorkID, ordinals: [String]? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [UpdateNotifier.workIdUserInfoKey: work.raw.uuidString]
        if let ordinals { info[UpdateNotifier.discoveredOrdinalsUserInfoKey] = ordinals }
        return info
    }

    func perform(_ action: Action, _ work: WorkID,
                 ordinals: [String]? = nil) async -> NotificationActionHandler.Outcome {
        await handler.perform(actionIdentifier: action.identifier,
                              userInfo: payload(work, ordinals: ordinals))
    }
}

@MainActor
private final class CompletionSink {
    var received: [ChapterCompletion] = []
}

@MainActor
private final class RecordingCenter: NotificationScheduling {
    private(set) var removed: [[String]] = []
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> Bool { true }
    func add(_ request: UNNotificationRequest) async {}
    func removePending(withIdentifiers identifiers: [String]) { removed.append(identifiers) }
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
}

private final class ActionSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failing = false
    private var cancelling = false

    init(id: String) { self.id = id }

    var chapterCount: [String: Int] {
        get { lock.withLock { counts } }
        set { lock.withLock { counts = newValue } }
    }
    var fails: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    var cancels: Bool {
        get { lock.withLock { cancelling } }
        set { lock.withLock { cancelling = newValue } }
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        if fails { throw URLError(.notConnectedToInternet) }
        if cancels { throw CancellationError() }
        let count = chapterCount[mangaId] ?? 0
        guard count > 0 else { return [] }
        return (1...count).map { Chapter(id: "\(mangaId)-\($0)", number: String($0), title: nil) }
    }

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
