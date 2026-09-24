import Foundation

enum RefreshBudget {
    case foreground
    case background(deadline: Date, maxWorks: Int)
}

struct UpdateEvent: Equatable {
    let workId: WorkID
    let title: String
    let newChapterCount: Int
    let didExceedCap: Bool
    let isAdult: Bool
}

enum RefreshStep: Equatable {
    case advanced(WorkID, count: Int)
    case baselined(WorkID)
    case unchanged(WorkID)
    case failed(WorkID)
    case skipped(WorkID)
    case exhausted
}

@MainActor
final class LibraryRefreshCoordinator {
    private struct FetchResult {
        let listing: ListingKey
        let sourceIsAdult: Bool
        let result: Result<[Chapter], Error>
    }
    private typealias SuccessfulFetch = (listing: ListingKey, sourceIsAdult: Bool, chapters: [Chapter])

    private let works: WorkStore
    private let library: LibraryStore
    private let history: HistoryStore
    private let updates: UpdateStateStore
    private let registry: SourceRegistry
    private let now: () -> Date
    private let didProcessWork: (WorkID) -> Void

    private var pendingWorkIds: [WorkID] = []
    private var nextIndex = 0
    private var pendingEvent: UpdateEvent?
    private var foregroundTask: Task<Void, Never>?
    private var foregroundRunID: UUID?
    private(set) var latestChapterNumbers: [ListingKey: [String]] = [:]

    init(works: WorkStore,
         library: LibraryStore,
         history: HistoryStore,
         // Nil-defaulted because these dependencies are @MainActor while default
         // arguments are evaluated from a nonisolated context.
         updates: UpdateStateStore? = nil,
         registry: SourceRegistry? = nil,
         now: @escaping () -> Date = Date.init,
         didProcessWork: @escaping (WorkID) -> Void = { _ in }) {
        self.works = works
        self.library = library
        self.history = history
        self.updates = updates ?? UpdateStateStore(works: works)
        self.registry = registry ?? .shared
        self.now = now
        self.didProcessWork = didProcessWork
    }

    func run(budget: RefreshBudget) async -> [UpdateEvent] {
        updates.reconcileMerges(using: works)
        pendingWorkIds = makeQueue(now: now())
        nextIndex = 0
        latestChapterNumbers = [:]
        var events: [UpdateEvent] = []
        var processed = 0

        while nextIndex < pendingWorkIds.count {
            guard !Task.isCancelled, canContinue(budget, processed: processed) else { break }
            let result = await step()
            if let event = pendingEvent { events.append(event) }
            pendingEvent = nil
            if result == .exhausted { break }
            processed += 1
            // Checkpoint before the cancellation seam. Scene backgrounding can then flush
            // this completed progress without any later write from the cancelled task.
            persistCursor()
            didProcessWork(pendingWorkIds[nextIndex - 1])
        }

        if !Task.isCancelled { persistCursor() }
        return events
    }

    func step() async -> RefreshStep {
        if pendingWorkIds.isEmpty {
            pendingWorkIds = makeQueue(now: now())
            nextIndex = 0
        }
        guard pendingWorkIds.indices.contains(nextIndex) else { return .exhausted }
        let workId = pendingWorkIds[nextIndex]
        nextIndex += 1
        pendingEvent = nil

        guard let work = works.work(workId) else { return .skipped(workId) }
        let eligible = eligibleListings(for: work, workId: workId)
        guard !eligible.isEmpty else { return .skipped(workId) }

        let results = await fetch(eligible)
        // A scene transition flushes immediately after cancelling the foreground run.
        // Never mutate update state when an in-flight source request returns afterwards.
        guard !Task.isCancelled else { return .skipped(workId) }
        let successes = successfulFetches(in: results)
        recordFailures(in: results, workId: workId)
        guard !successes.isEmpty else { return .failed(workId) }

        let hadBaseline = updates.state(for: workId)?.hasBaseline == true
        let baselineNumbers = successes.flatMap { $0.chapters.map(\.number) }
        var released: Set<ChapterOrdinal> = []
        for (index, success) in successes.enumerated() {
            let numbers = index == 0 && !hadBaseline ? baselineNumbers : success.chapters.map(\.number)
            latestChapterNumbers[success.listing] = success.chapters.map(\.number)
            released.formUnion(updates.absorb(workId: workId, listing: success.listing,
                                              rawNumbers: numbers, now: now()))
        }

        guard hadBaseline else { return .baselined(workId) }
        guard !released.isEmpty else { return .unchanged(workId) }

        // The frontier absorbs every ordinal. This cap only bounds the user-visible
        // consequence of a source renumbering a long run at once (ADR-0021 §Decisions.1).
        let exceedsCap = released.count > UpdateTuning.maxNotifiedChaptersPerWork
        let count = min(released.count, UpdateTuning.maxNotifiedChaptersPerWork)
        pendingEvent = UpdateEvent(workId: workId,
                                   title: work.displayTitle,
                                   newChapterCount: count,
                                   didExceedCap: exceedsCap,
                                   isAdult: successes.contains { $0.sourceIsAdult })
        return .advanced(workId, count: count)
    }

    func refreshLibrary() async {
        _ = await run(budget: .foreground)
        library.applyRefreshedChapterNumbers(latestChapterNumbers)
    }

    func startForeground(notify: @escaping ([UpdateEvent]) async -> Void) {
        guard foregroundTask == nil else { return }
        let runID = UUID()
        foregroundRunID = runID
        foregroundTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let events = await run(budget: .foreground)
            guard !Task.isCancelled else {
                if foregroundRunID == runID { foregroundTask = nil }
                return
            }
            if !events.isEmpty { await notify(events) }
            if foregroundRunID == runID { foregroundTask = nil }
        }
    }

    func stopForeground() {
        foregroundTask?.cancel()
        foregroundTask = nil
        foregroundRunID = nil
    }

    private func fetch(_ listings: [ListingKey]) async -> [FetchResult] {
        let requests = listings.compactMap { listing -> (ListingKey, MangaSource)? in
            guard let source = registry.sourceForRefresh(sourceId: listing.sourceId) else { return nil }
            return (listing, source)
        }
        return await withTaskGroup(of: FetchResult.self) { group in
            var iterator = requests.makeIterator()

            func addNext() {
                guard let (listing, source) = iterator.next() else { return }
                group.addTask {
                    do {
                        return FetchResult(listing: listing, sourceIsAdult: source.isNSFW,
                                           result: .success(try await source.chapters(mangaId: listing.mangaId)))
                    } catch {
                        return FetchResult(listing: listing, sourceIsAdult: source.isNSFW,
                                           result: .failure(error))
                    }
                }
            }

            for _ in 0..<4 { addNext() }
            var output: [FetchResult] = []
            while let result = await group.next() {
                output.append(result)
                addNext()
            }
            return output
        }
    }

    private func eligibleListings(for work: Work, workId: WorkID) -> [ListingKey] {
        work.listings.filter { listing in
            guard registry.source(id: listing.sourceId)?.participatesInUpdates ?? true else { return false }
            guard let blocked = updates.state(for: workId)?.listings[listing]?.blockedUntil else { return true }
            return blocked <= now()
        }
    }

    private func successfulFetches(in results: [FetchResult]) -> [SuccessfulFetch] {
        results.compactMap { result in
            guard case .success(let chapters) = result.result else { return nil }
            return (result.listing, result.sourceIsAdult, chapters)
        }
    }

    private func recordFailures(in results: [FetchResult], workId: WorkID) {
        for result in results where result.result.isFailure {
            updates.recordFailure(workId: workId, listing: result.listing, now: now())
        }
    }

    private func makeQueue(now: Date) -> [WorkID] {
        let all = works.allWorkIds().sorted { $0.raw.uuidString < $1.raw.uuidString }
        let stale = all.filter { workId in
            guard works.work(workId)?.snapshot?.publicationStatus != .finished else { return false }
            guard let checked = updates.state(for: workId)?.lastSuccessfulCheck else { return true }
            return now.timeIntervalSince(checked) >= UpdateTuning.freshWindow
        }.sorted { lhs, rhs in
            let left = updates.state(for: lhs)?.lastSuccessfulCheck ?? .distantPast
            let right = updates.state(for: rhs)?.lastSuccessfulCheck ?? .distantPast
            return left == right ? lhs.raw.uuidString < rhs.raw.uuidString : left < right
        }
        let engaged = all.filter { workId in
            guard let work = works.work(workId) else { return false }
            return work.listings.contains { listing in
                library.items.contains { $0.id == listing.mangaId && ($0.sourceId ?? LegacySourceID.unattributed) == listing.sourceId }
                    || history.latestEntry(forManga: listing.mangaId).map {
                        now.timeIntervalSince($0.updatedAt) <= UpdateTuning.recentEngagementWindow
                    } == true
            }
        }
        let prioritized = deduplicated(stale + engaged)
        let remainder = all.filter { !prioritized.contains($0) }
        return prioritized + rotated(remainder, after: updates.refreshCursor)
    }

    private func rotated(_ ids: [WorkID], after cursor: WorkID?) -> [WorkID] {
        guard let cursor, let index = ids.firstIndex(of: cursor), !ids.isEmpty else { return ids }
        let start = ids.index(after: index)
        return Array(ids[start...] + ids[..<start])
    }

    private func deduplicated(_ ids: [WorkID]) -> [WorkID] {
        var seen: Set<WorkID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private func canContinue(_ budget: RefreshBudget, processed: Int) -> Bool {
        switch budget {
        case .foreground:
            return true
        case .background(let deadline, let maxWorks):
            return processed < maxWorks
                && deadline.timeIntervalSince(now()) > UpdateTuning.deadlineSafetyMargin
        }
    }

    private func persistCursor() {
        guard !pendingWorkIds.isEmpty else { return }
        let lastProcessed = max(0, min(nextIndex - 1, pendingWorkIds.count - 1))
        updates.setRefreshCursor(pendingWorkIds[lastProcessed])
        updates.flush()
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
