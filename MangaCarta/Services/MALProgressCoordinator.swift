//
//  MALProgressCoordinator.swift
//  MangaCarta
//
//  Where a completed chapter becomes a queued MyAnimeList update, and where that queue is
//  drained one title at a time.
//
//  Two halves, deliberately separated:
//
//  • The completion sink is synchronous and network-free. It runs on the reader's path, so
//    it does exactly one thing — write the fact to the durable outbox — and returns.
//  • The drain is a single serial task. Only one request is ever in flight, because MAL has
//    no compare-and-swap and two overlapping writes to one title cannot be reasoned about.
//

import Foundation

/// The two authenticated operations the drain needs. Narrower than
/// `MALAuthenticatedClient` on purpose: the coordinator has no business refreshing tokens
/// or reading identity, and a test needs only these two to script every path.
protocol MALProgressDelivering: Sendable {
    func listStatus(mangaID: Int) async throws -> MALListStatus?
    func updateProgress(mangaID: Int, update: MALListStatusUpdate) async throws -> MALListStatus
}

extension MALAuthenticatedClient: MALProgressDelivering {}

/// What the coordinator needs to know about the signed-in account, and the one thing it
/// needs to tell it. Kept as a protocol so the drain does not depend on `MALAccountStore`'s
/// whole state machine — and so a test does not have to build a sign-in to exercise a retry.
@MainActor
protocol MALSyncAccount: AnyObject {
    /// The MAL user id whose queue may be drained, or `nil` when signed out. Every outbox
    /// operation is keyed by it, which is what keeps one account's progress off another's
    /// list.
    var syncUserID: Int? { get }
    var syncEnabled: Bool { get }
    var automaticallyAddsTitles: Bool { get }
    func reauthorizationRequired()
    /// Told after each item's outcome so Settings can follow the queue without polling it.
    /// `skipped` is cumulative for this session — a skipped title is dropped, not stored.
    func syncActivityChanged(skipped: Int)
}

extension MALAccountStore: MALSyncAccount {
    var syncUserID: Int? {
        guard case let .signedIn(profile, syncEnabled, _) = stableState, syncEnabled else {
            return nil
        }
        return profile.id
    }

    var syncEnabled: Bool {
        if case let .signedIn(_, enabled, _) = stableState { return enabled }
        return false
    }

    var automaticallyAddsTitles: Bool {
        if case let .signedIn(_, _, adds) = stableState { return adds }
        return false
    }
}

@MainActor
final class MALProgressCoordinator {
    /// Why the drain stopped short of emptying the queue. Both cases retain the outbox:
    /// nothing here is a reason to discard a user's progress.
    enum Pause: Equatable {
        case reauthorizationRequired
        case accountBlocked
    }

    static let initialRetryDelay: TimeInterval = 60
    static let maximumRetryDelay: TimeInterval = 6 * 60 * 60

    private let outbox: any MALProgressOutboxProtocol
    private let client: any MALProgressDelivering
    private let account: any MALSyncAccount
    private let malID: (WorkID) -> Int?
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let jitter: (TimeInterval) -> TimeInterval
    private let listingParticipates: (ListingKey) -> Bool

    /// Non-nil exactly while a drain pass is running, so concurrent callers join the pass
    /// already in flight instead of starting a second one.
    private var drainTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    /// Whether the app currently wants the queue drained at all. Set by `start()` — scene
    /// activation, sign-in, or **Retry now** — and cleared by `stop()`. A completion recorded
    /// while backgrounded is queued but starts no network work of its own.
    private var isRunning = false

    private(set) var pause: Pause?

    /// Titles dropped because they are not on the user's list and automatic addition is off.
    /// In memory by design: it is a count for Settings, not durable state, and a relaunch
    /// showing zero skipped is better than persisting a number nothing can act on.
    private(set) var skippedCount = 0

    init(
        outbox: any MALProgressOutboxProtocol,
        client: any MALProgressDelivering,
        account: any MALSyncAccount,
        malID: @escaping (WorkID) -> Int?,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        jitter: @escaping (TimeInterval) -> TimeInterval = { $0 * Double.random(in: 0.8...1.0) }
        , listingParticipates: @escaping (ListingKey) -> Bool = { _ in true }
    ) {
        self.outbox = outbox
        self.client = client
        self.account = account
        self.malID = malID
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        self.listingParticipates = listingParticipates
    }

    // MARK: Completion sink

    /// Called synchronously by `HistoryStore` when a chapter goes incomplete → complete.
    /// Signed out or sync off, this does nothing at all: a completion recorded now must not
    /// become some future account's update, and disabling sync means disabling the queue.
    func chapterCompleted(_ completion: ChapterCompletion) {
        guard listingParticipates(ListingKey(completion.manga)) else { return }
        guard account.syncEnabled, let userID = account.syncUserID else { return }

        do {
            if let mangaID = completion.manga.malId ?? malID(completion.workID) {
                try outbox.enqueue(userID: userID, mangaID: mangaID,
                                   desiredProgress: completion.progress,
                                   completedAt: completion.completedAt)
            } else {
                // No MAL id yet. The progress subsystem never title-matches on its own; it
                // waits for the existing resolution path and promotes on the signal below.
                try outbox.defer(userID: userID, workID: completion.workID,
                                 desiredProgress: completion.progress,
                                 completedAt: completion.completedAt)
            }
        } catch {
            // The local read is already durable in HistoryStore; a failed outbox write must
            // not propagate into the reader. The next completion retries the write.
            return
        }
        scheduleDrainIfRunning()
    }

    /// The signal that a Work has learned external ids. Promotes anything deferred for it.
    func workMetadataChanged(_ workID: WorkID) {
        guard account.syncEnabled, let userID = account.syncUserID,
              let mangaID = malID(workID) else { return }
        try? outbox.promote(userID: userID, workID: workID, toMangaID: mangaID)
        scheduleDrainIfRunning()
    }

    // MARK: Lifecycle

    /// Starts the drain loop if it is not already running. Safe to call on every trigger —
    /// scene activation, sign-in, enqueue, or **Retry now**.
    func start() {
        isRunning = true
        scheduleDrainIfRunning()
    }

    private func scheduleDrainIfRunning() {
        guard isRunning, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runUntilIdle()
            self?.loopTask = nil
        }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        drainTask?.cancel()
        drainTask = nil
    }

    /// Clears a pause and drains immediately. This is **Retry now**, and the only way past
    /// `reauthorizationRequired`/`accountBlocked` short of a relaunch.
    func retryNow() {
        pause = nil
        start()
    }

    func flush() {
        try? outbox.flush()
    }

    /// Drains, then sleeps the backoff it just scheduled and drains again, until the queue
    /// is empty or paused. The sleep is injected so retry timing is testable without waiting.
    func runUntilIdle() async {
        while !Task.isCancelled {
            await drain()
            guard pause == nil,
                  let userID = account.syncUserID,
                  let next = outbox.nextEligible(userID: userID, at: .distantFuture) else {
                return
            }
            let delay = next.nextAttemptAt.timeIntervalSince(now())
            guard delay > 0 else { return }  // Eligible already: `drain` would have taken it.
            do { try await sleep(delay) } catch { return }
        }
    }

    /// One serial pass over everything currently eligible. Concurrent callers join the pass
    /// in flight rather than opening a second one, which is what keeps a single request per
    /// MAL id.
    func drain() async {
        let task: Task<Void, Never>
        if let drainTask {
            task = drainTask
        } else {
            task = Task { [weak self] in await self?.performDrain() }
            drainTask = task
        }
        // Cancelling a caller does not cancel an unstructured task it merely awaits, so the
        // cancellation is handed across explicitly.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if drainTask == task { drainTask = nil }
    }

    private func performDrain() async {
        guard pause == nil, account.syncEnabled, let userID = account.syncUserID else { return }

        while !Task.isCancelled, pause == nil,
              let item = outbox.nextEligible(userID: userID, at: now()) {
            // The account can change under a long drain; a signed-out or switched account
            // must never receive the previous account's queued work.
            guard account.syncEnabled, account.syncUserID == userID else { return }
            let outcome = await deliver(item)
            switch outcome {
            case .delivered, .skipped:
                try? outbox.markDelivered(item)
                if case .skipped = outcome { skippedCount += 1 }
                account.syncActivityChanged(skipped: skippedCount)
            case .cancelled:
                // Not an attempt. The item is left exactly as it was.
                return
            case let .retry(failure, retryAfter):
                try? outbox.reschedule(item, failure: failure,
                                       nextAttemptAt: nextAttempt(after: item,
                                                                  retryAfter: retryAfter))
                account.syncActivityChanged(skipped: skippedCount)
            case .blockItem:
                try? outbox.reschedule(item, failure: .permanent, nextAttemptAt: .distantFuture)
                account.syncActivityChanged(skipped: skippedCount)
            case let .pause(reason):
                if reason == .reauthorizationRequired { account.reauthorizationRequired() }
                pause = reason
                return
            }
        }
    }

    // MARK: One item

    private enum Outcome: Equatable {
        case delivered
        /// Not on the list, and the user has asked not to add titles automatically.
        case skipped
        case cancelled
        case retry(MALProgressFailure, retryAfter: TimeInterval?)
        case blockItem
        case pause(Pause)
    }

    private func deliver(_ item: MALProgressOutboxItem) async -> Outcome {
        do {
            let remote = try await client.listStatus(mangaID: item.mangaID)

            if let remote {
                // Already at or past what we want: nothing to write, and writing anyway
                // could only lower a value another client raised.
                guard remote.numChaptersRead < item.desiredProgress else { return .delivered }
                return try await push(item, status: nil)
            }
            guard account.automaticallyAddsTitles else { return .skipped }
            return try await push(item, status: "reading")
        } catch let failure as MALRequestFailure {
            return outcome(for: failure)
        } catch {
            return .retry(.unknown, retryAfter: nil)
        }
    }

    /// Sends the update and believes MAL only if the entry it returns is at least as far
    /// along as what was asked for. Anything lower is retried, never reported as delivered.
    private func push(_ item: MALProgressOutboxItem, status: String?) async throws -> Outcome {
        let confirmed = try await client.updateProgress(
            mangaID: item.mangaID,
            update: MALListStatusUpdate(status: status, numChaptersRead: item.desiredProgress)
        )
        return confirmed.numChaptersRead >= item.desiredProgress
            ? .delivered
            : .retry(.unknown, retryAfter: nil)
    }

    private func outcome(for failure: MALRequestFailure) -> Outcome {
        switch failure {
        case .cancelled:
            return .cancelled
        case let .transient(retryAfter):
            return .retry(.transient, retryAfter: retryAfter)
        case .reauthorizationRequired:
            return .pause(.reauthorizationRequired)
        case .accountBlocked:
            return .pause(.accountBlocked)
        case .permanentItem:
            return .blockItem
        case .unknown:
            return .retry(.unknown, retryAfter: nil)
        }
    }

    /// Exponential from one minute, capped at six hours, jittered so a fleet of clients does
    /// not retry in lockstep. A server-supplied `Retry-After` wins only when it is longer —
    /// it is a floor MAL asked for, not a licence to retry sooner.
    private func nextAttempt(after item: MALProgressOutboxItem,
                             retryAfter: TimeInterval?) -> Date {
        let exponential = Self.initialRetryDelay * pow(2, Double(item.retryCount))
        var delay = jitter(min(exponential, Self.maximumRetryDelay))
        if let retryAfter, retryAfter > delay { delay = retryAfter }
        return now().addingTimeInterval(delay)
    }
}
