import Foundation

@MainActor
final class SourceTitleSearch {
    struct SourceOutcome {
        let sourceId: String
        let sourceName: String
        let result: Result
    }

    enum Result {
        case found([Manga])
        case timedOut
        case failed
    }

    private enum SearchError: Error { case timedOut }

    private actor Limiter {
        let limit: Int
        var active = 0
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(_ limit: Int) { self.limit = limit }

        func acquire() async {
            if active < limit { active += 1 } else {
                await withCheckedContinuation { waiters.append($0) }
            }
        }

        func release() {
            if let next = waiters.first { waiters.removeFirst(); next.resume() } else {
                active -= 1
            }
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var continuation: CheckedContinuation<[Manga], Error>?
        private var pending: Swift.Result<[Manga], Error>?

        func install(_ continuation: CheckedContinuation<[Manga], Error>) {
            lock.lock(); self.continuation = continuation
            let pending = self.pending; self.pending = nil; lock.unlock()
            if let pending { resume(with: pending) }
        }

        func resume(with result: Swift.Result<[Manga], Error>) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            guard let continuation else { pending = result; lock.unlock(); return }
            resumed = true; self.continuation = nil; lock.unlock()
            continuation.resume(with: result)
        }
    }

    private final class WatchdogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Error>?
        private var cancelled = false

        func set(_ task: Task<Void, Error>) {
            lock.lock(); self.task = task
            if cancelled { task.cancel() }
            lock.unlock()
        }

        func cancel() {
            lock.lock(); cancelled = true; task?.cancel(); lock.unlock()
        }
    }

    private let registry: SourceRegistry
    private let showAdultContent: Bool
    private let challengeActive: @Sendable () async -> Bool
    private let deadline: TimeInterval
    private let probeInterval: TimeInterval
    private let concurrency: Int

    init(registry: SourceRegistry, showAdultContent: Bool,
         challengeActive: @escaping @Sendable () async -> Bool = MALHubChallenge.isActive,
         deadline: TimeInterval = 8, probeInterval: TimeInterval = 0.25, concurrency: Int = 4) {
        self.registry = registry
        self.showAdultContent = showAdultContent
        self.challengeActive = challengeActive
        self.deadline = deadline
        self.probeInterval = probeInterval
        self.concurrency = concurrency
    }

    func search(spellings: [String], sourceIDs: Set<String>? = nil, excluding: Set<String> = [],
                stopWhen: @escaping ([Manga]) -> Bool = { _ in false }) async -> [SourceOutcome] {
        let sources = registry.visibleSources(includeAdult: showAdultContent).filter {
            $0.id != LocalSource.sourceID && !excluding.contains($0.id)
                && (sourceIDs == nil || sourceIDs!.contains($0.id))
        }
        let normalized = normalizedSpellings(spellings)
        guard !sources.isEmpty else { return [] }
        let limiter = Limiter(max(1, concurrency))
        return await withTaskGroup(of: SourceOutcome.self, returning: [SourceOutcome].self) { group in
            for source in sources {
                group.addTask {
                    await self.search(source: source, spellings: normalized, limiter: limiter,
                                      stopWhen: stopWhen)
                }
            }
            var outcomes: [SourceOutcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { lhs, rhs in
                sources.firstIndex(where: { $0.id == lhs.sourceId })! <
                    sources.firstIndex(where: { $0.id == rhs.sourceId })!
            }
        }
    }

    static func replacing(sourceId: String, in outcomes: [SourceOutcome], with replacement: SourceOutcome)
        -> [SourceOutcome] {
        outcomes.map { $0.sourceId == sourceId ? replacement : $0 }
    }

    private func normalizedSpellings(_ spellings: [String]) -> [String] {
        var seen = Set<String>()
        return spellings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(MALTitleMatcher.normalize($0)).inserted }
    }

    private func search(source: MangaSource, spellings: [String], limiter: Limiter,
                        stopWhen: @escaping ([Manga]) -> Bool) async -> SourceOutcome {
        var results: [Manga] = []
        do {
            for spelling in spellings {
                let found = try await timedSearch(source: source, title: spelling, limiter: limiter)
                for manga in found where registry.admitsForDiscovery(manga)
                    && !results.contains(where: { $0.id == manga.id }) {
                    results.append(manga)
                }
                if stopWhen(results) { break }
            }
            return SourceOutcome(sourceId: source.id, sourceName: source.name, result: .found(results))
        } catch is SearchError {
            return SourceOutcome(sourceId: source.id, sourceName: source.name, result: .timedOut)
        } catch {
            return SourceOutcome(sourceId: source.id, sourceName: source.name, result: .failed)
        }
    }

    private func timedSearch(source: MangaSource, title: String, limiter: Limiter) async throws -> [Manga] {
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        let completion = Completion()
        let watchdogBox = WatchdogBox()
        let work = Task {
            do {
                let value = try await source.search(title: title, limit: 20, offset: 0)
                completion.resume(with: .success(value)); watchdogBox.cancel()
            } catch {
                completion.resume(with: .failure(error)); watchdogBox.cancel()
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
                    work.cancel(); completion.resume(with: .failure(SearchError.timedOut)); return
                }
            }
        }
        watchdogBox.set(watchdog)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Manga], Error>) in
                completion.install(continuation)
            }
        }, onCancel: {
            work.cancel(); watchdog.cancel(); completion.resume(with: .failure(CancellationError()))
        })
    }
}
