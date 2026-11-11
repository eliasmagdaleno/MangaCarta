import Foundation

@MainActor
final class MALHubChapterCountLoader {
    private struct CountContext {
        let registry: SourceRegistry
        let cache: ListingCountCache
        let challengeActive: @Sendable () async -> Bool
        let deadline: TimeInterval
    }
    private let registry: SourceRegistry
    private let cache: ListingCountCache
    private let challengeActive: @Sendable () async -> Bool
    private let deadline: TimeInterval

    init(registry: SourceRegistry, cache: ListingCountCache,
         challengeActive: @escaping @Sendable () async -> Bool = {
             await MainActor.run { WebViewService.shared.isChallengeActive }
         },
         deadline: TimeInterval = 8) {
        self.registry = registry
        self.cache = cache
        self.challengeActive = challengeActive
        self.deadline = deadline
    }

    func load(_ groups: [MALHubSourceGroup]) async -> [String: Int?] {
        let choices = groups.flatMap { group in
            group.choices.map { (group.sourceId, $0) }
        }
        .sorted { lhs, rhs in
            let lhsRank = lhs.1.kind == .exact ? 0 : 1
            let rhsRank = rhs.1.kind == .exact ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsSource = registry.sources.firstIndex { $0.id == lhs.0 } ?? .max
            let rhsSource = registry.sources.firstIndex { $0.id == rhs.0 } ?? .max
            return lhsSource < rhsSource
        }
        let selected = Array(choices.prefix(3))
        var output = Dictionary(uniqueKeysWithValues: choices.map { ($0.1.manga.id, nil as Int?) })
        await withTaskGroup(of: (String, Int?).self) { group in
            var pending = selected.makeIterator()
            var active = 0
            func addNext() {
                guard active < 4, let next = pending.next() else { return }
                active += 1
                let context = CountContext(registry: registry, cache: cache,
                                           challengeActive: challengeActive, deadline: deadline)
                group.addTask { [context] in
                    let value = await Self.count(next.1.manga, sourceID: next.0, context: context)
                    return (next.1.manga.id, value)
                }
            }
            for _ in 0..<4 { addNext() }
            while let result = await group.next() {
                active -= 1
                output[result.0] = result.1
                addNext()
            }
        }
        return output
    }

    private static func count(_ manga: Manga, sourceID: String, context: CountContext) async -> Int? {
        let listing = ListingKey(manga)
        if let cached = context.cache.count(for: listing) { return cached }
        guard let source = context.registry.source(id: sourceID) else { return nil }
        do {
            let chapters = try await withThrowingTaskGroup(of: [Chapter].self) { group in
                group.addTask { try await source.chapters(mangaId: manga.id) }
                group.addTask {
                    var elapsed = 0.0
                    while elapsed < context.deadline {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        if !(await context.challengeActive()) { elapsed += 0.25 }
                    }
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            let count = FulfillmentRouter.distinctChapterCount(chapters)
            context.cache.record(count, for: listing)
            return count
        } catch {
            return nil
        }
    }
}
