import Foundation

struct CoOccurrenceTable: Codable, Equatable {
    static let maximumBytes = 2 * 1024 * 1024
    static let minimumK = 20

    let version: Int
    let k: Int
    let pairs: [Int: [[Int]]]

    private struct Wire: Decodable {
        let v: Int
        let k: Int
        let pairs: [String: [[Int]]]
    }

    init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw CoOccurrenceError.invalidTable }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var pairs: [Int: [[Int]]] = [:]
        for (key, entries) in wire.pairs {
            guard let id = Int(key), entries.allSatisfy({ $0.count == 2 }) else {
                throw CoOccurrenceError.invalidTable
            }
            pairs[id] = entries
        }
        self.init(version: wire.v, k: wire.k, pairs: pairs)
    }

    init(version: Int = 1, k: Int = 20, pairs: [Int: [[Int]]]) {
        self.version = version
        self.k = k
        self.pairs = pairs
    }

    func validated() throws -> CoOccurrenceTable {
        guard version == 1, k >= Self.minimumK else { throw CoOccurrenceError.invalidTable }
        let cleaned = pairs.reduce(into: [Int: [[Int]]]()) { result, entry in
            guard entry.key > 0 else { return }
            let valid = entry.value.filter { pair in
                pair.count == 2 && pair[0] > 0 && pair[0] != entry.key && pair[1] >= Self.minimumK
            }
            result[entry.key] = valid
        }
        return CoOccurrenceTable(version: version, k: k, pairs: cleaned)
    }
}

struct CoOccurrenceError: Error { static let invalidTable = CoOccurrenceError() }

struct CoOccurrenceTableCache: Codable {
    var table: CoOccurrenceTable?
    var fetchedAt: Date?
    var attemptedAt: Date?
}

struct CoOccurrencePoolRecord: Codable {
    let malIDs: [Int]
    let fetchedAt: Date
    /// Keyed by the MAL id that was asked for. A matched Listing needn't publish one itself.
    let candidates: [Int: Manga]

    func isFresh(now: Date) -> Bool {
        // Explicitly typed: CI's older compiler can't type-check this as one expression.
        let day: TimeInterval = 86_400
        let lifetime: TimeInterval = candidates.isEmpty ? day : 14 * day
        return now.timeIntervalSince(fetchedAt) < lifetime
    }
}

struct CoOccurrenceCandidateProvider: CandidateProvider {
    typealias LoadWorks = @Sendable () async -> [Work]
    typealias Titles = @Sendable ([Int]) async throws -> [AniListWork]
    typealias Resolve = @Sendable ([AniListWork]) async -> [Int: Manga]
    typealias Enabled = @Sendable () async -> Bool

    let isEnabled: Enabled
    let fetchTable: @Sendable () async -> Data?
    let loadWorks: LoadWorks
    let titles: Titles
    let resolve: Resolve
    let store: CoOccurrenceStore

    func candidates(for profile: TasteProfile, excluding: Set<String>, limit: Int) async throws -> [ScoredManga] {
        guard await isEnabled() else { return [] }
        let table = await store.table()
        await store.refreshTableIfNeeded(enabled: isEnabled, fetch: fetchTable)
        guard await isEnabled(), let table else { return [] }

        let works = await loadWorks()
        let readSeeds = works.compactMap { work -> (Int, Double)? in
            guard let malID = work.externalIds.mal,
                  let weight = profile.workWeights[work.id] else { return nil }
            return (malID, weight)
        }
        guard await isEnabled(), !readSeeds.isEmpty else { return [] }

        // Another Source's copy of a title the reader has carries a different Listing id, so the
        // exclusion is widened to whole Works (Amendment 5 item 11).
        let excludedWorks = works.filter { work in
            Self.listings(of: work).contains { excluding.contains($0.mangaId) }
        }
        let excludedListings = Set(excludedWorks.flatMap(Self.listings))
        let excludedMAL = Set(excludedWorks.compactMap(\.externalIds.mal)).union(readSeeds.map(\.0))
        var scores: [Int: Double] = [:]
        for (seed, weight) in readSeeds {
            for (position, pair) in (table.pairs[seed] ?? []).enumerated() {
                // `validated()` guarantees the shape, whether the table was downloaded or read back.
                scores[pair[0], default: 0] += weight / Double(1 + position)
            }
        }
        let ranked = scores.keys.filter { !excludedMAL.contains($0) }
            .sorted { scores[$0, default: 0] != scores[$1, default: 0]
                ? scores[$0, default: 0] > scores[$1, default: 0] : $0 < $1 }
        let head = Array(ranked.prefix(12))
        let cached = await store.pool(malIDs: head)
        await store.refreshPoolIfNeeded(malIDs: head, enabled: isEnabled,
                                        titles: titles, resolve: resolve)
        guard await isEnabled(), let cached else { return [] }
        return head.compactMap { malID in
            guard let manga = cached.candidates[malID], !excluding.contains(manga.id),
                  !excludedListings.contains(ListingKey(manga)) else { return nil }
            return ScoredManga(manga: manga,
                               score: scores[malID, default: 0],
                               reason: "Readers also saved this",
                               reasonKind: .cooccurrence)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.manga.id < $1.manga.id }
        .prefix(limit).map { $0 }
    }

    private static func listings(of work: Work) -> [ListingKey] {
        work.listings + work.removedListings.map(\.key)
    }
}
