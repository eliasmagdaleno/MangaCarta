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
    private var inFlight: [Int: Task<MyAnimeListMangaDetail?, Never>] = [:]
    private var loaded = false

    private var fileURL: URL { directory.appendingPathComponent("mal-detail.json") }

    nonisolated static func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
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
        if let task = inFlight[malID] { return await task.value }

        let stale = entries[malID]?.detail
        let task: Task<MyAnimeListMangaDetail?, Never> = Task { [weak self] in
            do {
                let value = try await fetch(malID)
                await self?.succeed(malID: malID, detail: value, fetchedAt: now)
                return value
            } catch is CancellationError {
                await self?.failed(malID: malID)
                return stale
            } catch {
                await self?.failed(malID: malID)
                return stale
            }
        }
        inFlight[malID] = task
        return await task.value
    }

    func invalidate(malID: Int) {
        loadIfNeeded()
        entries.removeValue(forKey: malID)
        inFlight[malID]?.cancel()
        inFlight.removeValue(forKey: malID)
        save()
    }

    private func succeed(malID: Int, detail: MyAnimeListMangaDetail, fetchedAt: Date) {
        guard inFlight[malID] != nil else { return }
        entries[malID] = Entry(detail: detail, fetchedAt: fetchedAt)
        save()
        inFlight.removeValue(forKey: malID)
    }

    private func failed(malID: Int) {
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
