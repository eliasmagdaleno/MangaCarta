//
//  MyAnimeListAPI.swift
//  MangaCarta
//

import Foundation

/// Errors surfaced by the MyAnimeList client. `LocalizedError` so `errorMessage`
/// bindings show something meaningful instead of a generic URLError string.
enum MyAnimeListError: LocalizedError {
    case missingClientID                            // MAL_CLIENT_ID not set (Secrets.xcconfig).
    case invalidURL                                 // Could not build a request URL.
    case invalidResponse                            // Response was not an HTTPURLResponse.
    case httpStatus(Int)                            // Non-2xx status (carries the code).
    case rateLimited                                // Still 429 after retrying.

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Missing MyAnimeList API client ID. Set MAL_CLIENT_ID in Secrets.xcconfig."
        case .invalidURL:
            return "Could not build a valid MyAnimeList request URL."
        case .invalidResponse:
            return "MyAnimeList returned an unexpected response."
        case .httpStatus(let code):
            return "MyAnimeList request failed with HTTP status \(code)."
        case .rateLimited:
            return "Too many MyAnimeList requests. Please try again in a moment."
        }
    }
}

struct MyAnimeListManga: Decodable {
    let id: Int
    let title: String
    let mainPicture: MainPicture?
    let alternativeTitles: AlternativeTitles?
    /// `manga`, `manhwa`, `manhua`, `novel`, `light_novel`, `one_shot`, `doujinshi`.
    /// Optional so a response without the field still decodes — and so an unrecognised
    /// value is never treated as a novel (ADR-0017: absent means "keep").
    let mediaType: String?

    /// A prose work, not a comic. MAL files novels under `/manga`, and its adaptations
    /// carry the **same title** as their source novel — which is what makes this worth
    /// knowing (ADR-0017).
    var isNovel: Bool {
        mediaType == "novel" || mediaType == "light_novel"
    }

    struct MainPicture: Decodable {
        let medium: String?
        let large: String?
    }

    struct AlternativeTitles: Decodable {
        let synonyms: [String]?
        let en: String?
        let ja: String?
    }

    /// Every title this manga goes by, for entity-resolution matching: main title
    /// first, then the English and Japanese alternates, then synonyms. Blank entries
    /// dropped, order-preserving de-dup — so a scraped source that uses the English
    /// title still matches even when MAL's main title is the romaji one.
    var allTitles: [String] {
        var seen = Set<String>()
        return ([title, alternativeTitles?.en, alternativeTitles?.ja]
                    .compactMap { $0 } + (alternativeTitles?.synonyms ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct MyAnimeListMangaDetail: Decodable {
    let id: Int
    let title: String
    let synopsis: String?
    let mainPicture: MyAnimeListManga.MainPicture?
    let genres: [Genre]?
    let relatedManga: [Relation]?
    let recommendations: [Recommendation]?

    struct Genre: Decodable {
        let id: Int
        let name: String
    }

    struct Relation: Decodable {
        let node: MyAnimeListManga
        let relationType: String
        let relationTypeFormatted: String
    }

    struct Recommendation: Decodable {
        let node: MyAnimeListManga
        let numRecommendations: Int
    }
}

/// MAL wraps referenced manga in a `{node: {...}}` envelope for search results.
/// Internal (not private): the decode test in MangaCartaTests exercises this
/// unwrapping directly via `@testable import`, which only elevates `internal` symbols.
struct MyAnimeListSearchResponse: Decodable {
    struct Entry: Decodable {
        let node: MyAnimeListManga
    }
    let data: [Entry]
}

struct MyAnimeListAPI {                              // Namespace-style struct for static helpers.
    static let baseURL = "https://api.myanimelist.net/v2"

    /// Shared decoder (snake_case → camelCase).
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Search MAL by title. What cross-source entity resolution will call for sources
    /// with no direct MAL id (MangaDex usually has one already via external links).
    /// MAL's `q` accepts at most 64 characters and answers **HTTP 400** for anything
    /// longer — verified live 2026-07-28: 64 returns 200, 65 returns 400, and the cap
    /// counts characters rather than UTF-8 bytes (64 multibyte characters also returns
    /// 200, so truncating on bytes would cut Japanese titles to a third of the length
    /// MAL will actually take).
    ///
    /// A prefix is the right truncation rather than a rejection: MAL matches on prefixes,
    /// so the first 64 characters of a long title still find the entry, and
    /// `MALTitleMatcher` scores against the *full* title set afterwards regardless. Long
    /// titles are not exotic — scanlation releases routinely carry group tags, language
    /// markers and volume suffixes — and before this, every one of them 400'd, which
    /// stalled the metadata upgrade queue outright.
    static func searchQuery(for title: String) -> String {
        String(title.prefix(64))
    }

    /// Drops prose works from a candidate list. **This is the whole of ADR-0017.**
    ///
    /// MAL indexes a light novel and its comic adaptation as two entries under the *same
    /// title*, so the precision-biased matcher sees two candidates at identical similarity
    /// and the ambiguity guard correctly refuses — a Work that is silently unresolved
    /// forever, over a collision that is not a real doubt for a manga reader. Measured
    /// 2026-08-10 over twelve scraping-style titles: **6 of 12 refused, all six on the
    /// ambiguity guard, and four of them a novel/comic title collision.** Dropping novels
    /// took it to 2 of 12.
    ///
    /// Applied here rather than in the resolver because this is the only caller and the
    /// candidates are only ever used for resolution — a novel's `malId` would fetch a
    /// novel's tags, which is wrong for every consumer this app has. An unknown or absent
    /// `media_type` is **kept**: this filter exists to remove a known-bad candidate, not to
    /// require proof that a candidate is good.
    static func excludingNovels(_ candidates: [MyAnimeListManga]) -> [MyAnimeListManga] {
        candidates.filter { !$0.isNovel }
    }

    static func searchManga(title: String, limit: Int = 10) async throws -> [MyAnimeListManga] {
        let response: MyAnimeListSearchResponse = try await request(
            path: "/manga",
            queryItems: [
                URLQueryItem(name: "q", value: searchQuery(for: title)),
                URLQueryItem(name: "limit", value: String(limit)),
                // `media_type` is requested solely so `excludingNovels` can act on it; MAL
                // has no server-side filter for it on this endpoint.
                URLQueryItem(name: "fields", value: "alternative_titles,main_picture,media_type"),
            ]
        )
        return excludingNovels(response.data.map(\.node))
    }

    /// Fetch a manga's detail by MAL id, including the two fields a future
    /// "More Like This" UI will consume: related manga and recommendations.
    static func mangaDetail(id: Int) async throws -> MyAnimeListMangaDetail {
        try await request(
            path: "/manga/\(id)",
            queryItems: [
                URLQueryItem(name: "fields",
                             value: "alternative_titles,synopsis,main_picture,genres,related_manga,recommendations"),
            ]
        )
    }

    /// Every spelling MAL knows this manga by, main title first — the widened search
    /// input of ADR-0020, and the one request that arm costs.
    ///
    /// It exists as its own endpoint because `mangaDetail` cannot supply it: MAL does not
    /// apply top-level `fields` to nested `recommendations` nodes, so a recommendation
    /// arrives with `alternativeTitles == nil` no matter what the parent asked for. Asking
    /// for the whole detail would also drag synopsis, genres, related manga and
    /// recommendations across the wire for three strings.
    static func alternativeTitles(id: Int) async throws -> [String] {
        let manga: MyAnimeListManga = try await request(
            path: "/manga/\(id)",
            queryItems: [URLQueryItem(name: "fields", value: "alternative_titles")]
        )
        return manga.allTitles
    }

    /// Generic GET + JSON decode helper for MAL endpoints.
    /// - Note: MAL is known to soft rate-limit (HTTP 429). On a 429 we retry once,
    ///         honoring the `Retry-After` header, before giving up — same behavior as
    ///         AniListAPI's request.
    private static func request<T: Decodable>(path: String,
                                              queryItems: [URLQueryItem]) async throws -> T {
        guard var comps = URLComponents(string: baseURL + path) else {
            throw MyAnimeListError.invalidURL
        }
        comps.queryItems = queryItems
        guard let url = comps.url else {
            throw MyAnimeListError.invalidURL
        }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "MALClientID") as? String,
              !clientID.isEmpty else {
            throw MyAnimeListError.missingClientID
        }
        var req = URLRequest(url: url)
        req.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")

        for attempt in 0..<2 {                                   // Initial try + one retry on 429.
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw MyAnimeListError.invalidResponse
            }
            if http.statusCode == 429, attempt == 0 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw MyAnimeListError.httpStatus(http.statusCode)
            }
            return try decoder.decode(T.self, from: data)
        }
        throw MyAnimeListError.rateLimited
    }
}
