import Foundation

enum AnalyticsEligibility {
    static func admits(manga: Manga, source: MangaSource?, work: Work?, vocabulary: TagVocabulary?) -> Bool {
        guard let source else { return false }
        guard AdultContentFilter.admits(
            rating: manga.contentRating,
            sourceDeclaresAdultTitles: source.declaresAdultTitles,
            showAdultContent: false
        ), !source.isNSFW else { return false }
        guard manga.sourceId != LocalSource.sourceID else { return false }
        if let work, work.listings.contains(where: { $0.sourceId == LocalSource.sourceID }) ||
            work.removedListings.contains(where: { $0.key.sourceId == LocalSource.sourceID }) { return false }
        if let snapshot = work?.snapshot {
            let names = snapshot.genres.map(\.name) + snapshot.tags.map(\.name)
            guard vocabulary != nil || names.isEmpty else { return false }
            if names.contains(where: { name in
                name.caseInsensitiveCompare("Hentai") == .orderedSame ||
                name.caseInsensitiveCompare("Erotica") == .orderedSame ||
                vocabulary?.isAdult(name) == true
            }) { return false }
        }
        return true
    }

    static func catalogueIDs(work: Work?, manga: Manga) -> CatalogueIDs? {
        let ids = CatalogueIDs(mal: work?.externalIds.mal ?? manga.malId, anilist: work?.externalIds.anilist)
        return ids.isEmpty ? nil : ids
    }
}
