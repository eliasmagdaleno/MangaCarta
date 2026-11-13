import Foundation

@MainActor
final class NotificationActionHandler {
    enum Outcome: Equatable {
        case markedRead
        case muted
        case noOp
    }

    private let works: WorkStore
    private let history: HistoryStore
    private let updates: UpdateStateStore
    private let library: LibraryStore
    private let fulfillment: FulfillmentCoordinator
    private let registry: SourceRegistry
    private let notifications: NotificationScheduling

    init(works: WorkStore, history: HistoryStore, updates: UpdateStateStore,
         library: LibraryStore, fulfillment: FulfillmentCoordinator,
         registry: SourceRegistry, notifications: NotificationScheduling) {
        self.works = works
        self.history = history
        self.updates = updates
        self.library = library
        self.fulfillment = fulfillment
        self.registry = registry
        self.notifications = notifications
    }

    func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completion(); return }
            _ = await self.perform(actionIdentifier: actionIdentifier, userInfo: userInfo)
            completion()
        }
    }

    func perform(actionIdentifier: String, userInfo: [AnyHashable: Any]) async -> Outcome {
        guard let raw = userInfo[UpdateNotifier.workIdUserInfoKey] as? String,
              let uuid = UUID(uuidString: raw),
              let work = works.work(WorkID(raw: uuid)) else { return .noOp }
        let resolved = work.id
        guard work.listings.contains(where: { library.item(for: $0) != nil }) else { return .noOp }

        if actionIdentifier == UpdateNotifier.muteActionIdentifier {
            updates.setMuted(true, workId: resolved)
            notifications.removePending(withIdentifiers: [UpdateStateStore.notificationIdentifier(for: resolved)])
            updates.flush()
            return .muted
        }
        guard actionIdentifier == UpdateNotifier.markReadActionIdentifier else { return .noOp }

        guard let captured = capturedOrdinals(from: userInfo, workId: resolved) else { return .noOp }
        return await markRead(captured, work: work, workId: resolved)
    }

    private func capturedOrdinals(from userInfo: [AnyHashable: Any], workId: WorkID) -> Set<ChapterOrdinal>? {
        if let rawOrdinals = userInfo[UpdateNotifier.discoveredOrdinalsUserInfoKey] {
            guard let values = rawOrdinals as? [String], !values.isEmpty,
                  !values.contains(where: { ChapterOrdinal.parse($0) == nil }) else { return nil }
            return Set(values.compactMap(ChapterOrdinal.parse))
        }
        guard let current = updates.state(for: workId)?.newlyDiscovered, !current.isEmpty else { return nil }
        return current
    }

    private func markRead(_ captured: Set<ChapterOrdinal>, work: Work, workId: WorkID) async -> Outcome {
        guard let listing = fulfillment.chosenListing(for: workId),
              let source = registry.source(id: listing.sourceId), !Task.isCancelled else { return .noOp }
        do {
            let chapters = try await source.chapters(mangaId: listing.mangaId)
            guard !Task.isCancelled else { return .noOp }
            let matched = chapters.filter { chapter in
                guard let ordinal = ChapterOrdinal.parse(chapter.number) else { return false }
                return captured.contains(ordinal)
            }
            guard Set(matched.compactMap { ChapterOrdinal.parse($0.number) }) == captured else { return .noOp }
            let item = library.item(for: listing)
            let title = item?.title ?? work.displayTitle
            let manga = Manga(id: listing.mangaId, sourceId: listing.sourceId, title: title,
                              description: "", status: "unknown", year: nil,
                              coverURL: item?.coverURL, malId: nil, altTitles: nil, contentRating: nil)
            history.markRead(manga: manga, chapters: matched)
            updates.clearNewlyDiscovered(captured, workId: resolved)
            history.flush()
            updates.flush()
            return .markedRead
        } catch is CancellationError {
            return .noOp
        } catch {
            return .noOp
        }
    }
}
