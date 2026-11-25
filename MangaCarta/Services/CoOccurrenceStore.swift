import Foundation

actor CoOccurrenceStore {
    static func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("analytics", isDirectory: true)
    }

    private let directory: URL
    private let clock: () -> Date
    private var tableCache: CoOccurrenceTableCache?
    private var poolCache: CoOccurrencePoolRecord?
    private var tableLoaded = false
    private var poolLoaded = false
    private var generation = 0
    private var tableTask: Task<Void, Never>?
    private var poolTask: Task<Void, Never>?

    private var tableURL: URL { directory.appendingPathComponent("cooccurrence-v1.json") }
    private var poolURL: URL { directory.appendingPathComponent("cooccurrence-pool.json") }

    init(directory: URL = CoOccurrenceStore.cachesDirectory(), clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.clock = clock
    }

    func table() -> CoOccurrenceTable? {
        loadTableIfNeeded()
        return tableCache?.table
    }

    @discardableResult
    func refreshTableIfNeeded(now: Date? = nil,
                              enabled: @escaping @Sendable () async -> Bool,
                              fetch: @escaping @Sendable () async -> Data?) -> Task<Void, Never>? {
        loadTableIfNeeded()
        let current = now ?? clock()
        if let cached = tableCache, let fetchedAt = cached.fetchedAt,
           current.timeIntervalSince(fetchedAt) < 7 * 24 * 60 * 60 { return nil }
        if let attemptedAt = tableCache?.attemptedAt,
           current.timeIntervalSince(attemptedAt) < 24 * 60 * 60 { return nil }
        if let tableTask { return tableTask }
        let requestedGeneration = generation
        let task = Task {
            guard await enabled() else { await self.discardTableTask(generation: requestedGeneration); return }
            let data = await fetch()
            let parsed = data.flatMap { try? CoOccurrenceTable(data: $0).validated() }
            guard await enabled() else { await self.discardTableTask(generation: requestedGeneration); return }
            await self.finishTable(parsed, at: current, generation: requestedGeneration)
        }
        tableTask = task
        return task
    }

    func pool(malIDs: [Int], now: Date? = nil) -> CoOccurrencePoolRecord? {
        loadPoolIfNeeded()
        guard let poolCache, poolCache.malIDs == malIDs, poolCache.isFresh(now: now ?? clock()) else { return nil }
        return poolCache
    }

    @discardableResult
    func refreshPoolIfNeeded(malIDs: [Int], now: Date? = nil,
                             enabled: @escaping @Sendable () async -> Bool,
                             titles: @escaping CoOccurrenceCandidateProvider.Titles,
                             resolve: @escaping CoOccurrenceCandidateProvider.Resolve) -> Task<Void, Never>? {
        loadPoolIfNeeded()
        let current = now ?? clock()
        if let poolCache, poolCache.malIDs == malIDs, poolCache.isFresh(now: current) { return nil }
        if let poolTask { return poolTask }
        guard !malIDs.isEmpty else { return nil }
        let requestedGeneration = generation
        let task = Task {
            guard await enabled() else { await self.discardPoolTask(generation: requestedGeneration); return }
            guard let found = try? await titles(malIDs), await enabled() else {
                await self.discardPoolTask(generation: requestedGeneration)
                return
            }
            let resolved = await resolve(found)
            guard await enabled() else { await self.discardPoolTask(generation: requestedGeneration); return }
            let wanted = resolved.filter { malIDs.contains($0.key) }
            let record = CoOccurrencePoolRecord(malIDs: malIDs, fetchedAt: current, candidates: wanted)
            await self.finishPool(record, generation: requestedGeneration)
        }
        poolTask = task
        return task
    }

    func clear() {
        generation += 1
        tableTask?.cancel()
        poolTask?.cancel()
        tableTask = nil
        poolTask = nil
        tableCache = nil
        poolCache = nil
        tableLoaded = true
        poolLoaded = true
        try? FileManager.default.removeItem(at: tableURL)
        try? FileManager.default.removeItem(at: poolURL)
    }

    private func finishTable(_ table: CoOccurrenceTable?, at date: Date, generation expected: Int) {
        guard generation == expected else { return }
        tableTask = nil
        var cache = tableCache ?? CoOccurrenceTableCache(table: nil, fetchedAt: nil, attemptedAt: nil)
        cache.attemptedAt = date
        if let table {
            cache.table = table
            cache.fetchedAt = date
        }
        tableCache = cache
        save(cache, to: tableURL)
    }

    private func finishPool(_ record: CoOccurrencePoolRecord?, generation expected: Int) {
        guard generation == expected else { return }
        poolTask = nil
        guard let record else { return }
        poolCache = record
        save(record, to: poolURL)
    }

    private func discardTableTask(generation expected: Int) {
        guard generation == expected else { return }
        tableTask = nil
    }

    private func discardPoolTask(generation expected: Int) {
        guard generation == expected else { return }
        poolTask = nil
    }

    private func loadTableIfNeeded() {
        guard !tableLoaded else { return }
        tableLoaded = true
        guard let cache = try? JSONDecoder().decode(CoOccurrenceTableCache.self, from: Data(contentsOf: tableURL)) else {
            return
        }
        let table = cache.table.flatMap { try? $0.validated() }
        tableCache = CoOccurrenceTableCache(table: table, fetchedAt: table == nil ? nil : cache.fetchedAt,
                                            attemptedAt: cache.attemptedAt)
    }

    private func loadPoolIfNeeded() {
        guard !poolLoaded else { return }
        poolLoaded = true
        poolCache = try? JSONDecoder().decode(CoOccurrencePoolRecord.self, from: Data(contentsOf: poolURL))
    }

    private func save<Value: Encodable>(_ value: Value, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
