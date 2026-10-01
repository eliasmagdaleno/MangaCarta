//
//  AniListAPI.swift
//  MangaCarta
//
//  Slice 1 of ADR-0007: the AniList GraphQL client. AniList is a *metadata
//  provider*, not a Source — it tells you about a manga, it never serves pages.
//
//  Two things distinguish it from MyAnimeListAPI, and both are deliberate:
//
//  1. It takes an injectable `Transport` instead of reaching for
//     `URLSession.shared` directly, so request building, error mapping, and
//     retry are all testable without the network.
//  2. Its live rate limit is 30 requests/minute (measured 2026-07-25 —
//     `x-ratelimit-limit: 30`, NOT the 90 the docs advertise). Per ADR-0007 the
//     whole budget is owned by one serial queue, so callers outside this file
//     go through that queue and never straight to `AniListAPI`.
//

import Foundation

/// Errors surfaced by the AniList client. `LocalizedError` so `errorMessage`
/// bindings show something meaningful, matching `MyAnimeListError`.
enum AniListError: LocalizedError, Equatable {
    case invalidResponse                            // Response was not an HTTPURLResponse.
    case notFound                                   // AniList does not know this Work. Terminal.
    case graphQL(message: String)                   // Query-level failure (our bug, usually).
    case rateLimited                                // Still 429 after retrying.
    case httpStatus(Int)                            // Non-2xx that isn't a 404 or 429.

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "AniList returned an unexpected response."
        case .notFound:
            return "AniList has no entry for this manga."
        case .graphQL(let message):
            return "AniList rejected the query: \(message)"
        case .rateLimited:
            return "Too many AniList requests. Please try again in a moment."
        case .httpStatus(let code):
            return "AniList request failed with HTTP status \(code)."
        }
    }
}

/// A tag on the **ranked axis**: AniList's 0–100 per-title relevance. Unsearchable
/// — AniList's 425-tag vocabulary shares only 32 names with MangaDex's 77, so
/// these are for scoring candidates already retrieved, never for search. MangaDex
/// tags land here too, with `rank == nil`.
struct RankedTag: Equatable, Codable {
    let name: String
    let rank: Int?
}

/// A Work's publication status. Drives the snapshot TTL (ADR-0007): `.finished` is
/// terminal, `.releasing` is known-incomplete because AniList reports
/// `chapters: null` until a series ends.
enum PublicationStatus: String, Codable {
    case finished, releasing, notYetReleased, cancelled, hiatus, unknown

    init(aniList raw: String?) {
        switch raw {
        case "FINISHED":         self = .finished
        case "RELEASING":        self = .releasing
        case "NOT_YET_RELEASED": self = .notYetReleased
        case "CANCELLED":        self = .cancelled
        case "HIATUS":           self = .hiatus
        default:                 self = .unknown
        }
    }
}

/// One AniList `Media` mapped onto the two tag axes ADR-0007 defines.
struct AniListWork: Equatable {
    let anilistId: Int
    let malId: Int?
    /// Every title AniList knows this Work by, romaji → english → native →
    /// synonyms. Matcher fuel: a richer left-hand side for `MALTitleMatcher`
    /// raises recall without loosening its precision-biased threshold.
    let knownTitles: [String]
    /// The **searchable** axis: AniList's 19 `genres`, 18 of which map onto
    /// MangaDex tag names, so these can drive `mangaByTag` candidate generation.
    let genres: [String]
    /// The **ranked** axis. Scoring only.
    let tags: [RankedTag]
    let publicationStatus: PublicationStatus
    /// `nil` for anything still releasing — AniList only knows a total once a
    /// series has finished. ADR-0004's routing fallback exists because of this.
    let chapterTotal: Int?

    /// Whether this record carries anything worth replacing a snapshot with.
    ///
    /// Read by **two** callers on purpose (ADR-0010): `WorkStore.apply`, which refuses to
    /// let an empty record discard a snapshot that has content, and the upgrade queue,
    /// which must record an outcome when `apply` declines — otherwise the Work keeps its
    /// unconditionally-stale provisional snapshot and is re-fetched forever. Two
    /// hand-maintained copies of this expression is how that defect comes back.
    var hasContent: Bool { !genres.isEmpty || !tags.isEmpty }
}

struct AniListAPI {
    static let endpoint = URL(string: "https://graphql.anilist.co")!

    /// Injectable so tests exercise the real request/decode/error path with no network.
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    init(transport: @escaping Transport = AniListAPI.urlSessionTransport) {
        self.transport = transport
    }

    static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AniListError.invalidResponse
        }
        return (data, http)
    }

    /// The one document every lookup uses; only the variables differ. Requesting
    /// `idMal` alongside `id` is what makes AniList *bridge* to MyAnimeList rather
    /// than compete with it — one call yields both external ids.
    private static let mediaQuery = """
    query ($id: Int, $malId: Int) {
      Media(id: $id, idMal: $malId, type: MANGA) {
        id idMal
        title { romaji english native }
        synonyms
        genres
        tags { name rank }
        status
        chapters
      }
    }
    """

    /// The whole 425-tag vocabulary in one 27 KB request (ADR-0011). `category` is a
    /// property of a tag *name*, globally, so it is fetched once and cached rather than
    /// persisted onto every Work.
    private static let tagCollectionQuery = """
    query {
      MediaTagCollection { name category isGeneralSpoiler isAdult }
    }
    """

    /// One page of media carrying **every** listed tag at `minimumTagRank` or better.
    ///
    /// `tag_in` is a **conjunction** on AniList, not a disjunction — verified live at
    /// ranks 0, 60 and 80 (ADR-0011's Context and its 2026-08-04 measurement). That is the
    /// whole reason the query unit is a *pair*: a single tag at a popularity sort is a
    /// popularity list wearing a tag's name, while `Demons AND Magic, both >= 60` is a
    /// statement about one reader.
    ///
    /// `isAdult: false` filters the *results*; excluding adult tags from the seeds is a
    /// separate decision made in `seedPairs`.
    private static let mediaByTagsQuery = """
    query ($tags: [String], $rank: Int, $perPage: Int) {
      Page(page: 1, perPage: $perPage) {
        media(type: MANGA, tag_in: $tags, minimumTagRank: $rank,
              isAdult: false, sort: POPULARITY_DESC) {
          id idMal
          title { romaji english native }
          synonyms
          genres
          tags { name rank }
          status
          chapters
        }
      }
    }
    """

    /// The pool query. Returns `[]` rather than throwing when AniList has nothing:
    /// under AND semantics an empty result is a **normal outcome** for a reader whose
    /// taste is genuinely rare, and treating it as an error would abort the whole refresh
    /// for exactly that user (ADR-0011).
    func media(tags: [String],
               minimumTagRank: Int = minimumSeedTagRank,
               limit: Int) async throws -> [AniListWork] {
        let payload: PagePayload = try await perform(
            query: Self.mediaByTagsQuery,
            variables: ["tags": tags, "rank": minimumTagRank, "perPage": limit])
        return (payload.page?.media ?? []).map { $0.toWork() }
    }

    /// Look a Work up by its MyAnimeList id — the common path, since MangaDex
    /// publishes `attributes.links.mal` and the app is already keyed on `malId`.
    func work(malId: Int) async throws -> AniListWork {
        let payload: MediaPayload = try await perform(query: Self.mediaQuery,
                                                      variables: ["malId": malId])
        guard let media = payload.media else { throw AniListError.notFound }
        return media.toWork()
    }

    /// The tag vocabulary. Shares `perform`'s retry and error mapping, so an HTML 502
    /// from a proxy surfaces as `.httpStatus` here too rather than as a `DecodingError`.
    func tagVocabulary() async throws -> [TagVocabularyEntry] {
        let payload: TagCollectionPayload = try await perform(query: Self.tagCollectionQuery,
                                                              variables: [:])
        return payload.tags ?? []
    }

    /// One request/retry/decode path for every query. Generic over the payload because the
    /// error handling — and only the error handling — is what the two callers share; each
    /// decides for itself what a missing payload means.
    private func perform<Payload: Decodable>(query: String,
                                             variables: [String: Any]) async throws -> Payload {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables])

        // Initial try plus one retry on 429, honoring Retry-After -- the same shape
        // as MyAnimeListAPI.request. Bounded deliberately:
        // the upgrade queue paces requests, so a client that retried indefinitely
        // would hide a budget problem the queue is supposed to prevent.
        for attempt in 0..<2 {
            let (data, http) = try await transport(request)

            if http.statusCode == 429, attempt == 0 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                continue
            }
            if http.statusCode == 429 { break }

            // The body is inspected before the status code, because AniList answers a
            // 404 with a perfectly well-formed GraphQL error -- that is a *semantic*
            // answer ("no such entry"), not a transport failure. Only when the body
            // isn't GraphQL at all does the status code become the interesting thing:
            // a 5xx from a proxy is an HTML page, and decoding it raises a
            // DecodingError that reads like a schema change and misdirects debugging.
            guard let envelope = try? JSONDecoder()
                .decode(GraphQLEnvelope<Payload>.self, from: data) else {
                throw (200...299).contains(http.statusCode)
                    ? AniListError.invalidResponse
                    : AniListError.httpStatus(http.statusCode)
            }

            if let first = envelope.errors?.first {
                throw first.status == 404 ? .notFound : AniListError.graphQL(message: first.message)
            }
            guard let payload = envelope.data else {
                throw AniListError.notFound
            }
            return payload
        }
        throw AniListError.rateLimited
    }
}

// MARK: - Wire types

/// The `{ data, errors }` shape every GraphQL response has. Generic over the payload:
/// error handling is identical for every query, the payload never is.
private struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    struct GraphQLError: Decodable {
        let message: String
        let status: Int?
    }
    let data: Payload?
    let errors: [GraphQLError]?
}

/// AniList nests the media under `data.Media` — capital M, hence the CodingKey.
/// Top-level rather than nested in `GraphQLEnvelope` so its `CodingKeys` doesn't
/// end up two levels deep, which SwiftLint's `nesting` rule rejects.
private struct MediaPayload: Decodable {
    let media: Media?
    enum CodingKeys: String, CodingKey { case media = "Media" }
}

private struct PagePayload: Decodable {
    struct Page: Decodable {
        let media: [Media]?
    }
    let page: Page?
    enum CodingKeys: String, CodingKey { case page = "Page" }
}

private struct TagCollectionPayload: Decodable {
    let tags: [TagVocabularyEntry]?
    enum CodingKeys: String, CodingKey { case tags = "MediaTagCollection" }
}

private struct Media: Decodable {
    struct Title: Decodable {
        let romaji: String?
        let english: String?
        let native: String?
    }
    struct MediaTag: Decodable {
        let name: String
        let rank: Int?
    }

    let id: Int
    let idMal: Int?
    let title: Title?
    let synonyms: [String]?
    let genres: [String]?
    let tags: [MediaTag]?
    let status: String?
    let chapters: Int?

    /// Trimmed, blanks dropped, order-preserving de-dup — the same treatment
    /// `MyAnimeListManga.allTitles` gives its titles, so both providers hand the
    /// matcher a list with the same guarantees. AniList frequently repeats a title
    /// across fields (One Piece's `romaji` and `native` are both "ONE PIECE").
    private var allTitles: [String] {
        var seen = Set<String>()
        return ([title?.romaji, title?.english, title?.native].compactMap { $0 } + (synonyms ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func toWork() -> AniListWork {
        AniListWork(anilistId: id,
                    malId: idMal,
                    knownTitles: allTitles,
                    genres: genres ?? [],
                    tags: (tags ?? []).map { RankedTag(name: $0.name, rank: $0.rank) },
                    publicationStatus: PublicationStatus(aniList: status),
                    chapterTotal: chapters)
    }
}
