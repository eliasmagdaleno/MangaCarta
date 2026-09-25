//
//  MangaDexAPI.swift
//  MangaCarta
//
//  Created by Elias Magdaleno on 10/8/25.
//

import Foundation

/// Relationship object used by MangaDex to attach related resources (e.g. cover_art).
struct MDRelationship: Decodable {                  // Decode relationship entries from API.
    let id: String                                  // Related object ID (e.g., cover_art id).
    let type: String                                // Relationship type (e.g., "cover_art", "author").
    let attributes: MDCoverAttributes?              // Attributes; for cover_art we care about fileName.
}

/// Attributes that appear on a cover_art relationship.
struct MDCoverAttributes: Decodable {               // Decode the nested attributes for cover_art.
    let fileName: String?                           // Actual file name on uploads (e.g., "abcd123.png").
}

/// Top-level list response for /manga.
struct MangaListResponse: Decodable {               // Decode array-style responses.
    let data: [MangaData]                           // The list of manga entries.
}

/// One manga item from /manga (with attributes + relationships).
struct MangaData: Decodable {                       // Represents a single manga entry in list responses.
    let id: String                                  // Manga ID.
    let attributes: MangaAttributes                 // Title/description/etc.
    let relationships: [MDRelationship]?            // ✅ Includes cover_art when requested via includes[].
}

/// Raw attributes for a manga from the API.
struct MangaAttributes: Decodable {                 // Raw payload we convert into our Manga struct.
    let title: [String: String]                     // Title in multiple locales; e.g., ["en": "Name"].
    // One single-key locale map per alternate, verified against the live API — NOT one
    // merged map, so the same locale can appear repeatedly and the values are what matter,
    // never the keys. Optional because entries with no alternates omit the key entirely.
    let altTitles: [[String: String]]?
    let description: [String: String]?              // Optional descriptions per locale.
    let status: String?                             // Ongoing/Completed/etc. (may be missing).
    let year: Int?                                  // Optional publication year.
    let links: [String: String]?                    // External-site ids (e.g. ["mal": "25"]); values may be slugs.

    /// Converts API attributes into our app’s `Manga` while attaching a prebuilt cover URL.
    /// - Parameters:
    ///   - id: The manga ID (UUID string).
    ///   - relationships: Relationship array to locate cover_art.fileName.
    func toManga(id: String, relationships: [MDRelationship]?) -> Manga {
        // 1) Prefer English title; if missing, fallback to any available locale; or "Unknown".
        let resolvedTitle = title["en"] ?? title.values.first ?? "Unknown"
        // 2) Prefer English description; fallback to empty string if none.
        let resolvedDescription = description?["en"] ?? ""
        // 3) Resolve status (fallback to "unknown" for consistency).
        let resolvedStatus = status ?? "unknown"
        // 4) Try to extract the cover filename from relationships (type == "cover_art").
        let fileName = relationships?
            .first(where: { $0.type == "cover_art" && $0.attributes?.fileName != nil })?
            .attributes?.fileName
        // 5) Build a thumbnail URL (512px) if we found a filename; otherwise nil.
        let cover = fileName.flatMap { mangaCoverURL(mangaId: id, fileName: $0, size: .w512) }
        // 6) Flatten the locale maps into a plain title list. Order is preserved as the API
        //    gave it (locale keys are not sorted, so the values are the only stable thing),
        //    blanks dropped, duplicates dropped, and the display title excluded — `title`
        //    already carries it, and a matcher that sees it twice scores it no differently.
        var seen: Set<String> = [resolvedTitle]
        let resolvedAltTitles = (altTitles ?? [])
            .flatMap(\.values)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        // 7) Produce our finalized Manga value with the pre-attached cover URL.
        return Manga(
            id: id,
            sourceId: MangaDexSource.sourceID,          // Everything from this API belongs to the MangaDex source.
            title: resolvedTitle,
            description: resolvedDescription,
            status: resolvedStatus,
            year: year,
            coverURL: cover,
            malId: links?["mal"].flatMap(Int.init),     // Free cross-source identity when MangaDex provides it.
            altTitles: resolvedAltTitles.isEmpty ? nil : resolvedAltTitles
        )
    }
}

// MARK: - Chapter payloads (used for Latest Updates and reading)

/// Top-level list response for /chapter.
struct ChapterListResponse: Decodable {             // Decode list of chapters.
    let data: [ChapterData]                         // The array of chapter entries.
    let total: Int                                  // Total matching chapters (for pagination).
}

/// One chapter entry from /chapter (we only parse what we need).
struct ChapterData: Decodable {                     // Represents a single chapter in list responses.
    let id: String                                  // Chapter ID.
    let attributes: ChapterAttributes               // Time/number/title/etc.
    let relationships: [MDRelationship]?            // Include "manga" relation if requested.
}

/// Raw attributes for a chapter (we focus on timing + metadata).
struct ChapterAttributes: Decodable {               // Minimal set for sorting/filters.
    let chapter: String?                            // Chapter number as string (may be nil).
    let title: String?                              // Optional chapter title.
    let translatedLanguage: String?                 // e.g., "en".
    let publishAt: String?                          // Publish timestamp as ISO string.
    let readableAt: String?                         // Readable timestamp (often used for sorting).
}

// MARK: - Reading (at-home) payloads

/// Response for /at-home/server/{chapterId}.
struct AtHomeServer: Decodable {                    // Needed to build page image URLs.
    let baseUrl: String                             // Temporary base URL for this chapter’s images.
}

/// Chapter pages data (hash + file names).
struct ChapterPagesResponse: Decodable {            // Holds base + chapter payload to build image URLs.
    let baseUrl: String                             // Base host to prepend.
    let chapter: ChapterPagesData                   // Hash + file arrays.
}

/// Nested chapter images payload (full vs data-saver).
struct ChapterPagesData: Decodable {                // The per-chapter arrays of image file names.
    let hash: String                                // Folder component for this chapter on the CDN.
    let data: [String]                              // Full-quality image files.
    let dataSaver: [String]                         // Reduced-size image files.
}

extension ChapterAttributes {                       // Convert raw chapter attributes → domain `Chapter`.
    /// Builds a `Chapter` from decoded attributes plus the chapter id from its container.
    func toChapter(id: String) -> Chapter {
        Chapter(id: id, number: chapter ?? "?", title: title,
                date: Chapter.parseISO8601(publishAt ?? readableAt))
    }
}

// MARK: - Detail wire types (/manga/{id})

/// Top-level response for the single-manga endpoint `/manga/{id}`.
struct MangaDetailResponse: Decodable {             // Object (not array) response wrapper.
    let data: MangaDetailData                       // The single manga payload.

    /// Converts the raw API payload into our `MangaDetail` domain value.
    func toDomain() -> MangaDetail {
        let attrs = data.attributes
        // Prefer English description; fall back to any locale; else empty.
        let description = attrs.description?["en"] ?? attrs.description?.values.first ?? ""
        // Collect author + artist names from relationships, dedupe while preserving order.
        var seen = Set<String>()
        let authors = (data.relationships ?? [])
            .filter { $0.type == "author" || $0.type == "artist" }
            .compactMap { $0.attributes?.name }
            .filter { seen.insert($0).inserted }
        // Resolve each tag's id, name, and group.
        let tags: [Tag] = (attrs.tags ?? []).compactMap { mdt in
            let name = mdt.attributes.name["en"] ?? mdt.attributes.name.values.first ?? ""
            guard !name.isEmpty else { return nil }
            return Tag(id: mdt.id, name: name, group: mdt.attributes.group ?? "")
        }
        return MangaDetail(description: description, authors: authors, tags: tags,
                           contentRating: attrs.contentRating)
    }
}

/// The single manga object inside a detail response.
struct MangaDetailData: Decodable {                 // Mirrors `MangaData` but with tags + author names.
    let id: String                                  // Manga ID.
    let attributes: MangaDetailAttributes           // Title/description/tags.
    let relationships: [MDDetailRelationship]?      // author/artist relations (names) when included.
}

/// Attributes for the detail endpoint (adds `tags` on top of the basic fields).
struct MangaDetailAttributes: Decodable {           // Detail-specific attribute payload.
    let title: [String: String]                     // Localized titles.
    let description: [String: String]?              // Localized descriptions.
    let tags: [MDTag]?                              // Genre/theme tags.
    let contentRating: String?                      // safe / suggestive / erotica / pornographic.
}

/// A MangaDex tag entry with a localized name.
struct MDTag: Decodable {                            // Wraps a tag's attributes.
    let id: String                                  // Tag UUID.
    let attributes: MDTagAttributes                 // Holds the localized name dictionary.
}

/// A tag entry from `/manga/tag` — like `MDTag` but with the tag's UUID, needed to
/// filter `/manga` via `includedTags[]`.
struct MDTagEntity: Decodable {
    let id: String                                  // Tag UUID used in includedTags[].
    let attributes: MDTagAttributes                 // Localized name dictionary.
}

/// Response wrapper for `GET /manga/tag`.
struct TagListResponse: Decodable {
    let data: [MDTagEntity]
}

/// Caches MangaDex's tag catalog as a case-insensitive name→UUID map. The app only ever
/// carries tag *display names* (`MangaDetail.tags`), but `/manga?includedTags[]=` needs
/// UUIDs, so tapping a genre chip resolves the name here first.
///
/// An `actor` because `MangaDexAPI`'s static methods are nonisolated — a shared mutable
/// dictionary would be a data race. We cache the in-flight *Task* (not just the result)
/// so concurrent first lookups share one network fetch, and drop it on failure so a
/// transient error isn't cached forever.
actor MangaDexTagCatalog {
    static let shared = MangaDexTagCatalog()

    /// Overridable fetch for tests; defaults to the live `/manga/tag` endpoint.
    private let fetchAll: () async throws -> [MDTagEntity]
    private var mapTask: Task<[String: String], Error>?

    init(fetchAll: @escaping () async throws -> [MDTagEntity] = {
        let res: TagListResponse = try await MangaDexAPI.request(endpoint: "/manga/tag")
        return res.data
    }) {
        self.fetchAll = fetchAll
    }

    /// The tag UUID for a display name (case-insensitive), or nil if no such tag exists.
    func id(forName name: String) async throws -> String? {
        let map = try await loadMap()
        return map[name.lowercased()]
    }

    private func loadMap() async throws -> [String: String] {
        if let mapTask { return try await mapTask.value }
        let task = Task { () throws -> [String: String] in
            let entities = try await fetchAll()
            return Dictionary(
                entities.compactMap { entity -> (String, String)? in
                    guard let name = entity.attributes.name["en"] ?? entity.attributes.name.values.first
                    else { return nil }
                    return (name.lowercased(), entity.id)
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
        mapTask = task
        do {
            return try await task.value
        } catch {
            mapTask = nil   // Don't cache a failed fetch.
            throw error
        }
    }
}

/// Localized name payload for a tag.
struct MDTagAttributes: Decodable {                 // e.g., name == ["en": "Action"].
    let name: [String: String]                      // Tag name per locale.
    let group: String?                              // Tag group (genre / theme / format / content); absent on some payloads.
}

/// Relationship on the detail endpoint that can carry an author/artist name.
struct MDDetailRelationship: Decodable {            // Separate from `MDRelationship` (which carries cover attrs).
    let id: String                                  // Related object ID.
    let type: String                                // e.g., "author", "artist".
    let attributes: MDAuthorAttributes?             // Author/artist attributes (name).
}

/// Attributes carrying an author/artist display name.
struct MDAuthorAttributes: Decodable {              // Decoded when includes[]=author/artist is requested.
    let name: String?                               // Person's display name.
}

// MARK: - Core API Client

/// Errors surfaced by the MangaDex client. `LocalizedError` so `errorMessage`
/// bindings show something meaningful instead of a generic URLError string.
enum MangaDexError: LocalizedError {
    case invalidURL                                 // Could not build a request URL.
    case invalidResponse                            // Response was not an HTTPURLResponse.
    case httpStatus(Int)                            // Non-2xx status (carries the code).
    case rateLimited                                // Still 429 after retrying.

    var errorDescription: String? {
        switch self {
        case .invalidURL:            return "Could not build a valid request URL."
        case .invalidResponse:       return "The server returned an unexpected response."
        case .httpStatus(let code):  return "Request failed with HTTP status \(code)."
        case .rateLimited:           return "Too many requests. Please try again in a moment."
        }
    }
}

struct MangaDexAPI {                                // Namespace-style struct for static helpers.
    static let baseURL = "https://api.mangadex.org" // Base REST API URL.

    /// Shared decoder (snake_case → camelCase). Reused across requests so we don't
    /// re-allocate a decoder and re-set its strategy on every call.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Generic GET + JSON decode helper for MangaDex endpoints.
    /// - Parameters:
    ///   - endpoint: Path beginning with '/', e.g., "/manga".
    ///   - queryItems: Optional query parameters.
    /// - Returns: Decoded value of type T.
    /// - Note: MangaDex rate-limits aggressively (HTTP 429). On a 429 we retry once,
    ///         honoring the `Retry-After` header, before giving up.
    static func request<T: Decodable>(endpoint: String,
                                      queryItems: [URLQueryItem]? = nil) async throws -> T {
        guard var comps = URLComponents(string: baseURL + endpoint) else {
            throw MangaDexError.invalidURL                       // Malformed base + path.
        }
        comps.queryItems = queryItems                           // Attach query parameters if provided.
        guard let url = comps.url else {                        // Ensure we produced a valid URL.
            throw MangaDexError.invalidURL                      // Throw if URL is malformed.
        }
        var req = URLRequest(url: url)                          // Create a URLRequest for custom headers.
        req.setValue("MangaCarta-iOS/1.0 (https://github.com/eliasmagdaleno/MangaCarta)",
                     forHTTPHeaderField: "User-Agent")          // Identify the client to the API.

        for attempt in 0..<2 {                                   // Initial try + one retry on 429.
            let (data, resp) = try await URLSession.shared.data(for: req) // Perform async GET request.
            guard let http = resp as? HTTPURLResponse else {    // Expect an HTTP response.
                throw MangaDexError.invalidResponse
            }
            if http.statusCode == 429, attempt == 0 {           // Rate limited: back off and retry once.
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                continue
            }
            guard (200...299).contains(http.statusCode) else {  // Validate we got a 2xx response.
                throw MangaDexError.httpStatus(http.statusCode) // Surface the actual status code.
            }
            return try decoder.decode(T.self, from: data)       // Decode into the requested generic type.
        }
        throw MangaDexError.rateLimited                          // Both attempts hit the rate limit.
    }

    /// Maps a `/manga` list response into domain `Manga` values (cover URL attached).
    private static func mangaList(from res: MangaListResponse) -> [Manga] {
        res.data.map { $0.attributes.toManga(id: $0.id, relationships: $0.relationships) }
    }

    // MARK: - High-level API: Manga Lists (ALWAYS with covers)

    // NOTE: Every /manga query below injects `includes[]=cover_art` so that the resulting `Manga`
    //       instances always have `coverURL` filled in (when available).

    /// Searches manga by title and returns `Manga` items carrying `coverURL`.
    static func searchManga(title: String, limit: Int = 20, offset: Int = 0) async throws -> [Manga] {
        // Build our query: search by title, include cover_art, and paginate.
        let items = [
            URLQueryItem(name: "title", value: title),              // Search term.
            URLQueryItem(name: "includes[]", value: "cover_art"),   // ✅ Ask for cover relationships.
            URLQueryItem(name: "limit", value: String(limit)),      // Page size.
            URLQueryItem(name: "offset", value: String(offset))     // Skip for pagination.
        ]
        // Call /manga and decode the list response.
        let res: MangaListResponse = try await MangaDexAPI.request(endpoint: "/manga", queryItems: items)
        // Map raw entries → our `Manga` model with coverURL already attached.
        return mangaList(from: res)
    }

    /// Fetches manga carrying a given genre/tag (by display name) with cover URLs.
    /// Resolves the name to its UUID via `MangaDexTagCatalog`; an unknown name yields
    /// no results rather than an error.
    static func fetchMangaByTag(name: String, limit: Int = 20, offset: Int = 0) async throws -> [Manga] {
        guard let tagID = try await MangaDexTagCatalog.shared.id(forName: name) else { return [] }
        let items = [
            URLQueryItem(name: "includedTags[]", value: tagID),     // Filter to this tag.
            URLQueryItem(name: "order[rating]", value: "desc"),     // Stable order → correct pagination.
            URLQueryItem(name: "includes[]", value: "cover_art"),   // ✅ Ask for cover relationships.
            URLQueryItem(name: "limit", value: String(limit)),      // Page size.
            URLQueryItem(name: "offset", value: String(offset))     // Skip for pagination.
        ]
        let res: MangaListResponse = try await MangaDexAPI.request(endpoint: "/manga", queryItems: items)
        return mangaList(from: res)
    }

    /// Fetches newly created manga (Newest first) with cover URLs.
    static func fetchNewTitles(limit: Int = 20, offset: Int = 0) async throws -> [Manga] {
        let items = [
            URLQueryItem(name: "order[createdAt]", value: "desc"),  // Sort by newest creation date.
            URLQueryItem(name: "includes[]", value: "cover_art"),   // ✅ Include cover data.
            URLQueryItem(name: "limit", value: String(limit)),      // Page size.
            URLQueryItem(name: "offset", value: String(offset))     // Pagination offset.
        ]
        let res: MangaListResponse = try await MangaDexAPI.request(endpoint: "/manga", queryItems: items)
        return mangaList(from: res)
    }

    /// Fetches highly-rated manga (Popular approximation) with cover URLs.
    static func fetchPopular(limit: Int = 20, offset: Int = 0) async throws -> [Manga] {
        let items = [
            URLQueryItem(name: "order[rating]", value: "desc"),     // Sort by rating, highest first.
            URLQueryItem(name: "includes[]", value: "cover_art"),   // Include cover data.
            URLQueryItem(name: "limit", value: String(limit)),      // Page size.
            URLQueryItem(name: "offset", value: String(offset))     // Pagination offset.
        ]
        let res: MangaListResponse = try await MangaDexAPI.request(endpoint: "/manga", queryItems: items)
        return mangaList(from: res)
    }

    // MARK: - Latest Updates (chapters → enriched manga with covers)

    /// Fetches latest chapter uploads, then enriches to unique manga (with covers) for a rail.
    /// Returns a list of `MangaUpdate` items you can show on your homepage.
    /// - Parameters:
    ///   - limitTitles: How many unique manga to return.
    ///   - translatedLang: Filter chapters by language (e.g., "en").
    ///   - offset: Paging offset into the *chapter* feed, not the returned manga. Dedupe
    ///     collapses chapters to unique manga, so a page routinely yields far fewer than
    ///     `limitTitles` items — callers must not read that as end-of-feed.
    /// - Note: This does a two-step process:
    ///         1) Get recent chapters with `includes[]=manga`
    ///         2) Batch-fetch the unique manga by IDs with `includes[]=cover_art`
    static func fetchLatestUpdates(limitTitles: Int = 20,
                                   translatedLang: String = "en",
                                   offset: Int = 0) async throws -> [MangaUpdate] {
        // 1) Ask for latest chapters, newest readable first, including manga relationship.
        //    Over-fetch chapters relative to the titles we want, since dedupe shrinks the
        //    page; /chapter caps `limit` at 100.
        let chapterLimit = min(100, max(limitTitles * 2, limitTitles))
        let items = [
            URLQueryItem(name: "includes[]", value: "manga"),       // Include "manga" relation on chapters.
            URLQueryItem(name: "translatedLanguage[]", value: translatedLang), // Filter by language.
            URLQueryItem(name: "order[readableAt]", value: "desc"), // Newest updates first.
            URLQueryItem(name: "limit", value: String(chapterLimit)), // Fetch enough to dedupe.
            URLQueryItem(name: "offset", value: String(offset))     // Page through the chapter feed.
        ]
        let chapters: ChapterListResponse = try await MangaDexAPI.request(endpoint: "/chapter", queryItems: items)

        // 2) Collect the first (newest) chapter for each unique manga ID.
        var uniqueMangaOrder: [String] = []                          // Preserve order of first-seen manga IDs.
        var newestChapterForManga: [String: String] = [:]            // Map mangaId → chapterId.
        for ch in chapters.data {                                    // Iterate newest → older.
            // Find related manga ID in relationships for this chapter.
            guard let mangaId = ch.relationships?.first(where: { $0.type == "manga" })?.id else { continue }
            // If we haven't seen this manga before, record the chapter and keep order.
            if newestChapterForManga[mangaId] == nil {
                newestChapterForManga[mangaId] = ch.id               // Save the newest chapter for this manga.
                uniqueMangaOrder.append(mangaId)                     // Remember appearance order.
                if uniqueMangaOrder.count >= limitTitles { break }   // Stop once we have enough unique manga.
            }
        }

        // 3) Enrich: fetch those manga by IDs WITH cover_art so we can build proper `Manga` objects.
        //    MangaDex supports querying multiple IDs using repeated ids[] parameters.
        let enriched = try await fetchMangaByIdsWithCovers(ids: uniqueMangaOrder)

        // 4) Build `MangaUpdate` list by pairing each enriched manga with its recorded chapterId.
        let updates: [MangaUpdate] = enriched.compactMap { manga in  // Map over enriched manga.
            guard let chId = newestChapterForManga[manga.id] else { return nil } // Find its newest chapter id.
            return MangaUpdate(chapterId: chId, manga: manga)        // Produce the update item.
        }

        return updates                                               // Return updates ready for UI.
    }

    /// Helper: batch-fetches manga by IDs with cover_art included, returning `Manga` with coverURL.
    /// - Parameter ids: Array of manga UUID strings (max 100 recommended per call).
    static func fetchMangaByIdsWithCovers(ids: [String]) async throws -> [Manga] {
        // Build repeated ids[] query parameters along with includes[]=cover_art.
        var items: [URLQueryItem] = [URLQueryItem(name: "includes[]", value: "cover_art")] // Ask for covers.
        ids.forEach { items.append(URLQueryItem(name: "ids[]", value: $0)) }               // Add each id.
        // Call /manga with our multi-id query.
        let res: MangaListResponse = try await MangaDexAPI.request(endpoint: "/manga", queryItems: items)
        // Convert to `Manga` with coverURL attached via toManga(...).
        return mangaList(from: res)
    }

    static func fetchMangaDetails(id: String) async throws -> MangaDetail {
        let res: MangaDetailResponse = try await request(endpoint: "/manga/\(id)", queryItems: [
            URLQueryItem(name: "includes[]", value: "author"),
            URLQueryItem(name: "includes[]", value: "artist")
            ]
                                                         )
        return res.toDomain()

    }

    static func fetchChapters(mangaId: String) async throws -> [Chapter] {
        // The /chapter endpoint caps `limit` at 100, so page through with offset
        // until we've collected every English chapter (guarded by a safety cap).
        let pageSize = 100
        let maxChapters = 2000
        var raw: [ChapterData] = []
        var offset = 0
        while offset < maxChapters {
            let res: ChapterListResponse = try await request(endpoint: "/chapter", queryItems: [
                URLQueryItem(name: "manga", value: mangaId),
                URLQueryItem(name: "translatedLanguage[]", value: "en"),
                URLQueryItem(name: "order[chapter]", value: "asc"),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "offset", value: String(offset))
            ])
            raw += res.data
            offset += pageSize
            if res.data.isEmpty || offset >= res.total { break }
        }
        // Multiple scanlation groups often upload the same chapter number. Keep the
        // first occurrence of each number (unknown-numbered chapters are never merged).
        var seenNumbers = Set<String>()
        return raw
            .map { $0.attributes.toChapter(id: $0.id) }
            .filter { $0.number == "?" || seenNumbers.insert($0.number).inserted }
    }

    // MARK: - Reading: build page URLs for a chapter

    /// Builds the per-page image URLs for a chapter using the At-Home server.
    /// - Parameters:
    ///   - chapterId: The target chapter’s ID.
    ///   - useDataSaver: Whether to prefer data-saver images (smaller).
    /// - Returns: Array of URLs (as `URL`) you can feed to `AsyncImage`.
    static func pageURLs(for chapterId: String, useDataSaver: Bool = true) async throws -> [URL] {
        // 1) Get at-home base URL and the data/dataSaver file arrays.
        let atHome: ChapterPagesResponse = try await MangaDexAPI.request(endpoint: "/at-home/server/\(chapterId)")
        // 2) Pick the array based on data-saver preference.
        let files = useDataSaver ? atHome.chapter.dataSaver : atHome.chapter.data
        // 3) Compose each full URL: {baseUrl}/{mode}/{hash}/{file}
        let mode = useDataSaver ? "data-saver" : "data"
        let base = atHome.baseUrl
        let hash = atHome.chapter.hash
        // 4) Map file names → URL objects, dropping any malformed ones with compactMap.
        return files.compactMap { URL(string: "\(base)/\(mode)/\(hash)/\($0)") }
    }

}
