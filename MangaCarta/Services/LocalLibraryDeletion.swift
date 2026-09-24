import Foundation

@MainActor
final class LocalLibraryDeletion {
    private let local: LocalLibraryStore
    private let library: LibraryStore
    private let works: WorkStore

    init(local: LocalLibraryStore, library: LibraryStore, works: WorkStore) {
        self.local = local
        self.library = library
        self.works = works
    }

    func delete(itemId: String) async throws {
        try await local.delete(itemId: itemId)
        if let item = library.item(for: itemId) {
            let manga = Manga(id: item.id, sourceId: item.sourceId ?? "local", title: item.title,
                              description: "", status: "completed", year: nil, coverURL: item.coverURL,
                              malId: nil, altTitles: nil, contentRating: nil)
            if library.contains(itemId) { library.toggle(manga) }
        }
        works.removeListing(ListingKey(sourceId: LocalSource.sourceID, mangaId: itemId))
    }
}
