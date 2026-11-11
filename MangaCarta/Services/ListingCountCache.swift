//
//  ListingCountCache.swift
//  MangaCarta
//
//  The counts ADR-0004 ranks on. Counting a Listing means asking a source for its
//  whole chapter list — N round-trips, where the slowest source sets the wait — so
//  the count is cached and the detail page renders from the cache immediately.
//
//  Disposable by construction: losing this file costs one recount and nothing else,
//  which is why it lives in `Caches/` rather than beside the authoritative stores
//  in Application Support.
//

import Foundation

final class ListingCountCache {

    /// One entry: what we counted, and when. The timestamp is the whole reason this
    /// is a struct rather than a bare `Int`.
    private struct Entry: Codable, Equatable {
        let count: Int
        let countedAt: Date
    }

    /// ADR-0004's "~24h TTL". Chapter counts go stale in one direction only — a
    /// series gains chapters — so a day-old count is a slightly low guess rather
    /// than a wrong one, and the background reconcile catches up either way.
    static let ttl: TimeInterval = 24 * 60 * 60

    private var entries: [ListingKey: Entry] = [:]
    private let directory: URL
    private var loaded = false

    private var fileURL: URL { directory.appendingPathComponent("listing-counts.json") }

    /// `Caches/`, not Application Support: the system may empty this at any time and
    /// on a real device eventually will. Losing it costs one recount.
    /// `nonisolated` so it can be a default argument, which is evaluated off-actor.
    nonisolated static func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    init(directory: URL = ListingCountCache.cachesDirectory()) {
        self.directory = directory
    }

    /// The cached count, or `nil` when this Listing has never been counted **or was
    /// counted too long ago to trust**. Both cases are the same answer: unknown,
    /// never zero — the router depends on that difference.
    func count(for listing: ListingKey, now: Date = Date()) -> Int? {
        loadIfNeeded()
        guard let entry = entries[listing] else { return nil }
        guard now.timeIntervalSince(entry.countedAt) < Self.ttl else { return nil }
        return entry.count
    }

    func record(_ count: Int, for listing: ListingKey, now: Date = Date()) {
        loadIfNeeded()
        entries[listing] = Entry(count: count, countedAt: now)
        save()
    }

    // MARK: - Persistence

    /// Saved synchronously, unlike the debounced writes in `WorkStore` and
    /// `UpdateStateStore`. Those sit on the page-turn path and re-arm constantly;
    /// a count is written at most once per Listing per TTL, from a background
    /// reconcile, so there is nothing here to debounce away.
    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // A cache that cannot write is still a working cache for this session,
            // and the next launch simply recounts. Nothing here is worth surfacing.
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ListingKey: Entry].self, from: data)
        else { return }
        entries = decoded
    }
}
