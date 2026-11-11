import Foundation

/// Chapter counts for the chooser's top three choices (design §3), so a "possible match"
/// is informative. Reads `ListingCountCache` first and writes what it counts back, in the
/// same distinct-chapter units fulfillment ranks on. A Listing missing from the result is
/// **unknown** — shown as "Chapter count unknown", never as zero.
@MainActor
final class MALHubChapterCountLoader {
    static let countedChoices = 3
    private static let maxInFlight = 4

    private let registry: SourceRegistry
    private let cache: ListingCountCache
    private let challengeActive: @Sendable () async -> Bool
    private let deadline: TimeInterval

    init(registry: SourceRegistry, cache: ListingCountCache,
         challengeActive: @escaping @Sendable () async -> Bool = MALHubChallenge.isActive,
         deadline: TimeInterval = 8) {
        self.registry = registry
        self.cache = cache
        self.challengeActive = challengeActive
        self.deadline = deadline
    }

    /// Exact matches first, then the registry's Source order — the order the chooser shows.
    func load(_ groups: [MALHubSourceGroup]) async -> [ListingKey: Int] {
        let order = Dictionary(registry.sources.enumerated().map { ($1.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        let choices = groups.flatMap(\.choices).sorted { lhs, rhs in
            let lhsRank = lhs.kind == .exact ? 0 : 1
            let rhsRank = rhs.kind == .exact ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (order[lhs.manga.sourceId] ?? .max) < (order[rhs.manga.sourceId] ?? .max)
        }

        // The cache is main-actor state: read it here, and record below, never in a child task.
        var counts: [ListingKey: Int] = [:]
        var toFetch: [(ListingKey, any MangaSource)] = []
        for choice in choices.prefix(Self.countedChoices) {
            let listing = ListingKey(choice.manga)
            if let cached = cache.count(for: listing) {
                counts[listing] = cached
            } else if let source = registry.source(id: listing.sourceId) {
                toFetch.append((listing, source))
            }
        }

        let challengeActive = challengeActive
        let deadline = deadline
        await withTaskGroup(of: (ListingKey, Int?).self) { group in
            var pending = toFetch.makeIterator()
            func addNext() {
                guard let (listing, source) = pending.next() else { return }
                group.addTask {
                    let count = await Self.count(listing, on: source, deadline: deadline,
                                                 challengeActive: challengeActive)
                    return (listing, count)
                }
            }
            for _ in 0..<Self.maxInFlight { addNext() }
            while let (listing, count) = await group.next() {
                if let count {
                    counts[listing] = count
                    cache.record(count, for: listing)
                }
                addNext()
            }
        }
        return counts
    }

    /// `nil` on a throw or after `deadline` seconds — time with a challenge sheet up doesn't count.
    private nonisolated static func count(_ listing: ListingKey, on source: any MangaSource,
                                          deadline: TimeInterval,
                                          challengeActive: @escaping @Sendable () async -> Bool) async -> Int? {
        do {
            let chapters = try await withThrowingTaskGroup(of: [Chapter].self) { group in
                group.addTask { try await source.chapters(mangaId: listing.mangaId) }
                group.addTask {
                    var elapsed = 0.0
                    while elapsed < deadline {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        if !(await challengeActive()) { elapsed += 0.25 }
                    }
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
            return FulfillmentRouter.distinctChapterCount(chapters)
        } catch {
            return nil
        }
    }
}
