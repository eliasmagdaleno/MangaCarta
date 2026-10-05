//
//  MALProgressOutbox.swift
//  MangaCarta
//
//  Durable, account-bound pending MyAnimeList progress.
//

import Foundation

enum MALProgressFailure: String, Codable, Equatable {
    case transient
    case unknown
    case permanent
}

/// Progress for a Work whose MAL id is not known yet. Keyed by `WorkID` because that is
/// the only stable identity available before resolution; it becomes a `MALProgressOutboxItem`
/// at promotion.
struct MALDeferredProgressItem: Codable, Equatable {
    let userID: Int
    let workID: WorkID
    var desiredProgress: Int
    var firstCompletedAt: Date
    var latestCompletedAt: Date
}

struct MALProgressOutboxItem: Codable, Equatable {
    let userID: Int
    let mangaID: Int
    var desiredProgress: Int
    var firstCompletedAt: Date
    var latestCompletedAt: Date
    var retryCount: Int
    var nextAttemptAt: Date
    var failure: MALProgressFailure?
}

/// A count-only view of an account's queue. Deliberately carries no titles or ids so it
/// can be logged or shown in Settings without leaking what the user reads.
struct MALProgressOutboxSummary: Equatable {
    let pending: Int
    let blocked: Int
    let deferred: Int
}

/// The narrow surface the delivery coordinator depends on. Encoding, versioning, key
/// representation, atomic writes, and quarantine stay inside the outbox; callers see only
/// queue operations.
protocol MALProgressOutboxProtocol: AnyObject {
    func enqueue(userID: Int, mangaID: Int, desiredProgress: Int, completedAt: Date) throws
    func `defer`(userID: Int, workID: WorkID, desiredProgress: Int, completedAt: Date) throws
    func promote(userID: Int, workID: WorkID, toMangaID mangaID: Int) throws
    /// The Work ids an account has progress deferred under, as recorded at completion time.
    func deferredWorkIDs(userID: Int) -> [WorkID]
    func nextEligible(userID: Int, at date: Date) -> MALProgressOutboxItem?
    func markDelivered(_ delivered: MALProgressOutboxItem) throws
    func reschedule(_ attempted: MALProgressOutboxItem,
                    failure: MALProgressFailure,
                    nextAttemptAt: Date) throws
    func summary(userID: Int) -> MALProgressOutboxSummary
    func clear(userID: Int) throws
    func flush() throws
}

final class MALProgressOutbox: MALProgressOutboxProtocol {
    private struct Key: Hashable {
        let userID: Int
        let mangaID: Int
    }

    private struct DeferredKey: Hashable {
        let userID: Int
        let workID: WorkID
    }

    private struct Envelope: Codable {
        let version: Int
        var ready: [MALProgressOutboxItem]
        var deferred: [MALDeferredProgressItem]?
    }

    private static let version = 1
    private let directory: URL
    private var ready: [Key: MALProgressOutboxItem] = [:]
    private var deferred: [DeferredKey: MALDeferredProgressItem] = [:]

    private var fileURL: URL { directory.appendingPathComponent("mal-progress-outbox.json") }
    private var quarantineURL: URL {
        directory.appendingPathComponent("mal-progress-outbox.quarantined.json")
    }

    init(directory: URL = WorkStore.applicationSupportDirectory()) {
        self.directory = directory
        load()
    }

    func enqueue(userID: Int, mangaID: Int, desiredProgress: Int,
                 completedAt: Date) throws {
        let key = Key(userID: userID, mangaID: mangaID)
        if var item = ready[key] {
            let increased = desiredProgress > item.desiredProgress
            item.desiredProgress = max(item.desiredProgress, desiredProgress)
            item.firstCompletedAt = min(item.firstCompletedAt, completedAt)
            item.latestCompletedAt = max(item.latestCompletedAt, completedAt)
            if increased {
                item.retryCount = 0
                item.nextAttemptAt = completedAt
                item.failure = nil
            }
            ready[key] = item
        } else {
            ready[key] = MALProgressOutboxItem(
                userID: userID,
                mangaID: mangaID,
                desiredProgress: desiredProgress,
                firstCompletedAt: completedAt,
                latestCompletedAt: completedAt,
                retryCount: 0,
                nextAttemptAt: completedAt,
                failure: nil
            )
        }
        try save()
    }

    /// Holds progress for a Work that has no MAL id yet. Deferred progress is never
    /// handed to `nextEligible`; it becomes sendable only via `promote`.
    func `defer`(userID: Int, workID: WorkID, desiredProgress: Int, completedAt: Date) throws {
        let key = DeferredKey(userID: userID, workID: workID)
        if var item = deferred[key] {
            item.desiredProgress = max(item.desiredProgress, desiredProgress)
            item.firstCompletedAt = min(item.firstCompletedAt, completedAt)
            item.latestCompletedAt = max(item.latestCompletedAt, completedAt)
            deferred[key] = item
        } else {
            deferred[key] = MALDeferredProgressItem(
                userID: userID,
                workID: workID,
                desiredProgress: desiredProgress,
                firstCompletedAt: completedAt,
                latestCompletedAt: completedAt
            )
        }
        try save()
    }

    /// Moves deferred progress onto a now-known MAL id, merging with anything already
    /// queued for that title. Merging goes through `enqueue`, so promotion can only ever
    /// raise the queued value.
    func promote(userID: Int, workID: WorkID, toMangaID mangaID: Int) throws {
        let key = DeferredKey(userID: userID, workID: workID)
        guard let item = deferred.removeValue(forKey: key) else { return }
        try enqueue(userID: userID, mangaID: mangaID,
                    desiredProgress: item.desiredProgress, completedAt: item.latestCompletedAt)
        let readyKey = Key(userID: userID, mangaID: mangaID)
        if var merged = ready[readyKey] {
            merged.firstCompletedAt = min(merged.firstCompletedAt, item.firstCompletedAt)
            ready[readyKey] = merged
        }
        try save()
    }

    func deferredWorkIDs(userID: Int) -> [WorkID] {
        deferred.keys.filter { $0.userID == userID }.map(\.workID)
    }

    func nextEligible(userID: Int, at date: Date) -> MALProgressOutboxItem? {
        ready.values
            .filter { $0.userID == userID && $0.failure != .permanent && $0.nextAttemptAt <= date }
            .sorted {
                ($0.firstCompletedAt, $0.mangaID) < ($1.firstCompletedAt, $1.mangaID)
            }
            .first
    }

    func markDelivered(_ delivered: MALProgressOutboxItem) throws {
        let key = Key(userID: delivered.userID, mangaID: delivered.mangaID)
        guard let current = ready[key],
              current.desiredProgress <= delivered.desiredProgress else { return }
        ready.removeValue(forKey: key)
        try save()
    }

    /// Records the outcome of a failed attempt. A result for progress the caller has
    /// since superseded is ignored: retry state belongs to the value now queued, not to
    /// the value that happened to be in flight.
    func reschedule(_ attempted: MALProgressOutboxItem,
                    failure: MALProgressFailure,
                    nextAttemptAt: Date) throws {
        let key = Key(userID: attempted.userID, mangaID: attempted.mangaID)
        guard var item = ready[key],
              item.desiredProgress <= attempted.desiredProgress else { return }
        item.failure = failure
        item.retryCount += 1
        item.nextAttemptAt = nextAttemptAt
        ready[key] = item
        try save()
    }

    /// Forgets everything pending for exactly one account, leaving other accounts alone.
    func clear(userID: Int) throws {
        ready = ready.filter { $0.value.userID != userID }
        deferred = deferred.filter { $0.value.userID != userID }
        try save()
    }

    func summary(userID: Int) -> MALProgressOutboxSummary {
        let mine = ready.values.filter { $0.userID == userID }
        return MALProgressOutboxSummary(
            pending: mine.filter { $0.failure != .permanent }.count,
            blocked: mine.filter { $0.failure == .permanent }.count,
            deferred: deferred.keys.filter { $0.userID == userID }.count
        )
    }

    func flush() throws {
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(version: Self.version,
                                ready: Array(ready.values),
                                deferred: Array(deferred.values))
        try JSONEncoder().encode(envelope).write(to: fileURL, options: .atomic)
    }

    private func load() {
        // A missing file is the ordinary first-launch case, not a fault.
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.version else {
            // Unreadable on-disk state is preserved rather than overwritten: it may hold
            // progress this build cannot parse, and a silent discard would lose it for good.
            quarantine(data)
            return
        }
        ready = Dictionary(uniqueKeysWithValues: envelope.ready.map {
            (Key(userID: $0.userID, mangaID: $0.mangaID), $0)
        })
        deferred = Dictionary(uniqueKeysWithValues: (envelope.deferred ?? []).map {
            (DeferredKey(userID: $0.userID, workID: $0.workID), $0)
        })
    }

    private func quarantine(_ data: Data) {
        try? data.write(to: quarantineURL, options: .atomic)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
