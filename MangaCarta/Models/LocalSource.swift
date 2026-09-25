import Foundation

struct LocalSource: MangaSource {
    static let sourceID = "local"
    let id = sourceID
    let name = "Local"
    let store: LocalLibraryStore
    var isBrowsable: Bool { false }
    var participatesInUpdates: Bool { false }
    var publishesExternalIds: Bool { false }
    var homeFeedCapabilities: Set<SourceOperation> { [] }
    var imagePrefetchConcurrency: Int { 32 }

    init(store: LocalLibraryStore = .shared) { self.store = store }

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = await store.allRecords().filter { query.isEmpty || $0.title.lowercased().contains(query) }
        return await records.dropFirst(offset).prefix(limit).asyncMap { record in
            manga(record, coverURL: await store.coverURL(itemId: record.itemId))
        }
    }

    func mangaDetail(id: String) async throws -> MangaDetail {
        guard await store.record(itemId: id) != nil else { throw SourceError.extractionFailed("missing local item") }
        return MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        guard let record = await store.record(itemId: mangaId) else { throw SourceError.extractionFailed("missing local item") }
        return record.chapters.map { Chapter(id: "\(mangaId)/\($0.number)", number: "\($0.number)", title: $0.title) }
    }

    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
        let parts = chapterId.split(separator: "/")
        guard parts.count == 2, let number = Int(parts[1]), !parts[0].isEmpty else { throw SourceError.extractionFailed("unknown chapter") }
        let urls = await store.pageURLs(itemId: String(parts[0]), chapter: number)
        guard !urls.isEmpty else { throw SourceError.extractionFailed("unknown chapter") }
        return urls
    }

    func popular(limit: Int, offset: Int) async throws -> [Manga] { throw SourceError.unsupported("popular") }

    private func manga(_ record: LocalItemRecord, coverURL: URL?) -> Manga {
        Manga(id: record.itemId, sourceId: Self.sourceID, title: record.title, description: "",
              status: "completed", year: nil, coverURL: coverURL, malId: nil,
              altTitles: nil, contentRating: nil)
    }
}

private extension Collection {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}
