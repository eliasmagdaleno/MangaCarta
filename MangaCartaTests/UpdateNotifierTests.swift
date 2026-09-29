import Foundation
import Testing
import UserNotifications
@testable import MangaCarta

@Suite("Update notifier")
struct UpdateNotifierTests {
    @MainActor
    @Test("Denied authorization schedules nothing while update state remains advanced")
    func deniedSchedulesNothing() async {
        let fixture = Fixture(status: .denied)
        defer { fixture.suite.remove() }
        let workId = fixture.mint("Dandadan")
        fixture.discover(workId)

        await fixture.notifier.schedule([fixture.event(workId, count: 1)])

        #expect(fixture.notifications.requests.isEmpty)
        #expect(fixture.updates.state(for: workId)?.newlyDiscovered.isEmpty == false)
    }

    @MainActor
    @Test("Adult copy hides a title when any linked listing is adult")
    func adultListingOverSuppressesCopy() async throws {
        let safe = NoticeSource(id: "safe", isNSFW: false)
        let adult = NoticeSource(id: "adult", isNSFW: true)
        let fixture = Fixture(sources: [safe, adult])
        defer { fixture.suite.remove() }
        let workId = fixture.mint("Public title", source: "safe", malId: 10)
        _ = fixture.mint("Private title", source: "adult", malId: 10)

        await fixture.notifier.schedule([fixture.event(workId, count: 3)])

        let request = try #require(fixture.notifications.requests.first)
        #expect(request.content.body == "A followed title has new chapters")
        #expect(request.content.body.contains("Public title") == false)
    }

    @MainActor
    @Test("Mixed Sources hide notification details while adult content is off")
    func mixedSourceHidesCopyWhenAdultContentIsOff() async throws {
        let mixed = NoticeSource(id: "mixed", isNSFW: false, declaresAdultTitles: true)
        let fixture = Fixture(sources: [mixed])
        defer { fixture.suite.remove() }
        let workId = fixture.mint("Mixed title", source: "mixed")

        await fixture.notifier.schedule([fixture.event(workId, count: 1)])

        let request = try #require(fixture.notifications.requests.first)
        #expect(request.content.body == "A followed title has new chapters")
        #expect(request.content.body.contains("Mixed title") == false)
    }

    @Test("Copy pluralizes one and three chapters and degrades capped events")
    func notificationCopy() {
        let workId = WorkID()
        #expect(UpdateNotifier.body(for: event(workId, count: 1)) == "1 new chapter of Dandadan")
        #expect(UpdateNotifier.body(for: event(workId, count: 3)) == "3 new chapters of Dandadan")
        #expect(UpdateNotifier.body(for: event(workId, count: 12, capped: true))
                == "Many new chapters of Dandadan")
    }

    @MainActor
    @Test("Muted Works are folded but never scheduled")
    func mutedWorkIsSkipped() async {
        let fixture = Fixture()
        defer { fixture.suite.remove() }
        let workId = fixture.mint("Muted")
        fixture.updates.setMuted(true, workId: workId)

        await fixture.notifier.schedule([fixture.event(workId, count: 1)])

        #expect(fixture.notifications.requests.isEmpty)
    }

    @MainActor
    @Test("The global notification toggle suppresses delivery")
    func globalToggleSuppressesDelivery() async {
        let fixture = Fixture()
        defer { fixture.suite.remove() }
        let workId = fixture.mint("Globally muted")
        fixture.defaults.set(false, forKey: UpdateNotifier.notificationsEnabledKey)

        await fixture.notifier.schedule([fixture.event(workId, count: 1)])

        #expect(fixture.notifications.requests.isEmpty)
    }

    @MainActor
    @Test("Repeated events reuse one stable Work identifier and notification group")
    func repeatedEventReusesIdentifier() async {
        let fixture = Fixture()
        defer { fixture.suite.remove() }
        let workId = fixture.mint("Repeat")

        await fixture.notifier.schedule([fixture.event(workId, count: 1)])
        await fixture.notifier.schedule([fixture.event(workId, count: 2)])

        #expect(fixture.notifications.requests.map(\.identifier) == [
            "work-\(workId.raw.uuidString)", "work-\(workId.raw.uuidString)"
        ])
        #expect(fixture.notifications.requests.allSatisfy {
            $0.content.threadIdentifier == UpdateNotifier.threadIdentifier
        })
    }

    @MainActor
    @Test("Forgetting update state cancels its pending notification")
    func forgettingCancelsPendingRequest() {
        let fixture = Fixture()
        defer { fixture.suite.remove() }
        let workId = fixture.mint("Forgotten")
        fixture.discover(workId)

        fixture.notifier.forget(workId: workId)

        #expect(fixture.updates.state(for: workId) == nil)
        #expect(fixture.notifications.removed == [["work-\(workId.raw.uuidString)"]])
    }

    @MainActor
    @Test("Authorization is requested once and only after a Library save")
    func contextualAuthorizationIsOneShot() async {
        let fixture = Fixture(status: .notDetermined)
        defer { fixture.suite.remove() }

        await fixture.notifier.requestAuthorizationIfNeeded()
        #expect(fixture.notifications.authorizationRequests == 0)

        fixture.library.toggle(fixture.manga("Saved"))
        await fixture.notifier.requestAuthorizationIfNeeded()
        await fixture.notifier.requestAuthorizationIfNeeded()

        #expect(fixture.notifications.authorizationRequests == 1)
    }

    @MainActor
    @Test("A response routes to the surviving Work rather than opening a chapter")
    func responseRoutesToResolvedWork() {
        var opened: WorkID?
        let fixture = Fixture(openWork: { opened = $0 })
        defer { fixture.suite.remove() }
        let winner = fixture.mint("Winner")
        let loser = fixture.mint("Loser", source: "other")
        fixture.works.merge(loser, into: winner)

        fixture.notifier.handleResponse(userInfo: [
            UpdateNotifier.workIdUserInfoKey: loser.raw.uuidString
        ])

        #expect(opened == winner)
    }

    private func event(_ workId: WorkID, count: Int, capped: Bool = false) -> UpdateEvent {
        UpdateEvent(workId: workId, title: "Dandadan", newChapterCount: count,
                    didExceedCap: capped, isAdult: false)
    }
}

@MainActor
private final class Fixture {
    let notifications: FakeNotificationCenter
    let suite: TestDefaults
    let defaults: UserDefaults
    let works: WorkStore
    let updates: UpdateStateStore
    let library: LibraryStore
    let notifier: UpdateNotifier

    init(status: UNAuthorizationStatus = .authorized,
         sources: [NoticeSource] = [NoticeSource(id: MangaDexSource.sourceID, isNSFW: false)],
         openWork: @escaping (WorkID) -> Void = { _ in }) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateNotifierTests-\(UUID().uuidString)")
        suite = TestDefaults("UpdateNotifierTests")
        defaults = suite.defaults
        notifications = FakeNotificationCenter(status: status)
        works = WorkStore(directory: directory)
        updates = UpdateStateStore(directory: directory, works: works)
        library = LibraryStore(defaults: defaults, works: works)
        notifier = UpdateNotifier(notifications: notifications, updates: updates, works: works,
                                  library: library, registry: SourceRegistry(sources: sources),
                                  defaults: defaults, openWork: openWork)
    }

    func mint(_ title: String, source: String = MangaDexSource.sourceID, malId: Int? = nil) -> WorkID {
        works.mint(from: manga(title, source: source, malId: malId))
    }

    func manga(_ title: String,
               source: String = MangaDexSource.sourceID,
               malId: Int? = nil) -> Manga {
        Manga(id: title.lowercased(), sourceId: source, title: title, description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: malId)
    }

    func discover(_ workId: WorkID) {
        let listing = works.work(workId)?.listings.first
            ?? ListingKey(sourceId: MangaDexSource.sourceID, mangaId: "missing")
        _ = updates.absorb(workId: workId, listing: listing, rawNumbers: ["1"], now: Date())
        _ = updates.absorb(workId: workId, listing: listing, rawNumbers: ["2"], now: Date())
    }

    func event(_ workId: WorkID, count: Int) -> UpdateEvent {
        UpdateEvent(workId: workId, title: works.work(workId)?.displayTitle ?? "",
                    newChapterCount: count, didExceedCap: false, isAdult: false)
    }
}

@MainActor
private final class FakeNotificationCenter: NotificationScheduling {
    var status: UNAuthorizationStatus
    var requests: [UNNotificationRequest] = []
    var removed: [[String]] = []
    var authorizationRequests = 0

    init(status: UNAuthorizationStatus) { self.status = status }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return true
    }
    func add(_ request: UNNotificationRequest) async { requests.append(request) }
    func removePending(withIdentifiers identifiers: [String]) { removed.append(identifiers) }
}

private struct NoticeSource: MangaSource {
    let id: String
    let isNSFW: Bool
    let declaresAdultTitles: Bool
    var name: String { id }

    init(id: String, isNSFW: Bool, declaresAdultTitles: Bool = false) {
        self.id = id
        self.isNSFW = isNSFW
        self.declaresAdultTitles = declaresAdultTitles
    }

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
