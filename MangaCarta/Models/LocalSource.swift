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
        let records = await store.allRecords()
        var ids = Set<String>()
        var mangas: [(String, LocalItemRecord)] = []
        let sortedRecords = records.sorted {
            $0.sourceFilename.localizedStandardCompare($1.sourceFilename) == .orderedAscending
        }
        var recordsByID: [String: [LocalItemRecord]] = [:]
        for record in sortedRecords {
            let id = LocalSeriesIdentity.normalizedSeries(record.comicInfo?.series)
                .map(LocalSeriesIdentity.seriesID) ?? record.itemId
            recordsByID[id, default: []].append(record)
        }
        for record in sortedRecords {
            let id: String
            if let series = LocalSeriesIdentity.normalizedSeries(record.comicInfo?.series) {
                id = LocalSeriesIdentity.seriesID(for: series)
                guard ids.insert(id).inserted else { continue }
            } else {
                id = record.itemId
            }
            mangas.append((id, recordsByID[id]?.sorted { LocalLibraryStore.seriesRecordBefore($0, $1) }.first ?? record))
        }
        return await mangas.filter { query.isEmpty || $0.1.title.lowercased().contains(query) }
            .dropFirst(offset).prefix(limit).asyncMap { id, record in
                manga(id: id, record: record, coverURL: await store.coverURL(itemId: record.itemId))
            }
    }

    func mangaDetail(id: String) async throws -> MangaDetail {
        guard let record = await store.seriesMetadata(for: id) else { throw SourceError.extractionFailed("missing local item") }
        let authors = (record.comicInfo?.writer ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tags = (record.comicInfo?.genres ?? []).map { Tag(id: nil, name: $0, group: nil) }
        return MangaDetail(description: record.comicInfo?.summary ?? "", authors: authors, tags: tags, contentRating: nil)
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        let chapters = await store.chapters(forMangaID: mangaId)
        guard !chapters.isEmpty else { throw SourceError.extractionFailed("missing local item") }
        return chapters.map { record, chapter, number in
            Chapter(id: "\(record.itemId)/\(chapter.number)", number: number, title: chapter.title)
        }
    }

    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
        let parts = chapterId.split(separator: "/")
        guard parts.count == 2, let number = Int(parts[1]), !parts[0].isEmpty else { throw SourceError.extractionFailed("unknown chapter") }
        let urls = await store.pageURLs(itemId: String(parts[0]), chapter: number)
        guard !urls.isEmpty else { throw SourceError.extractionFailed("unknown chapter") }
        return urls
    }

    func popular(limit: Int, offset: Int) async throws -> [Manga] { throw SourceError.unsupported("popular") }

    private func manga(id: String, record: LocalItemRecord, coverURL: URL?) -> Manga {
        Manga(id: id, sourceId: Self.sourceID, title: record.comicInfo?.series ?? record.title,
              description: record.comicInfo?.summary ?? "",
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
