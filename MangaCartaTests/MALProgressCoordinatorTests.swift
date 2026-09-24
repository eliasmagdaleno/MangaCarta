//
//  MALProgressCoordinatorTests.swift
//  MangaCartaTests
//
//  The completion sink, deferred promotion, and the serial drain's reconciliation
//  and retry policy. Every test here uses a scripted client, a deterministic clock,
//  and a real outbox in a temporary directory — nothing contacts MyAnimeList.
//

import XCTest
@testable import MangaCarta

// MARK: - Doubles

private final class ScriptedDeliveryClient: MALProgressDelivering, @unchecked Sendable {
    enum Call: Equatable {
        case read(mangaID: Int)
        case update(mangaID: Int, status: String?, progress: Int)
    }

    var statuses: [Int: Result<MALListStatus?, MALRequestFailure>] = [:]
    /// Consumed front-to-back per manga id, so a test can script "fails, then succeeds".
    var updates: [Int: [Result<MALListStatus, MALRequestFailure>]] = [:]
    private(set) var calls: [Call] = []
    /// Set while a request is in flight, so a test can prove only one runs at a time.
    private(set) var maxConcurrentRequests = 0
    private var inFlight = 0

    func listStatus(mangaID: Int) async throws -> MALListStatus? {
        try await track {
            calls.append(.read(mangaID: mangaID))
            switch statuses[mangaID] ?? .success(nil) {
            case let .success(status): return status
            case let .failure(error): throw error
            }
        }
    }

    func updateProgress(mangaID: Int, update: MALListStatusUpdate) async throws -> MALListStatus {
        try await track {
            calls.append(.update(mangaID: mangaID,
                                 status: update.status,
                                 progress: update.numChaptersRead))
            guard var scripted = updates[mangaID], !scripted.isEmpty else {
                return MALListStatus(status: update.status ?? "reading",
                                     numChaptersRead: update.numChaptersRead)
            }
            let next = scripted.removeFirst()
            updates[mangaID] = scripted
            switch next {
            case let .success(status): return status
            case let .failure(error): throw error
            }
        }
    }

    private func track<T>(_ body: () throws -> T) async throws -> T {
        inFlight += 1
        maxConcurrentRequests = max(maxConcurrentRequests, inFlight)
        defer { inFlight -= 1 }
        // A suspension point inside the request, so an incorrectly parallel drain would
        // actually overlap here rather than being serialized by luck.
        await Task.yield()
        return try body()
    }
}

@MainActor
private final class FakeSyncAccount: MALSyncAccount {
    var syncUserID: Int?
    var syncEnabled = true
    var automaticallyAddsTitles = true
    private(set) var reauthorizationCount = 0
    private(set) var reportedSkipped: [Int] = []

    init(userID: Int? = 7) { self.syncUserID = userID }

    func reauthorizationRequired() { reauthorizationCount += 1 }

    func syncActivityChanged(skipped: Int) { reportedSkipped.append(skipped) }
}

// MARK: - Tests

@MainActor
final class MALProgressCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var outbox: MALProgressOutbox!
    private var client: ScriptedDeliveryClient!
    private var account: FakeSyncAccount!
    private var now = Date(timeIntervalSince1970: 1_000)
    private var slept: [TimeInterval] = []

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MALProgressCoordinatorTests-\(UUID().uuidString)")
        outbox = MALProgressOutbox(directory: directory)
        client = ScriptedDeliveryClient()
        account = FakeSyncAccount()
        now = Date(timeIntervalSince1970: 1_000)
        slept = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeCoordinator(
        malIDs: [WorkID: Int] = [:],
        listingParticipates: @escaping (ListingKey) -> Bool = { _ in true }
    ) -> MALProgressCoordinator {
        MALProgressCoordinator(
            outbox: outbox,
            client: client,
            account: account,
            malID: { malIDs[$0] },
            now: { [unowned self] in self.now },
            // Sleeping advances the deterministic clock instead of waiting, so backoff is
            // observable without the test taking six hours.
            sleep: { [unowned self] seconds in
                self.slept.append(seconds)
                self.now = self.now.addingTimeInterval(seconds)
            },
            jitter: { $0 }, listingParticipates: listingParticipates
        )
    }

    private func completion(workID: WorkID = WorkID(),
                            malID: Int? = nil,
                            progress: Int,
                            at date: Date? = nil,
                            sourceId: String = "mangadex") -> ChapterCompletion {
        let manga = Manga(id: "m", sourceId: sourceId, title: "T", description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: malID)
        let chapter = Chapter(id: "c", number: String(progress), title: nil)
        return ChapterCompletion(manga: manga, chapter: chapter, workID: workID,
                                 progress: progress, completedAt: date ?? now)
    }

    func testLocalCompletionNeverReachesMALOutbox() {
        let coordinator = makeCoordinator(listingParticipates: { key in key.sourceId != "local" })
        coordinator.chapterCompleted(completion(progress: 12, sourceId: "local"))
        let reloaded = MALProgressOutbox(directory: directory)
        XCTAssertNil(reloaded.nextEligible(userID: 7, at: now))
        XCTAssertEqual(reloaded.summary(userID: 7).deferred, 0)
    }

    // MARK: Completion sink

    func testCompletionWithAKnownMALIDIsQueuedSynchronouslyWithoutNetworkWork() {
        let coordinator = makeCoordinator()

        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        // Reconstructing the outbox proves it reached disk during the synchronous call.
        let reloaded = MALProgressOutbox(directory: directory)
        XCTAssertEqual(reloaded.nextEligible(userID: 7, at: now)?.desiredProgress, 12)
        XCTAssertEqual(client.calls, [])
    }

    func testSignedOutCompletionsAreNeverQueuedForAFutureAccount() {
        account.syncUserID = nil
        let coordinator = makeCoordinator()

        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        account.syncUserID = 7
        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
        XCTAssertEqual(outbox.summary(userID: 7).deferred, 0)
    }

    func testSyncDisabledCompletionsDoNotEnterTheOutbox() {
        account.syncEnabled = false
        let coordinator = makeCoordinator()

        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
        XCTAssertEqual(outbox.summary(userID: 7).deferred, 0)
    }

    func testCompletionWithoutAMALIDIsDeferredUntilMetadataArrives() async {
        let workID = WorkID()
        let coordinator = makeCoordinator(malIDs: [:])

        coordinator.chapterCompleted(completion(workID: workID, progress: 5))

        XCTAssertEqual(outbox.summary(userID: 7).deferred, 1)
        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
    }

    func testDeferredProgressIsPromotedWhenTheWorkLearnsItsMALID() async {
        let workID = WorkID()
        var malIDs: [WorkID: Int] = [:]
        let coordinator = MALProgressCoordinator(
            outbox: outbox,
            client: client,
            account: account,
            malID: { malIDs[$0] },
            now: { [unowned self] in self.now },
            sleep: { [unowned self] seconds in self.now = self.now.addingTimeInterval(seconds) },
            jitter: { $0 }
        )
        coordinator.chapterCompleted(completion(workID: workID, progress: 5))

        malIDs[workID] = 99
        coordinator.workMetadataChanged(workID)

        XCTAssertEqual(outbox.summary(userID: 7).deferred, 0)
        XCTAssertEqual(outbox.nextEligible(userID: 7, at: now)?.mangaID, 99)
    }

    // MARK: Reconciliation

    func testRemoteProgressAtOrAboveDesiredDropsTheItemWithoutWriting() async {
        client.statuses[42] = .success(MALListStatus(status: "reading", numChaptersRead: 20))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        XCTAssertEqual(client.calls, [.read(mangaID: 42)])
        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
    }

    func testLowerRemoteProgressIsAdvancedWithoutTouchingTheExistingStatus() async {
        client.statuses[42] = .success(MALListStatus(status: "on_hold", numChaptersRead: 3))
        client.updates[42] = [.success(MALListStatus(status: "on_hold", numChaptersRead: 12))]
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        XCTAssertEqual(client.calls,
                       [.read(mangaID: 42), .update(mangaID: 42, status: nil, progress: 12)])
        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
    }

    func testAnAbsentTitleIsAddedAsReadingOnlyWhenAutomaticAdditionIsOn() async {
        client.statuses[42] = .success(nil)
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        XCTAssertEqual(client.calls,
                       [.read(mangaID: 42), .update(mangaID: 42, status: "reading", progress: 12)])
    }

    func testAnAbsentTitleIsSkippedRatherThanRetriedWhenAutomaticAdditionIsOff() async {
        account.automaticallyAddsTitles = false
        client.statuses[42] = .success(nil)
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        XCTAssertEqual(client.calls, [.read(mangaID: 42)])
        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
        XCTAssertEqual(coordinator.skippedCount, 1)
        XCTAssertEqual(account.reportedSkipped, [1], "Settings follows the drain, not a poll")
    }

    func testAnUpdateReportingLessThanDesiredIsNotTreatedAsDelivered() async {
        client.statuses[42] = .success(MALListStatus(status: "reading", numChaptersRead: 3))
        client.updates[42] = [.success(MALListStatus(status: "reading", numChaptersRead: 4))]
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        let item = outbox.nextEligible(userID: 7, at: now.addingTimeInterval(86_400))
        XCTAssertEqual(item?.desiredProgress, 12)
        XCTAssertEqual(item?.retryCount, 1)
    }

    // MARK: Retry policy

    func testTransientFailuresBackOffExponentiallyFromOneMinuteAndCapAtSixHours() async {
        client.statuses[42] = .failure(.transient(retryAfter: nil))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        var delays: [TimeInterval] = []
        for _ in 0..<12 {
            let before = now
            await coordinator.drain()
            let item = outbox.nextEligible(userID: 7, at: .distantFuture)
            delays.append(item!.nextAttemptAt.timeIntervalSince(before))
            now = item!.nextAttemptAt
        }

        XCTAssertEqual(Array(delays.prefix(4)), [60, 120, 240, 480])
        XCTAssertEqual(delays.last, 6 * 60 * 60)
    }

    func testALongerRetryAfterOverridesTheComputedBackoff() async {
        client.statuses[42] = .failure(.transient(retryAfter: 900))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        XCTAssertEqual(outbox.nextEligible(userID: 7, at: .distantFuture)?.nextAttemptAt,
                       now.addingTimeInterval(900))
    }

    func testAHigherDesiredProgressResetsRetryMetadata() async {
        client.statuses[42] = .failure(.transient(retryAfter: nil))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))
        await coordinator.drain()
        XCTAssertEqual(outbox.nextEligible(userID: 7, at: .distantFuture)?.retryCount, 1)

        coordinator.chapterCompleted(completion(malID: 42, progress: 13))

        let item = outbox.nextEligible(userID: 7, at: now)
        XCTAssertEqual(item?.desiredProgress, 13)
        XCTAssertEqual(item?.retryCount, 0)
    }

    func testCancellationLeavesTheItemUntouchedAndCountsNoAttempt() async {
        client.statuses[42] = .failure(.cancelled)
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        let item = outbox.nextEligible(userID: 7, at: now)
        XCTAssertEqual(item?.retryCount, 0)
        XCTAssertNil(item?.failure)
    }

    func testAReauthorizationFailurePausesTheDrainAndRetainsTheQueue() async {
        client.statuses[42] = .failure(.reauthorizationRequired)
        client.statuses[43] = .success(MALListStatus(status: "reading", numChaptersRead: 99))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))
        coordinator.chapterCompleted(completion(malID: 43, progress: 1,
                                                at: now.addingTimeInterval(1)))

        await coordinator.drain()

        XCTAssertEqual(account.reauthorizationCount, 1)
        XCTAssertEqual(coordinator.pause, .reauthorizationRequired)
        XCTAssertEqual(client.calls, [.read(mangaID: 42)])
        XCTAssertNotNil(outbox.nextEligible(userID: 7, at: now))
    }

    func testAPermanentItemFailureBlocksOneTitleAndOthersKeepDraining() async {
        client.statuses[42] = .failure(.permanentItem(status: 404))
        client.statuses[43] = .success(MALListStatus(status: "reading", numChaptersRead: 99))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))
        coordinator.chapterCompleted(completion(malID: 43, progress: 1,
                                                at: now.addingTimeInterval(1)))
        now = now.addingTimeInterval(1)

        await coordinator.drain()

        XCTAssertEqual(client.calls, [.read(mangaID: 42), .read(mangaID: 43)])
        let summary = outbox.summary(userID: 7)
        XCTAssertEqual(summary.blocked, 1)
        XCTAssertEqual(summary.pending, 0)
    }

    func testAnAccountRefusalPausesTheWholeDrain() async {
        client.statuses[42] = .failure(.accountBlocked)
        client.statuses[43] = .success(MALListStatus(status: "reading", numChaptersRead: 99))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))
        coordinator.chapterCompleted(completion(malID: 43, progress: 1,
                                                at: now.addingTimeInterval(1)))

        await coordinator.drain()

        XCTAssertEqual(coordinator.pause, .accountBlocked)
        XCTAssertEqual(client.calls, [.read(mangaID: 42)])
    }

    func testAnUnknownFailureBacksOffInsteadOfSpinning() async {
        client.statuses[42] = .failure(.unknown(status: 418))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.drain()

        XCTAssertEqual(client.calls, [.read(mangaID: 42)])
        XCTAssertEqual(outbox.nextEligible(userID: 7, at: .distantFuture)?.failure, .unknown)
        XCTAssertEqual(outbox.nextEligible(userID: 7, at: .distantFuture)?.nextAttemptAt,
                       now.addingTimeInterval(60))
    }

    // MARK: Account boundary and serialization

    func testANewlySignedInUserNeverDrainsThePreviousUsersItems() async {
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        account.syncUserID = 8
        await coordinator.drain()

        XCTAssertEqual(client.calls, [])
        XCTAssertNotNil(outbox.nextEligible(userID: 7, at: now))
    }

    func testConcurrentDrainsRunAsOneSerialPass() async {
        client.statuses[42] = .success(MALListStatus(status: "reading", numChaptersRead: 99))
        client.statuses[43] = .success(MALListStatus(status: "reading", numChaptersRead: 99))
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 1))
        coordinator.chapterCompleted(completion(malID: 43, progress: 1,
                                                at: now.addingTimeInterval(1)))
        now = now.addingTimeInterval(1)

        async let first: Void = coordinator.drain()
        async let second: Void = coordinator.drain()
        _ = await (first, second)

        XCTAssertEqual(client.maxConcurrentRequests, 1)
        XCTAssertEqual(client.calls.count, 2)
    }

    func testRunningUntilIdleSleepsTheScheduledBackoffAndThenRetries() async {
        client.statuses[42] = .success(MALListStatus(status: "reading", numChaptersRead: 3))
        client.updates[42] = [
            .failure(.transient(retryAfter: nil)),
            .success(MALListStatus(status: "reading", numChaptersRead: 12))
        ]
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))

        await coordinator.runUntilIdle()

        XCTAssertEqual(slept, [60])
        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
    }

    func testDrainingDoesNothingWhileSyncIsDisabled() async {
        let coordinator = makeCoordinator()
        coordinator.chapterCompleted(completion(malID: 42, progress: 12))
        account.syncEnabled = false

        await coordinator.drain()

        XCTAssertEqual(client.calls, [])
    }
}
