import Foundation

@MainActor
final class LocalMatchingCoordinator {
    enum Confirmation: Equatable {
        case confirmed(WorkID)
        case combineRequired(incumbent: WorkID, warning: String)
        case failed(String)
    }

    private let works: WorkStore
    private let matches: LocalMatchStore
    private let progress: MALProgressCoordinator
    private let sourceAvailable: (String) -> Bool
    private let metadataChanged: (WorkID) -> Void

    init(works: WorkStore, matches: LocalMatchStore, progress: MALProgressCoordinator,
         sourceAvailable: @escaping (String) -> Bool = { _ in true },
         metadataChanged: @escaping (WorkID) -> Void) {
        self.works = works
        self.matches = matches
        self.progress = progress
        self.sourceAvailable = sourceAvailable
        self.metadataChanged = metadataChanged
    }

    func confirm(localWorkID: WorkID, ids: ExternalIDs, remoteListing: Manga? = nil,
                 evidence: [LocalMatchEvidence] = [], combine: Bool = false,
                 at date: Date = Date()) -> Confirmation {
        guard let localID = works.canonicalWorkID(localWorkID) else {
            return .failed("Couldn’t save this match. Try again.")
        }
        if let listing = remoteListing, !sourceAvailable(listing.sourceId) {
            return .failed("That reading source is unavailable. Try again later.")
        }
        let incumbentForIDs = works.workId(externalId: ids)
        if let listing = remoteListing, let owner = works.workId(for: ListingKey(listing)),
           owner != localID && !(combine && owner == incumbentForIDs) {
            return .failed("That listing is already linked to another title.")
        }
        if let incumbent = works.workId(externalId: ids), incumbent != localID, !combine {
            let title = works.work(incumbent)?.displayTitle ?? "this title"
            return .combineRequired(incumbent: incumbent,
                                    warning: "This will combine with \(title) in your library. This can't be undone.")
        }

        guard let survivor = works.confirmExternalIds(ids, on: localID),
              let live = works.canonicalWorkID(survivor) else {
            return .failed("Couldn’t save this match. Try again.")
        }
        if let listing = remoteListing {
            switch works.linkListing(listing, to: live) {
            case .added, .alreadyLinked: break
            default: return .failed("Couldn’t link that reading source. Try again.")
            }
        }
        let record = LocalMatchRecord(localWorkID: live, confirmedAt: date, status: .confirmed,
                                      malID: ids.mal, aniListID: ids.anilist,
                                      remoteListing: remoteListing.map(ListingKey.init), evidence: evidence)
        matches.save(record)
        metadataChanged(live)
        progress.workMetadataChanged(live)
        return .confirmed(live)
    }

    func unmatch(workID: WorkID, at date: Date = Date()) -> String? {
        guard let live = works.canonicalWorkID(workID), let work = works.work(live) else {
            return "Couldn’t unmatch this title. Try again."
        }
        guard let record = matches.record(for: workID) ?? matches.record(for: live) else { return nil }
        if let remote = record.remoteListing, remote.sourceId != LocalSource.sourceID,
           work.listings.contains(remote) {
            works.removeListing(remote)
        }
        works.removeExternalIds(ExternalIDs(mal: record.malID, anilist: record.aniListID), from: live)
        matches.markUnmatched(workID: live, at: date)
        progress.unmatch(workID: live)
        return nil
    }
}
