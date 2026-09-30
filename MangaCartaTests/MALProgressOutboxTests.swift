//
//  MALProgressOutboxTests.swift
//  MangaCartaTests
//
//  Durable, account-bound coalescing of pending MyAnimeList progress.
//

import XCTest
@testable import MangaCarta

final class MALProgressOutboxTests: XCTestCase {
    private func makeDirectory() -> URL {
        makeTestDirectory("MALProgressOutboxTests")
            .appendingPathComponent("MALProgressOutboxTests-\(UUID().uuidString)")
    }

    func testEnqueueCoalescesToTheHighestProgressWithinOneAccountAndTitle() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let first = Date(timeIntervalSince1970: 100)
        let latest = Date(timeIntervalSince1970: 300)

        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: first)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 10,
                           completedAt: Date(timeIntervalSince1970: 200))
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 15, completedAt: latest)

        let item = try XCTUnwrap(outbox.nextEligible(userID: 7, at: latest))
        XCTAssertEqual(item.userID, 7)
        XCTAssertEqual(item.mangaID, 42)
        XCTAssertEqual(item.desiredProgress, 15)
        XCTAssertEqual(item.firstCompletedAt, first)
        XCTAssertEqual(item.latestCompletedAt, latest)
        XCTAssertNil(outbox.nextEligible(userID: 8, at: latest))
    }

    func testDeliveredProgressRemovesOnlyTheValueThatWasActuallySent() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: now)
        let attempted = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now))
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 15,
                           completedAt: now.addingTimeInterval(1))

        try outbox.markDelivered(attempted)

        XCTAssertEqual(outbox.nextEligible(userID: 7, at: now.addingTimeInterval(1))?.desiredProgress,
                       15)
        try outbox.markDelivered(try XCTUnwrap(
            outbox.nextEligible(userID: 7, at: now.addingTimeInterval(1))))
        XCTAssertNil(outbox.nextEligible(userID: 7, at: now.addingTimeInterval(1)))
    }

    // MARK: - Persistence

    func testPendingProgressSurvivesReconstructionFromDisk() throws {
        let directory = makeDirectory()
        let first = Date(timeIntervalSince1970: 100)
        let latest = Date(timeIntervalSince1970: 300)
        let outbox = MALProgressOutbox(directory: directory)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 15, completedAt: first)
        try outbox.enqueue(userID: 7, mangaID: 43, desiredProgress: 3, completedAt: latest)
        try outbox.enqueue(userID: 8, mangaID: 42, desiredProgress: 9, completedAt: latest)

        let reopened = MALProgressOutbox(directory: directory)

        let item = try XCTUnwrap(reopened.nextEligible(userID: 7, at: latest))
        XCTAssertEqual(item.mangaID, 42)
        XCTAssertEqual(item.desiredProgress, 15)
        XCTAssertEqual(item.firstCompletedAt, first)
        XCTAssertEqual(reopened.nextEligible(userID: 8, at: latest)?.desiredProgress, 9)
    }

    func testMissingFileReconstructsAsEmptyRatherThanFailing() {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        XCTAssertNil(outbox.nextEligible(userID: 7, at: Date(timeIntervalSince1970: 100)))
    }

    func testUnsupportedEnvelopeVersionIsQuarantinedRatherThanSilentlyOverwritten() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("mal-progress-outbox.json")
        let future = Data(#"{"version":99,"ready":[]}"#.utf8)
        try future.write(to: fileURL)

        let outbox = MALProgressOutbox(directory: directory)
        XCTAssertNil(outbox.nextEligible(userID: 7, at: Date(timeIntervalSince1970: 100)))

        let quarantined = directory.appendingPathComponent("mal-progress-outbox.quarantined.json")
        XCTAssertEqual(try Data(contentsOf: quarantined), future,
                       "the unreadable envelope must be preserved verbatim, not discarded")
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 1,
                           completedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(try Data(contentsOf: fileURL), future)
    }

    func testCorruptFileIsQuarantinedRatherThanSilentlyOverwritten() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("mal-progress-outbox.json")
        let corrupt = Data("{ this is not json".utf8)
        try corrupt.write(to: fileURL)

        let outbox = MALProgressOutbox(directory: directory)
        XCTAssertNil(outbox.nextEligible(userID: 7, at: Date(timeIntervalSince1970: 100)))

        let quarantined = directory.appendingPathComponent("mal-progress-outbox.quarantined.json")
        XCTAssertEqual(try Data(contentsOf: quarantined), corrupt)
    }

    // MARK: - Retry and failure classification

    func testTransientFailureReschedulesTheItemInsteadOfDroppingIt() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: now)
        let attempt = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now))

        try outbox.reschedule(attempt, failure: .transient, nextAttemptAt: now.addingTimeInterval(60))

        XCTAssertNil(outbox.nextEligible(userID: 7, at: now.addingTimeInterval(59)),
                     "a rescheduled item must not be handed out before its next attempt time")
        let retried = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now.addingTimeInterval(60)))
        XCTAssertEqual(retried.desiredProgress, 12)
        XCTAssertEqual(retried.retryCount, 1)
    }

    func testHigherProgressResetsRetryStateSoNewWorkIsNotHeldBehindOldBackoff() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: now)
        let attempt = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now))
        try outbox.reschedule(attempt, failure: .transient,
                              nextAttemptAt: now.addingTimeInterval(600))

        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 15,
                           completedAt: now.addingTimeInterval(1))

        let item = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now.addingTimeInterval(1)))
        XCTAssertEqual(item.desiredProgress, 15)
        XCTAssertEqual(item.retryCount, 0)
        XCTAssertNil(item.failure)
    }

    func testAStaleAttemptResultDoesNotOverwriteRetryStateForNewerProgress() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: now)
        let staleAttempt = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now))
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 15,
                           completedAt: now.addingTimeInterval(1))

        try outbox.reschedule(staleAttempt, failure: .permanent, nextAttemptAt: .distantFuture)

        let item = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now.addingTimeInterval(1)))
        XCTAssertEqual(item.desiredProgress, 15, "progress 15 must not be blocked by a result for 12")
        XCTAssertNil(item.failure)
    }

    func testPermanentFailureStopsTheItemFromBeingHandedOutAgain() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: now)
        try outbox.enqueue(userID: 7, mangaID: 43, desiredProgress: 4,
                           completedAt: now.addingTimeInterval(1))
        let attempt = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now))

        try outbox.reschedule(attempt, failure: .permanent, nextAttemptAt: .distantFuture)

        XCTAssertEqual(outbox.nextEligible(userID: 7, at: .distantFuture)?.mangaID, 43,
                       "a blocked title must not starve the rest of the queue")
        XCTAssertEqual(outbox.summary(userID: 7).blocked, 1)
    }

    // MARK: - Account isolation

    func testClearingOneAccountLeavesTheOtherAccountIntact() throws {
        let directory = makeDirectory()
        let outbox = MALProgressOutbox(directory: directory)
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: now)
        try outbox.enqueue(userID: 8, mangaID: 42, desiredProgress: 9, completedAt: now)

        try outbox.clear(userID: 7)

        XCTAssertNil(outbox.nextEligible(userID: 7, at: now))
        XCTAssertEqual(outbox.nextEligible(userID: 8, at: now)?.desiredProgress, 9)
        XCTAssertNil(MALProgressOutbox(directory: directory).nextEligible(userID: 7, at: now),
                     "clearing must be durable, not in-memory only")
    }

    // MARK: - Deferred Works awaiting a MAL id

    func testCompletionsForAWorkWithNoMALIdCoalesceWhileDeferred() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let work = WorkID()
        let first = Date(timeIntervalSince1970: 100)
        let latest = Date(timeIntervalSince1970: 300)

        try outbox.defer(userID: 7, workID: work, desiredProgress: 4, completedAt: first)
        try outbox.defer(userID: 7, workID: work, desiredProgress: 2, completedAt: latest)
        try outbox.defer(userID: 7, workID: work, desiredProgress: 9, completedAt: latest)

        XCTAssertNil(outbox.nextEligible(userID: 7, at: latest),
                     "a Work with no MAL id is not sendable and must not be handed out")
        XCTAssertEqual(outbox.summary(userID: 7).deferred, 1)
    }

    func testDeferredProgressBecomesSendableOnceAMALIdIsKnown() throws {
        let directory = makeDirectory()
        let outbox = MALProgressOutbox(directory: directory)
        let work = WorkID()
        let first = Date(timeIntervalSince1970: 100)
        let latest = Date(timeIntervalSince1970: 300)
        try outbox.defer(userID: 7, workID: work, desiredProgress: 4, completedAt: first)
        try outbox.defer(userID: 7, workID: work, desiredProgress: 9, completedAt: latest)

        try outbox.promote(userID: 7, workID: work, toMangaID: 42)

        let item = try XCTUnwrap(outbox.nextEligible(userID: 7, at: latest))
        XCTAssertEqual(item.mangaID, 42)
        XCTAssertEqual(item.desiredProgress, 9, "the coalesced maximum must survive promotion")
        XCTAssertEqual(item.firstCompletedAt, first)
        XCTAssertEqual(item.latestCompletedAt, latest)
        XCTAssertEqual(outbox.summary(userID: 7).deferred, 0)
        XCTAssertEqual(MALProgressOutbox(directory: directory)
            .nextEligible(userID: 7, at: latest)?.mangaID, 42,
                       "promotion must be durable")
    }

    func testPromotionMergesIntoProgressAlreadyQueuedForThatTitle() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let work = WorkID()
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 15, completedAt: now)
        try outbox.defer(userID: 7, workID: work, desiredProgress: 9,
                         completedAt: now.addingTimeInterval(1))

        try outbox.promote(userID: 7, workID: work, toMangaID: 42)

        let item = try XCTUnwrap(outbox.nextEligible(userID: 7, at: now.addingTimeInterval(1)))
        XCTAssertEqual(item.desiredProgress, 15, "promotion must never lower queued progress")
        XCTAssertNil(outbox.nextEligible(userID: 8, at: now.addingTimeInterval(1)))
    }

    func testDeferredWorkIsIsolatedByAccount() throws {
        let outbox = MALProgressOutbox(directory: makeDirectory())
        let work = WorkID()
        let now = Date(timeIntervalSince1970: 100)
        try outbox.defer(userID: 7, workID: work, desiredProgress: 9, completedAt: now)

        try outbox.promote(userID: 8, workID: work, toMangaID: 42)

        XCTAssertNil(outbox.nextEligible(userID: 8, at: now),
                     "one account's Work must not be promotable by another account")
        XCTAssertEqual(outbox.summary(userID: 7).deferred, 1)
    }

    // MARK: - Privacy of the persisted payload

    func testPersistedPayloadCarriesNoTitlesURLsChapterLabelsOrTokens() throws {
        let directory = makeDirectory()
        let outbox = MALProgressOutbox(directory: directory)
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(userID: 7, mangaID: 42, desiredProgress: 12, completedAt: now)
        try outbox.defer(userID: 7, workID: WorkID(), desiredProgress: 3, completedAt: now)

        let raw = try XCTUnwrap(String(
            data: try Data(contentsOf: directory.appendingPathComponent("mal-progress-outbox.json")),
            encoding: .utf8))

        for forbidden in ["http", "chapter", "title", "token", "Bearer", "mangadex"] {
            XCTAssertFalse(raw.lowercased().contains(forbidden.lowercased()),
                           "persisted outbox must not contain \(forbidden)")
        }
    }
}
