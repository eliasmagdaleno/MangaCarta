import Foundation

/// Where one Work's chapters are fetched from: the Listing fulfillment chose, as a `Manga`
/// the reader and History can be handed as-is, and the Source serving it.
struct UpdatesChapterTarget {
    let manga: Manga
    let source: MangaSource
}

/// What the Updates screen knows about one Work's current chapters.
enum UpdatesChapterResolution {
    /// Requested and waiting — for a slot, or for the Source.
    case loading
    case loaded(manga: Manga, chapters: [Chapter])
    /// The Source answered with an error. Unknown, not "no chapters": the rows stay.
    case failed(manga: Manga, message: String)
    /// No registered Source can serve any of the Work's Listings (uninstalled, disabled).
    case sourceUnavailable
}

/// The Updates screen's chapter-metadata loader (spec 2026-11-09, owner decision 4).
///
/// **Lazy and capped.** Nothing is fetched until the screen asks for a Work — which it does
/// only when that Work's group is expanded and on screen, and only for Works in the timeline
/// (so only Works with newly discovered chapters). At most `maxConcurrentRequests` chapter
/// requests run at once; the rest wait in arrival order.
///
/// **Read-only.** It calls `MangaSource.chapters` and keeps the answer in memory for this
/// screen. It never touches `UpdateStateStore`: mapping ordinals to chapters is display, and
/// a second path that wrote the frontier would be a second baseline (ADR-0021).
@MainActor
final class UpdatesChapterLoader: ObservableObject {
    nonisolated static let maxConcurrentRequests = 4

    @Published private(set) var resolutions: [WorkID: UpdatesChapterResolution] = [:]

    /// How many chapter requests are running right now. Exposed for tests of the cap.
    private(set) var inFlight = 0

    private let maxConcurrent: Int
    private let resolve: (WorkID, Manga) -> UpdatesChapterTarget?
    private var queue: [(WorkID, UpdatesChapterTarget)] = []
    /// Works whose answer predates the last refresh; the next `request` fetches them again.
    private var stale: Set<WorkID> = []
    /// The ticket of each Work's latest started request. An answer whose ticket is no longer
    /// current (a `retry` started a newer one) is dropped rather than overwriting it.
    private var generation: [WorkID: Int] = [:]
    /// Works whose request was already running when a refresh invalidated them. Their answer
    /// predates the refresh, so `finish` applies it and then fetches once more.
    private var refetchWhenDone: Set<WorkID> = []

    /// - Parameter resolve: picks the Listing and Source for a Work, or `nil` when none is
    ///   registered. Production passes `live(registry:fulfillment:)`; tests pass a stub.
    init(maxConcurrent: Int = UpdatesChapterLoader.maxConcurrentRequests,
         resolve: @escaping (WorkID, Manga) -> UpdatesChapterTarget?) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.resolve = resolve
    }

    /// The same Listing the detail page would open: the per-Work pin, else the ranking
    /// (ADR-0004). Falls back to the summary's own Listing when fulfillment has no
    /// candidate, which then resolves to unavailable if its Source is gone too.
    static func live(registry: SourceRegistry,
                     fulfillment: FulfillmentCoordinator) -> (WorkID, Manga) -> UpdatesChapterTarget? {
        { workId, display in
            let own = ListingKey(display)
            let listing = fulfillment.chosenListing(for: workId) ?? own
            guard let source = registry.source(id: listing.sourceId) else { return nil }
            return UpdatesChapterTarget(manga: listing == own ? display : display.relisted(as: listing),
                                        source: source)
        }
    }

    /// Asks for a Work's chapters. A Work already loading, loaded or failed is left alone
    /// (use `retry` for a failure), unless a refresh has since made its answer stale.
    func request(_ workId: WorkID, displayManga: Manga) {
        if let existing = resolutions[workId] {
            guard stale.contains(workId) else { return }
            if case .loading = existing { return }
        }
        stale.remove(workId)
        guard let target = resolve(workId, displayManga) else {
            resolutions[workId] = .sourceUnavailable
            return
        }
        // A stale answer keeps showing while its replacement loads: a refresh must not
        // blank rows the reader is looking at.
        switch resolutions[workId] {
        case .loaded?: break
        default: resolutions[workId] = .loading
        }
        queue.append((workId, target))
        pump()
    }

    func retry(_ workId: WorkID, displayManga: Manga) {
        if case .loading? = resolutions[workId] { return }
        resolutions[workId] = nil
        stale.remove(workId)
        request(workId, displayManga: displayManga)
    }

    /// After a refresh: every answer becomes stale, and Works no longer in the timeline are
    /// forgotten. The screen re-requests the Works it is still showing.
    func invalidate(keeping workIds: Set<WorkID>) {
        resolutions = resolutions.filter { workIds.contains($0.key) }
        queue.removeAll { !workIds.contains($0.0) }
        let queued = Set(queue.map(\.0))
        for workId in resolutions.keys {
            if case .loading = resolutions[workId] {
                // Still queued: it will start after the refresh, so its answer is current.
                // Already running: its answer is from before the refresh — fetch again after.
                if !queued.contains(workId) { refetchWhenDone.insert(workId) }
                continue
            }
            stale.insert(workId)
        }
        stale.formIntersection(workIds)
        refetchWhenDone.formIntersection(workIds)
    }

    private func pump() {
        while inFlight < maxConcurrent, !queue.isEmpty {
            let (workId, target) = queue.removeFirst()
            inFlight += 1
            let ticket = (generation[workId] ?? 0) + 1
            generation[workId] = ticket
            let source = target.source
            let mangaId = target.manga.id
            Task { [weak self] in
                let outcome: Result<[Chapter], Error>
                do {
                    outcome = .success(try await source.chapters(mangaId: mangaId))
                } catch {
                    outcome = .failure(error)
                }
                self?.finish(workId, target: target, ticket: ticket, outcome: outcome)
            }
        }
    }

    private func finish(_ workId: WorkID, target: UpdatesChapterTarget, ticket: Int,
                        outcome: Result<[Chapter], Error>) {
        inFlight -= 1
        defer { pump() }
        // Forgotten by a refresh, or superseded by a newer request for the same Work.
        guard generation[workId] == ticket, resolutions[workId] != nil else { return }
        switch outcome {
        case .success(let chapters):
            resolutions[workId] = .loaded(manga: target.manga, chapters: chapters)
        case .failure(let error):
            resolutions[workId] = .failed(manga: target.manga, message: error.localizedDescription)
        }
        // The answer is shown meanwhile, as a stale answer is during any refetch.
        if refetchWhenDone.remove(workId) != nil {
            queue.append((workId, target))
        }
    }
}

/// One newly discovered chapter as the screen draws it.
enum UpdatesChapterRow: Identifiable {
    /// Waiting on metadata: the ordinal is known, the chapter is not yet.
    case pending(ChapterOrdinal)
    case chapter(ChapterOrdinal, Chapter)
    /// Metadata loaded, but no current chapter carries this ordinal. Kept visible, with the
    /// chapter list as the way forward — a discovery is never dropped for want of metadata.
    case unmatched(ChapterOrdinal)

    var ordinal: ChapterOrdinal {
        switch self {
        case .pending(let ordinal), .chapter(let ordinal, _), .unmatched(let ordinal): return ordinal
        }
    }

    var id: ChapterOrdinal { ordinal }

    /// Maps the Work's discovered ordinals (already newest first) onto fetched chapters.
    /// `chapters == nil` means nothing has loaded. Order is the ordinals', never the
    /// Source's: view order is not discovery order. When several chapters share an ordinal
    /// (one per scanlation group), the Source's first is used.
    static func rows(ordinals: [ChapterOrdinal], chapters: [Chapter]?) -> [UpdatesChapterRow] {
        guard let chapters else { return ordinals.map(UpdatesChapterRow.pending) }
        var byOrdinal: [ChapterOrdinal: Chapter] = [:]
        for chapter in chapters {
            guard let ordinal = ChapterOrdinal.parse(chapter.number), byOrdinal[ordinal] == nil else { continue }
            byOrdinal[ordinal] = chapter
        }
        return ordinals.map { ordinal in
            byOrdinal[ordinal].map { .chapter(ordinal, $0) } ?? .unmatched(ordinal)
        }
    }
}

extension UpdatesTimeline {
    /// The screen's "Mark all seen": exactly the Works this timeline shows, which is what
    /// keeps it to Works still in the Library. Seen is not read — this reaches
    /// `UpdateStateStore` alone, never History.
    @MainActor
    func markAllSeen(in updates: UpdateStateStore) {
        updates.clearNewlyDiscovered(workIds: workIds)
    }
}
