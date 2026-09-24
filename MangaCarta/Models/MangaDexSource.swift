//
//  MangaDexSource.swift
//  MangaCarta
//
//  MangaDex as the first `MangaSource`. A thin adapter over the existing `MangaDexAPI`
//  networking layer — no request/decoding logic lives here. `MangaDexAPI` remains the
//  implementation (429 retry, pagination, cover-URL building); this type just exposes it
//  through the source-agnostic protocol.
//

import Foundation

struct MangaDexSource: MangaSource {
    /// Single source of truth for this source's identifier. `Manga.sourceId` is stamped
    /// with this value in `MangaAttributes.toManga`, and `SourceRegistry` resolves by it.
    static let sourceID = "mangadex"

    let id = MangaDexSource.sourceID
    let name = "MangaDex"
    var publishesExternalIds: Bool { true }

    /// True orderings of the three browse feeds (order[rating] / order[readableAt] /
    /// order[createdAt] in MangaDexAPI).
    var homeRailEyebrows: [String] { ["Top rated", "New chapters", "Just added"] }
    var supportsTagBrowse: Bool { true }

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        try await MangaDexAPI.searchManga(title: title, limit: limit, offset: offset)
    }

    func mangaByTag(tag: String, limit: Int, offset: Int) async throws -> [Manga] {
        try await MangaDexAPI.fetchMangaByTag(name: tag, limit: limit, offset: offset)
    }

    func popular(limit: Int, offset: Int) async throws -> [Manga] {
        try await MangaDexAPI.fetchPopular(limit: limit, offset: offset)
    }

    func newTitles(limit: Int, offset: Int) async throws -> [Manga] {
        try await MangaDexAPI.fetchNewTitles(limit: limit, offset: offset)
    }

    func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] {
        try await MangaDexAPI.fetchLatestUpdates(limitTitles: limitTitles, translatedLang: language, offset: offset)
    }

    func mangaDetail(id: String) async throws -> MangaDetail {
        try await MangaDexAPI.fetchMangaDetails(id: id)
    }

    func manga(id: String) async throws -> Manga? {
        try await MangaDexAPI.fetchMangaByIdsWithCovers(ids: [id]).first
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        try await MangaDexAPI.fetchChapters(mangaId: mangaId)
    }

    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
        try await MangaDexAPI.pageURLs(for: chapterId, useDataSaver: preferDataSaver)
    }

    func webURL(forManga id: String) async throws -> URL? {
        URL(string: "https://mangadex.org/title/\(id)")
    }
}
