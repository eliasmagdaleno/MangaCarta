import Foundation

enum MigrationSkipReason: Equatable { case belongsToOtherWork(WorkID), workNotFound }
enum MigrationOutcome: Equatable { case migrated, skipped(MigrationSkipReason) }

@MainActor
final class WorkSourcesCoordinator: ObservableObject {
    private let works: WorkStore
    private let preferences: SourcePreferenceStore
    private let fulfillment: FulfillmentCoordinator
    private let library: LibraryStore
    private let malChoices: MALSourceChoiceStore
    private let updates: UpdateStateStore

    init(works: WorkStore, preferences: SourcePreferenceStore, fulfillment: FulfillmentCoordinator,
         library: LibraryStore, malChoices: MALSourceChoiceStore, updates: UpdateStateStore) {
        self.works = works; self.preferences = preferences; self.fulfillment = fulfillment
        self.library = library; self.malChoices = malChoices; self.updates = updates
    }

    func ensureWork(for listing: Manga) -> WorkID {
        works.workId(for: ListingKey(listing)) ?? works.mint(from: listing)
    }

    @discardableResult
    func add(_ listing: Manga, to work: WorkID, recordExternalIds: Bool = true) async -> WorkStore.AddListingResult {
        let result = works.addListing(listing, to: work, recordExternalIds: recordExternalIds)
        if case .added = result { await fulfillment.reconcile(work) }
        return result
    }

    @discardableResult
    func remove(_ key: ListingKey, from work: WorkID, keepingReadState: Bool) async -> WorkStore.RemoveListingResult {
        let result = works.removeListing(key, from: work, keepingReadState: keepingReadState)
        guard case .removed = result else { return result }
        await cleanupAfterRemoval(key, from: work)
        return result
    }

    func migrate(_ work: WorkID, to target: Manga, from sourceId: String,
                 removingOld: Bool) async -> MigrationOutcome {
        guard let current = works.work(work) else { return .skipped(.workNotFound) }
        switch works.addListing(target, to: work, recordExternalIds: true) {
        case .belongsToOtherWork(let other): return .skipped(.belongsToOtherWork(other))
        case .workNotFound: return .skipped(.workNotFound)
        case .added, .alreadyLinked: break
        }
        let targetKey = ListingKey(target)
        if let pin = preferences.choice(for: work), pin.sourceId != sourceId, pin.sourceId != target.sourceId {
            // A deliberate pin on a third Source survives this batch operation.
        } else {
            preferences.choose(targetKey, for: work)
        }
        let listings = current.listings + [targetKey]
        let oldItemKey = listings.first(where: { $0.sourceId == sourceId && library.item(for: $0) != nil })
            ?? listings.first(where: { library.item(for: $0) != nil })
        if let oldItemKey { library.repointItem(from: oldItemKey, to: targetKey, coverURL: target.coverURL) }
        if removingOld {
            let oldKeys = works.work(work)?.listings.filter { $0.sourceId == sourceId } ?? []
            for key in oldKeys { _ = await remove(key, from: work, keepingReadState: true) }
        }
        return .migrated
    }

    @discardableResult
    func move(_ key: ListingKey, from other: WorkID, to work: WorkID) async -> WorkStore.RemoveListingResult {
        let result = works.moveCopy(key, from: other, to: work)
        guard case .removed = result else { return result }
        await cleanupAfterRemoval(key, from: other)
        await fulfillment.reconcile(other)
        await fulfillment.reconcile(work)
        return result
    }

    private func cleanupAfterRemoval(_ key: ListingKey, from work: WorkID) async {
        if preferences.choice(for: work) == key { preferences.clearChoice(for: work) }
        if let replacement = fulfillment.chosenListing(for: work) { library.repointItem(from: key, to: replacement) }
        if let value = works.work(work), let mal = value.externalIds.mal,
           let choice = await malChoices.choice(for: mal), ListingKey(choice.manga) == key {
            await malChoices.remove(malId: mal)
        }
        updates.dropListing(key, from: work)
    }

    func combine(_ other: WorkID, into work: WorkID) async {
        guard let survivor = works.work(work), let losing = works.work(other) else { return }
        for key in survivor.listings where losing.removedListings.contains(where: { $0.key == key }) {
            works.liftRemoval(key, on: other)
        }
        for key in losing.listings where survivor.removedListings.contains(where: { $0.key == key }) {
            works.liftRemoval(key, on: work)
        }
        guard works.merge(other, into: work) else { return }
        let merged = works.work(work)
        let survivorKey = merged?.listings.first(where: { library.item(for: $0) != nil })
        let otherKey = losing.listings.first(where: { library.item(for: $0) != nil })
        if let survivorKey, let otherKey {
            library.mergeItems(from: otherKey, into: survivorKey)
        } else if survivorKey == nil, let otherKey,
                  let replacement = fulfillment.chosenListing(for: work) {
            library.repointItem(from: otherKey, to: replacement)
        }
        await fulfillment.reconcile(work)
    }
}
