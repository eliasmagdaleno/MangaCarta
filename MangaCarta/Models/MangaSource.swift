//
//  MangaSource.swift
//  MangaCarta
//
//  The source-abstraction seam. Everything the app does to browse and read manga
//  goes through a `MangaSource`, not a concrete API. MangaDex is source #1
//  (`MangaDexSource`); more sources plug in by conforming to this protocol.
//
//  Designed to be BRIDGE-FRIENDLY: every parameter is an `Int`/`String` and every
//  return value is a value/Codable domain type, with no Swift-only constructs crossing
//  the source boundary. This keeps the door open for a future dynamic-extension runtime
//  (JS/WASM) whose sources could conform to the same contract via a bridge.
//

import Foundation

/// A browsable, readable manga source (MangaDex, and later others).
protocol MangaSource {
    /// Stable identifier persisted in `Manga.sourceId` and `SourceRegistry` (e.g. "mangadex").
    var id: String { get }
    /// Human-readable name for pickers/UI (e.g. "MangaDex").
    var name: String { get }
    /// Whether this source serves adult content. Gated behind a Settings toggle.
    var isNSFW: Bool { get }
    /// Whether this source publishes external ids (for example MAL ids) that can be
    /// used by cross-catalogue resolution.
    var publishesExternalIds: Bool { get }

    /// Search the source by title. Results carry `coverURL` and `sourceId`.
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga]
    /// Whether this source can browse by a genre/tag name (see `mangaByTag`). The detail
    /// screen renders tappable genre chips only when this is true. Optional capability;
    /// defaults to false. Must be a protocol requirement so overrides dispatch through
    /// `any MangaSource` (see the NOTE below).
    var supportsTagBrowse: Bool { get }
    /// A genre/tag browse feed matching the given tag display name (as surfaced in
    /// `MangaDetail.tags`). Optional capability. Bridge-friendly: String/Int in, value out.
    func mangaByTag(tag: String, limit: Int, offset: Int) async throws -> [Manga]
    /// A "popular" browse feed (rating-ordered on MangaDex).
    func popular(limit: Int, offset: Int) async throws -> [Manga]
    /// A "newest titles" browse feed (creation-ordered on MangaDex). Optional capability.
    func newTitles(limit: Int, offset: Int) async throws -> [Manga]
    /// A "latest updates" feed (recent chapters → unique manga). Optional capability.
    /// `offset` pages the feed. Note it addresses the source's *underlying* feed, not the
    /// returned manga: MangaDex pages recent chapters and then dedupes them to unique
    /// manga, so a page can return far fewer than `limitTitles` items without being the
    /// end of the feed. Callers must not treat a short page as exhaustion.
    func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate]
    /// Enriched metadata for a single manga.
    func mangaDetail(id: String) async throws -> MangaDetail
    /// Fetch a listing by source id when the source supports id-based lookup.
    func manga(id: String) async throws -> Manga?
    /// The readable chapter list for a manga.
    func chapters(mangaId: String) async throws -> [Chapter]
    /// The per-page image URLs for a chapter.
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL]
    /// How many page images the reader may prefetch concurrently for this source.
    /// Lower it for rate-limit-sensitive image CDNs. Default 5.
    var imagePrefetchConcurrency: Int { get }
    /// The human-facing web page for a manga on the source's site (for "open in
    /// browser"). Optional capability; nil when the source has no web presence.
    func webURL(forManga id: String) async throws -> URL?

    // NOTE: these three must be protocol requirements (not extension-only) so a
    // source's override is reached through `any MangaSource` — extension-only
    // members dispatch statically and always hit the defaults.

    /// Titles for the three Home browse rails: [popular, latest-updates, new-titles].
    var homeRailTitles: [String] { get }
    /// The Home feeds this source declares. Undeclared feeds have no rail and are not
    /// loaded. Built-in sources use the default, while extension sources derive this
    /// from their declaration's capabilities.
    var homeFeedCapabilities: Set<SourceOperation> { get }
    /// Eyebrow labels above the rail titles, describing how each feed is actually
    /// ordered (e.g. "Top rated"). Empty (the default) hides the eyebrows.
    var homeRailEyebrows: [String] { get }
    /// Whether the middle (latest-updates) rail shows the tinted "NEW" badge.
    var latestRailShowsNewBadge: Bool { get }
}

/// Errors common to the source layer (distinct from a source's own transport errors).
enum SourceError: LocalizedError {
    /// The source does not implement an optional capability (carries the capability name).
    case unsupported(String)
    /// A Cloudflare interactive challenge was shown but never completed (dismissed/timed out).
    case cloudflareUnsolved
    /// The WebView could not load the page (carries the underlying reason).
    case navigationFailed(String)
    /// The extraction script failed or its output couldn't be decoded (carries the reason).
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let capability):
            return "This source doesn't support \(capability)."
        case .cloudflareUnsolved:
            return "Cloudflare verification wasn't completed."
        case .navigationFailed(let reason):
            return "Couldn't load the page: \(reason)"
        case .extractionFailed(let reason):
            return "Couldn't read the page: \(reason)"
        }
    }
}

// MARK: - Optional capabilities

/// Default implementations for feed methods a source may not offer. A source that lacks
/// a "new titles" or "latest updates" feed simply doesn't implement these and callers get
/// a clear `SourceError.unsupported` instead of a crash. MangaDex overrides all of them.
extension MangaSource {
    var isNSFW: Bool { false }
    var publishesExternalIds: Bool { false }

    func manga(id: String) async throws -> Manga? { nil }

    var supportsTagBrowse: Bool { false }

    func mangaByTag(tag: String, limit: Int, offset: Int) async throws -> [Manga] {
        throw SourceError.unsupported("mangaByTag")
    }

    func newTitles(limit: Int, offset: Int) async throws -> [Manga] {
        throw SourceError.unsupported("newTitles")
    }

    func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] {
        throw SourceError.unsupported("latestUpdates")
    }

    /// First page of the latest-updates feed. Convenience for the many callers that only
    /// ever want the top of the feed (Home rails, tests).
    func latestUpdates(limitTitles: Int, language: String) async throws -> [MangaUpdate] {
        try await latestUpdates(limitTitles: limitTitles, language: language, offset: 0)
    }

    var imagePrefetchConcurrency: Int { 5 }

    func webURL(forManga id: String) async throws -> URL? { nil }

    var homeRailTitles: [String] { ["Popular", "Recently Updated", "Newly Added"] }
    var homeFeedCapabilities: Set<SourceOperation> { Set(SourceOperation.discoveryFeeds) }
    var homeRailEyebrows: [String] { [] }
    /// Whether the middle (latest-updates) rail shows the tinted "NEW" badge.
    var latestRailShowsNewBadge: Bool { true }
}
