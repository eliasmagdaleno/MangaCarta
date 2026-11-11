import Foundation

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

private enum MALHubSearchError: Error { case timedOut }

private actor MALHubSearchLimiter {
    let limit: Int
    var active = 0
    var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active -= 1
        }
    }
}

private final class MALHubSearchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<[Manga], Error>?
    private var pending: Result<[Manga], Error>?

    func install(_ continuation: CheckedContinuation<[Manga], Error>) {
        lock.lock()
        self.continuation = continuation
        let pending = self.pending
        self.pending = nil
        lock.unlock()
        if let pending { resume(with: pending) }
    }

    func resume(with result: Result<[Manga], Error>) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pending = result
            lock.unlock()
            return
        }
        resumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class MALHubWatchdogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Task<Void, Error>?
    private var cancelled = false

    func set(_ task: Task<Void, Error>) {
        lock.lock()
        value = task
        if cancelled { task.cancel() }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        value?.cancel()
        lock.unlock()
    }
}

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

    init(registry: SourceRegistry, store: MALSourceChoiceStore, showAdultContent: Bool,
         matcher: MALTitleMatcher = .init(),
         challengeActive: @escaping @Sendable () async -> Bool = {
             await MainActor.run { WebViewService.shared.isChallengeActive }
         },
         deadline: TimeInterval = 8, probeInterval: TimeInterval = 0.25,
         alternativeTitles: @escaping @Sendable (Int) async throws -> [String] = {
             try await MyAnimeListAPI.alternativeTitles(id: $0)
         }) {
        self.registry = registry
        self.store = store
        self.showAdultContent = showAdultContent
        self.matcher = matcher
        self.challengeActive = challengeActive
        self.deadline = deadline
        self.probeInterval = probeInterval
        self.alternativeTitles = alternativeTitles
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
            } else {
                await store.remove(malId: candidate.malId)
            }
        }
        return await search(candidate: candidate, detail: detail, sourceIDs: sourceIDs)
    }

    private func search(candidate: MALDiscoveryCandidate, detail: MyAnimeListMangaDetail?,
                        sourceIDs: Set<String>?) async -> MALHubResolution {
        let sources = registry.visibleSources(includeAdult: showAdultContent).filter { source in
            source.id != LocalSource.sourceID &&
                (sourceIDs == nil || sourceIDs!.contains(source.id))
        }
        guard !sources.isEmpty else { return .notFound([]) }
        var spellings = [detail?.title ?? candidate.title]
        let alternates = detail?.allTitles.dropFirst() ?? []
        if !alternates.isEmpty {
            spellings += Array(alternates.prefix(2))
        } else if let fetched = try? await alternativeTitles(candidate.malId) {
            spellings += Array(fetched.dropFirst().prefix(2))
        }
        spellings = spellings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        spellings = spellings.filter { seen.insert(MALTitleMatcher.normalize($0)).inserted }
        let limiter = MALHubSearchLimiter(4)
        return await withTaskGroup(of: MALHubSourceGroup.self, returning: MALHubResolution.self) { group in
            for source in sources {
                group.addTask {
                    await self.resolve(source: source, spellings: spellings, candidate: candidate,
                                       detail: detail, limiter: limiter)
                }
            }
            var groups: [MALHubSourceGroup] = []
            for await result in group { groups.append(result) }
            groups.sort { lhs, rhs in
                sources.firstIndex(where: { $0.id == lhs.sourceId })!
                    < sources.firstIndex(where: { $0.id == rhs.sourceId })!
            }
            let exact = groups.flatMap(\.choices).filter { $0.kind == .exact }
            if exact.count == 1 { return .open(exact[0].manga) }
            return groups.contains { !$0.choices.isEmpty } ? .chooser(groups) : .notFound(groups)
        }
    }

    private func resolve(source: MangaSource, spellings: [String], candidate: MALDiscoveryCandidate,
                         detail: MyAnimeListMangaDetail?, limiter: MALHubSearchLimiter) async -> MALHubSourceGroup {
        var results: [Manga] = []
        var exactFound = false
        do {
            for spelling in spellings {
                let found = try await timedSearch(source: source, title: spelling, limiter: limiter)
                let admitted = found.filter { registry.admitsForDiscovery($0) }
                results += admitted.filter { manga in !results.contains { $0.id == manga.id } }
                if admitted.contains(where: { $0.malId == candidate.malId }) {
                    exactFound = true
                    break
                }
            }
        } catch MALHubSearchError.timedOut {
            return group(source, status: .couldNotCheckTimedOut)
        } catch is CancellationError {
            return group(source, status: .couldNotCheckFailed)
        } catch {
            return group(source, status: .couldNotCheckFailed)
        }
        if exactFound {
            let choices = results.filter { $0.malId == candidate.malId }.map {
                MALHubChoice(manga: $0, sourceName: source.name, kind: .exact)
            }
            return group(source, choices: choices)
        }
        let titles = detail?.allTitles ?? spellings
        let candidates = results.map { (id: $0.id, titles: [$0.title] + ($0.altTitles ?? [])) }
        let scores = matcher.rankedScores(sourceTitles: titles, candidates: candidates)
        guard let top = scores.first, top.score >= matcher.acceptanceThreshold else {
            return group(source, status: .noMatch)
        }
        let ambiguous = scores.count > 1 && top.score - scores[1].score < matcher.ambiguityMargin
        let selected = scores.filter {
            ambiguous ? top.score - $0.score < matcher.ambiguityMargin : $0.id == top.id
        }
        let choices = selected.compactMap { score in
            results.first(where: { $0.id == score.id }).map {
                MALHubChoice(manga: $0, sourceName: source.name, kind: .possible)
            }
        }
        return group(source, choices: choices, ambiguous: ambiguous)
    }

    private func group(_ source: MangaSource, choices: [MALHubChoice] = [], ambiguous: Bool = false,
                       status: MALHubSourceGroup.Status = .choices) -> MALHubSourceGroup {
        MALHubSourceGroup(sourceId: source.id, sourceName: source.name, choices: choices,
                          ambiguous: ambiguous, status: status)
    }

    private func timedSearch(source: MangaSource, title: String,
                             limiter: MALHubSearchLimiter) async throws -> [Manga] {
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        let completion = MALHubSearchCompletion()
        let watchdogBox = MALHubWatchdogBox()
        let work = Task {
            do {
                let value = try await source.search(title: title, limit: 20, offset: 0)
                completion.resume(with: .success(value))
                watchdogBox.cancel()
            } catch {
                completion.resume(with: .failure(error))
                watchdogBox.cancel()
            }
        }
        let watchdog = Task {
            var elapsed = 0.0
            while true {
                try Task.checkCancellation()
                let active = await challengeActive()
                try await Task.sleep(nanoseconds: UInt64(probeInterval * 1_000_000_000))
                if !active { elapsed += probeInterval }
                if elapsed >= deadline {
                    work.cancel()
                    completion.resume(with: .failure(MALHubSearchError.timedOut))
                    return
                }
            }
        }
        watchdogBox.set(watchdog)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Manga], Error>) in
                completion.install(continuation)
            }
        }, onCancel: {
            work.cancel()
            watchdog.cancel()
            completion.resume(with: .failure(CancellationError()))
        })
    }
}

private extension Manga {
    func with(contentRating: String?) -> Manga {
        Manga(id: id, sourceId: sourceId, title: title, description: description, status: status,
              year: year, coverURL: coverURL, malId: malId, altTitles: altTitles,
              contentRating: contentRating)
    }
}
