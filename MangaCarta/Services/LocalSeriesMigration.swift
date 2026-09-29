import Foundation

@MainActor
enum LocalSeriesMigration {
    static func schedule(directory: URL, library: LibraryStore, history: HistoryStore, works: WorkStore) {
        Task { @MainActor in
            await run(local: LocalLibraryStore(root: directory.appendingPathComponent("LocalLibrary")),
                      library: library, history: history, works: works)
        }
    }

    static func run(local: LocalLibraryStore, library: LibraryStore, history: HistoryStore,
                    works: WorkStore) async {
        for item in library.items where item.sourceId == LocalSource.sourceID {
            guard let record = await local.record(itemId: item.id),
                  let normalized = LocalSeriesIdentity.normalizedSeries(record.comicInfo?.series) else { continue }
            let seriesID = LocalSeriesIdentity.seriesID(for: normalized)
            guard seriesID != item.id else { continue }
            let aggregate = await local.seriesMetadata(for: seriesID) ?? record
            let chapters = await local.chapters(forMangaID: seriesID)
            let mapping = Dictionary(uniqueKeysWithValues: chapters.map {
                ("\($0.record.itemId)/\($0.chapter.number)", $0.number)
            })
            history.rewriteLocalListing(from: item.id, to: seriesID, chapterNumbers: mapping)
            works.moveListing(from: ListingKey(sourceId: LocalSource.sourceID, mangaId: item.id),
                              to: ListingKey(sourceId: LocalSource.sourceID, mangaId: seriesID))
            library.moveItem(from: item.id, to: seriesID,
                             title: aggregate.comicInfo?.series ?? aggregate.title,
                             coverURL: await local.coverURL(itemId: aggregate.itemId),
                             chapterNumbers: chapters.map(\.number))
        }
    }
}
