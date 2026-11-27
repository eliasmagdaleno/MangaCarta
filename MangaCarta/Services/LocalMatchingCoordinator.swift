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
        if let incumbent = works.workId(externalId: ids), incumbent != localID, !combine {
            let title = works.work(incumbent)?.displayTitle ?? "this title"
            return .combineRequired(incumbent: incumbent,
                                    warning: "This will combine with \(title) in your library. This can't be undone.")
        }
        guard works.canConfirmExternalIds(ids, on: localID, linking: remoteListing) else {
            return .failed("Couldn’t link that reading source. Try again.")
        }

        let survivorBeforeWrite = works.workId(externalId: ids) ?? localID
        let existingIDs = works.work(survivorBeforeWrite)?.externalIds
        let localExistingIDs = works.work(localID)?.externalIds
        let introducedMalID = localExistingIDs?.mal == nil && existingIDs?.mal == nil
            ? ids.mal : nil
        let introducedAniListID = localExistingIDs?.anilist == nil && existingIDs?.anilist == nil
            ? ids.anilist : nil
        let live = works.confirmExternalIds(ids, on: localID)
        var confirmedRemoteListing: ListingKey?
        if let listing = remoteListing {
            switch works.linkListing(listing, to: live) {
            case .added:
                confirmedRemoteListing = ListingKey(listing)
            case .alreadyLinked:
                break
            case .belongsToOtherWork, .workNotFound:
                preconditionFailure("preflighted local match Listing link became invalid")
            }
        }
        let record = LocalMatchRecord(localWorkID: live, originalLocalWorkID: localID,
                                      confirmedAt: date, status: .confirmed,
                                      malID: ids.mal, aniListID: ids.anilist,
                                      remoteListing: confirmedRemoteListing,
                                      introducedMalID: introducedMalID,
                                      introducedAniListID: introducedAniListID, evidence: evidence)
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
        guard record.status == .confirmed else { return nil }
        if let remote = record.remoteListing, remote.sourceId != LocalSource.sourceID,
           work.listings.contains(remote) {
            _ = works.removeListing(remote, from: live, keepingReadState: true)
        }
        works.removeExternalIds(ExternalIDs(mal: record.introducedMalID,
                                            anilist: record.introducedAniListID), from: live)
        matches.markUnmatched(workID: live, at: date)
        progress.unmatch(workID: record.originalLocalWorkID)
        return nil
    }
}
