import Foundation

/// Disposable read-through cache for MAL detail payloads. Disk failures are misses: a
/// cache outage must never turn a recommendation lookup into an app error.
actor MALDetailStore {
    static let ttl: TimeInterval = 24 * 60 * 60

    private struct Entry: Codable {
        let detail: MyAnimeListMangaDetail
        let fetchedAt: Date
    }

    private let directory: URL
    private var entries: [Int: Entry] = [:]
    /// Keyed by MAL id; the token tells a finishing fetch whether it is still the current
    /// one, so a fetch orphaned by `invalidate` can neither write nor clear a newer fetch.
    private var inFlight: [Int: (token: UUID, task: Task<MyAnimeListMangaDetail?, Never>)] = [:]
    private var loaded = false

    private var fileURL: URL { directory.appendingPathComponent("mal-detail.json") }

    /// `Caches/MALDetail/`: disposable, so the OS may evict it and the next fetch repairs it.
    nonisolated static func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MALDetail", isDirectory: true)
    }

    init(directory: URL = MALDetailStore.cachesDirectory()) {
        self.directory = directory
    }

    func detail(for malID: Int, now: Date = Date(),
                fetch: @escaping @Sendable (Int) async throws -> MyAnimeListMangaDetail)
        async -> MyAnimeListMangaDetail? {
        loadIfNeeded()
        if let entry = entries[malID], now.timeIntervalSince(entry.fetchedAt) < Self.ttl {
            return entry.detail
        }
        if let current = inFlight[malID] { return await current.task.value }

        // A failed refresh serves the expired record (stale-if-offline) and leaves its
        // `fetchedAt` alone, so the next call still sees it as expired and retries.
        let stale = entries[malID]?.detail
        let token = UUID()
        let task: Task<MyAnimeListMangaDetail?, Never> = Task { [weak self] in
            do {
                let value = try await fetch(malID)
                await self?.succeed(malID: malID, token: token, detail: value, fetchedAt: now)
                return value
            } catch {
                // Cancellation included: nothing is written, and no negative entry exists.
                await self?.finish(malID: malID, token: token)
                return stale
            }
        }
        inFlight[malID] = (token, task)
        return await task.value
    }

    func invalidate(malID: Int) {
        loadIfNeeded()
        entries.removeValue(forKey: malID)
        inFlight[malID]?.task.cancel()
        inFlight.removeValue(forKey: malID)
        save()
    }

    private func succeed(malID: Int, token: UUID, detail: MyAnimeListMangaDetail, fetchedAt: Date) {
        guard inFlight[malID]?.token == token else { return }
        entries[malID] = Entry(detail: detail, fetchedAt: fetchedAt)
        save()
        inFlight.removeValue(forKey: malID)
    }

    private func finish(malID: Int, token: UUID) {
        guard inFlight[malID]?.token == token else { return }
        inFlight.removeValue(forKey: malID)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? decoder.decode([String: Entry].self, from: data) else { return }
        entries = raw.reduce(into: [:]) { result, pair in
            if let id = Int(pair.key) { result[id] = pair.value }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let raw = Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
            try encoder.encode(raw).write(to: fileURL, options: .atomic)
        } catch {
            // Cache persistence is best effort.
        }
    }
}
