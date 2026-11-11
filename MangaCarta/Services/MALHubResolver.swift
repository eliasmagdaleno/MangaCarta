import Foundation

// Resolver assembly is intentionally explicit; long lines here mirror the policy's ordered steps.
// swiftlint:disable line_length

struct MALHubChoice: Equatable {
    let manga: Manga
    let sourceName: String
    let kind: Kind
    enum Kind: Equatable { case exact, possible }
}

struct MALHubSourceGroup: Equatable {
    let sourceId: String
    let sourceName: String
    let choices: [MALHubChoice]
    let ambiguous: Bool
    let status: Status
    enum Status: Equatable { case choices, noMatch, couldNotCheckTimedOut, couldNotCheckFailed }
}

enum MALHubResolution: Equatable {
    case open(Manga)
    case chooser([MALHubSourceGroup])
    case notFound([MALHubSourceGroup])
}

private actor MALHubSearchLimiter {
    let limit: Int
    var active = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ limit: Int) { self.limit = limit }
    func acquire() async { if active < limit { active += 1 } else { await withCheckedContinuation { waiters.append($0) } } }
    func release() { if let next = waiters.first { waiters.removeFirst(); next.resume() } else { active -= 1 } }
}

/// Resolves a tapped MAL card without mutating Work identity. All writes go through `confirm`.
@MainActor
final class MALHubResolver {
    private let registry: SourceRegistry
    private let store: MALSourceChoiceStore
    private let showAdultContent: Bool
    private let matcher: MALTitleMatcher
    private let challengeActive: @Sendable () async -> Bool
    private let deadline: TimeInterval
    private let probeInterval: TimeInterval
    private let alternativeTitles: @Sendable (Int) async throws -> [String]

    init(registry: SourceRegistry, store: MALSourceChoiceStore,
         showAdultContent: Bool, matcher: MALTitleMatcher = .init(),
         challengeActive: @escaping @Sendable () async -> Bool = { await MainActor.run { WebViewService.shared.isChallengeActive } },
         deadline: TimeInterval = 8, probeInterval: TimeInterval = 0.25,
         alternativeTitles: @escaping @Sendable (Int) async throws -> [String] = { try await MyAnimeListAPI.alternativeTitles(id: $0) }) {
        self.registry = registry; self.store = store; self.showAdultContent = showAdultContent
        self.matcher = matcher; self.challengeActive = challengeActive; self.deadline = deadline
        self.probeInterval = probeInterval; self.alternativeTitles = alternativeTitles
    }

    func confirm(_ choice: MALHubChoice, for candidate: MALDiscoveryCandidate) async {
        await store.confirm(malId: candidate.malId, sourceId: choice.manga.sourceId,
                            manga: choice.manga, title: candidate.title)
    }

    func resolve(candidate: MALDiscoveryCandidate, detail: MyAnimeListMangaDetail? = nil,
                 sourceIDs: Set<String>? = nil) async -> MALHubResolution {
        if let listing = candidate.resolvedListing { return .open(listing) }
        if let remembered = await store.choice(for: candidate.malId) {
            if let source = registry.source(id: remembered.sourceId), source.isBrowsable,
               !source.isNSFW || showAdultContent, registry.admitsForDiscovery(remembered.manga) {
                do {
                    let fetched = try await source.mangaDetail(id: remembered.manga.id)
                    let refreshed = remembered.manga.with(contentRating: fetched.contentRating)
                    guard registry.admitsForDiscovery(refreshed) else {
                        await store.remove(malId: candidate.malId)
                        return await search(candidate: candidate, detail: detail, sourceIDs: sourceIDs)
                    }
                    return .open(refreshed)
                } catch { }
            } else { await store.remove(malId: candidate.malId) }
        }
        return await search(candidate: candidate, detail: detail, sourceIDs: sourceIDs)
    }

    private func search(candidate: MALDiscoveryCandidate, detail: MyAnimeListMangaDetail?, sourceIDs: Set<String>?) async -> MALHubResolution {
        let sources = registry.visibleSources(includeAdult: showAdultContent).filter { $0.id != LocalSource.sourceID && (sourceIDs == nil || sourceIDs!.contains($0.id)) }
        guard !sources.isEmpty else { return .notFound([]) }
        var spellings = [candidate.title]
        if let detail { spellings += Array(detail.allTitles.dropFirst().prefix(2)) } else if let fetched = try? await alternativeTitles(candidate.malId) { spellings += Array(fetched.dropFirst().prefix(2)) }
        spellings = spellings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen = Set<String>(); spellings = spellings.filter { seen.insert(MALTitleMatcher.normalize($0)).inserted }
        let limiter = MALHubSearchLimiter(4)
        return await withTaskGroup(of: MALHubSourceGroup.self, returning: MALHubResolution.self) { group in
            for source in sources { group.addTask { await self.resolve(source: source, spellings: spellings, candidate: candidate, detail: detail, limiter: limiter) } }
            var groups: [MALHubSourceGroup] = []; for await groupResult in group { groups.append(groupResult) }
            groups.sort { lhs, rhs in sources.firstIndex(where: { $0.id == lhs.sourceId })! < sources.firstIndex(where: { $0.id == rhs.sourceId })! }
            let exact = groups.flatMap(\.choices).filter { $0.kind == .exact }
            return exact.count == 1 ? .open(exact[0].manga) : (groups.contains { !$0.choices.isEmpty } ? .chooser(groups) : .notFound(groups))
        }
    }

    private func resolve(source: MangaSource, spellings: [String], candidate: MALDiscoveryCandidate,
                         detail: MyAnimeListMangaDetail?, limiter: MALHubSearchLimiter) async -> MALHubSourceGroup {
        var results: [Manga] = []; var exactFound = false
        do {
            for spelling in spellings {
                let found = try await timedSearch(source: source, title: spelling, limiter: limiter)
                let admitted = found.filter { registry.admitsForDiscovery($0) }
                results += admitted.filter { manga in !results.contains(where: { $0.id == manga.id }) }
                if admitted.contains(where: { $0.malId == candidate.malId }) { exactFound = true; break }
            }
        } catch is CancellationError { return .init(sourceId: source.id, sourceName: source.name, choices: [], ambiguous: false, status: .couldNotCheckTimedOut) } catch { return .init(sourceId: source.id, sourceName: source.name, choices: [], ambiguous: false, status: .couldNotCheckFailed) }
        if exactFound {
            let choices = results.filter { $0.malId == candidate.malId }.map { MALHubChoice(manga: $0, sourceName: source.name, kind: .exact) }
            return .init(sourceId: source.id, sourceName: source.name, choices: choices, ambiguous: false, status: .choices)
        }
        let titles = detail?.allTitles ?? spellings
        let scores = matcher.rankedScores(sourceTitles: titles, candidates: results.map { (id: $0.id, titles: [$0.title] + ($0.altTitles ?? [])) })
        guard let top = scores.first, top.score >= matcher.acceptanceThreshold else { return .init(sourceId: source.id, sourceName: source.name, choices: [], ambiguous: false, status: .noMatch) }
        let ambiguous = scores.count > 1 && top.score - scores[1].score < matcher.ambiguityMargin
        let selected = scores.filter { ambiguous ? top.score - $0.score < matcher.ambiguityMargin : $0.id == top.id }
        let choices = selected.compactMap { score in results.first(where: { $0.id == score.id }).map { MALHubChoice(manga: $0, sourceName: source.name, kind: .possible) } }
        return .init(sourceId: source.id, sourceName: source.name, choices: choices, ambiguous: ambiguous, status: .choices)
    }

    private func timedSearch(source: MangaSource, title: String, limiter: MALHubSearchLimiter) async throws -> [Manga] {
        await limiter.acquire(); defer { Task { await limiter.release() } }
        let work = Task { try await source.search(title: title, limit: 20, offset: 0) }
        let watchdog = Task { () -> Bool in
            var elapsed = 0.0
            while true {
                try Task.checkCancellation()
                let active = await challengeActive()
                try await Task.sleep(nanoseconds: UInt64(probeInterval * 1_000_000_000))
                if !active { elapsed += probeInterval }
                if elapsed >= deadline { return true }
            }
        }
        let result: Result<[Manga], Error> = await withTaskCancellationHandler(operation: {
            await withTaskGroup(of: Result<[Manga], Error>?.self) { group -> Result<[Manga], Error> in
                group.addTask {
                    do { return .success(try await work.value) } catch { return .failure(error) }
                }
                group.addTask { (try? await watchdog.value) == true ? .failure(CancellationError()) : nil }
                let result = await group.next()!!
                group.cancelAll(); watchdog.cancel()
                return result
            }
        }, onCancel: { work.cancel(); watchdog.cancel() })
        return try result.get()
    }
}

// swiftlint:enable line_length

private extension Manga {
    func with(contentRating: String?) -> Manga {
        Manga(id: id, sourceId: sourceId, title: title, description: description, status: status,
              year: year, coverURL: coverURL, malId: malId, altTitles: altTitles, contentRating: contentRating)
    }
}
