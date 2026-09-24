//
//  ExtensionSource.swift
//  MangaCarta
//
//  An installed Source as a `MangaSource` — the adapter that makes installation mean
//  something. One validated `SourceDeclaration` plus its bundle script, served through
//  `ExtensionRuntime`: every protocol method becomes one `SourceOperation` invocation,
//  and every wire value comes back through `ExtensionDomainValidator` and the
//  `Extension*` adapters as a `Manga`, `MangaDetail`, `Chapter` or page `URL`.
//
//  Three things this type is built around:
//
//  * **The host stamps identity.** `Manga.sourceId` is the qualified id on every
//    conversion path, exactly as `toManga(id:relationships:)` stamps MangaDex's; the
//    engine's output cannot set it (Host API design, "Envelope and value rules").
//  * **An unregistered Source fails as unavailable.** A detail page or reader that
//    adopted this instance before the reader uninstalled or disabled it does not keep
//    running the engine: each call first asks `SourceLifecycleRegistry.isActive`, and
//    "calls fail as unavailable" (design §11) is what it does when the answer is no.
//  * **Offset in, cursor out.** `MangaSource` pages by `offset` because it was written
//    to be bridge-friendly; the Host API pages by opaque cursor. `CursorLedger` remembers
//    the cursor each page handed back, keyed by the offset it leads to, so the sequential
//    scroll `PagedMangaLoader` performs lands on consecutive pages without this adapter
//    ever guessing a cursor's shape.
//
//  The request shape sent to the engine is the one the shipped `bundled theme engine`
//  reads — `cursor` and `limit` beside the operation's own fields — which is the only
//  engine contract that exists on `main` today.
//

import Foundation

/// What an `ExtensionSource` needs from the host for one invocation: the capabilities
/// installed at `context.host`, built for this Source and this operation. The production
/// conformer is `ExtensionHostCapabilityFactory`; a test supplies captured HTML.
protocol ExtensionSourceHosting: AnyObject {
    @MainActor
    func capabilities(for declaration: SourceDeclaration,
                      operation: SourceOperation,
                      invocationID: UUID) -> [ExtensionHostCapability]
}

/// Why an `ExtensionSource` call failed, in the reader's words. The engine's own
/// `message` is diagnostic and never shown verbatim (design, "Errors and partial
/// success"); the sentence here is the host's, per stable error code.
enum ExtensionSourceError: LocalizedError, Equatable {
    /// The Source is disabled or uninstalled. Listings, pins and storage are intact and
    /// reconnect on reinstall; only calls are refused.
    case unavailable(name: String)
    /// The runtime ended the invocation with this code.
    case invocation(ExtensionHostErrorCode)
    /// An offset the adapter could not reach by following cursors from the last page it
    /// saw — the feed was reloaded elsewhere, or paged with a different size.
    case pageOutOfSequence

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            return "\(name) is no longer installed. Reinstall it to keep reading from it."
        case .invocation(let code):
            return Self.copy(for: code)
        case .pageOutOfSequence:
            return "Couldn't load that page of the feed. Pull to refresh and try again."
        }
    }

    private static func copy(for code: ExtensionHostErrorCode) -> String {
        switch code {
        case .cancelled:
            return "The request was cancelled."
        case .invalidRequest, .unsupported, .incompatibleVersion:
            return "This source can't handle that request. An update to the source may fix it."
        case .invalidResponse:
            return "The source returned something the app couldn't read."
        case .unsupportedLanguage:
            return "This source doesn't serve that language."
        case .network, .navigation:
            return "Couldn't reach the source. Check your connection and try again."
        case .http:
            return "The site answered with an error."
        case .rateLimited:
            return "The site is asking for a pause. Try again in a moment."
        case .timeout:
            return "The source took too long to answer."
        case .resourceLimit:
            return "The source needed more than the app allows for one request."
        case .policyDenied:
            return "The source tried to reach somewhere it isn't allowed to."
        case .interactionRequired:
            return "The site wants to verify your browser. Open this source in the foreground and try again."
        case .interactionDeclined:
            return "Browser verification wasn't completed."
        case .interactionTimedOut:
            return "Browser verification timed out."
        case .script:
            return "The source's script failed."
        case .storage:
            return "The source's storage is unavailable or full."
        }
    }
}

/// A Source installed from a repository, served through `ExtensionRuntime`.
///
/// Immutable once built: a changed declaration, script or adult class is a new instance,
/// which `ExtensionSourceRegistrar` swaps into `SourceRegistry`. Safe to call from any
/// actor — the runtime is per invocation and the only mutable state is the cursor
/// ledger, which locks.
final class ExtensionSource: MangaSource {

    let declaration: SourceDeclaration
    let script: String
    /// Effective class ≠ `none`: the declared class, or the reader's local elevation
    /// (repository format design §7.2). Decided by the registrar, which can read both.
    let isNSFW: Bool

    private let lifecycle: SourceLifecycleRegistry
    private let host: any ExtensionSourceHosting
    private let validator: ExtensionDomainValidator
    private let cursors = CursorLedger()

    init(declaration: SourceDeclaration,
         script: String,
         isNSFW: Bool,
         lifecycle: SourceLifecycleRegistry,
         host: any ExtensionSourceHosting) {
        self.declaration = declaration
        self.script = script
        self.isNSFW = isNSFW
        self.lifecycle = lifecycle
        self.host = host
        validator = ExtensionDomainValidator(assetOrigins: declaration.network.assetOrigins)
    }

    // MARK: - Identity and presentation

    var id: String { declaration.qualifiedId.rawValue }
    var name: String { declaration.name }

    var supportsTagBrowse: Bool { declaration.capabilities.supports(.tagBrowse) }

    var homeFeedCapabilities: Set<SourceOperation> {
        Set(SourceOperation.discoveryFeeds.filter { declaration.capabilities.supports($0) })
    }

    var imagePrefetchConcurrency: Int {
        declaration.presentation.imagePrefetchConcurrencyHint ?? 5
    }

    /// Feed presentation is per declared feed (design §13); text the declaration omits
    /// falls back to the host's own, the same defaults every compiled source uses.
    var homeRailTitles: [String] {
        [feed(.popular)?.title ?? "Popular",
         feed(.latestUpdates)?.title ?? "Recently Updated",
         feed(.newTitles)?.title ?? "Newly Added"]
    }

    var homeRailEyebrows: [String] {
        let eyebrows = [feed(.popular)?.eyebrow, feed(.latestUpdates)?.eyebrow, feed(.newTitles)?.eyebrow]
        return eyebrows.contains { $0 != nil } ? eyebrows.map { $0 ?? "" } : []
    }

    var latestRailShowsNewBadge: Bool {
        feed(.latestUpdates)?.badge == .new
    }

    private func feed(_ operation: SourceOperation) -> FeedPresentation? {
        declaration.presentation.feeds[operation]
    }

    func webURL(forManga id: String) async throws -> URL? {
        let value = try await invoke(.webURL, request: ["listingId": id])
        guard let object = value as? [String: Any],
              let rawURL = object["url"] as? String else {
            throw ExtensionSourceError.invocation(.invalidResponse)
        }
        guard let url = URL(string: rawURL),
              url.scheme == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host,
              declaration.network.browserOrigins.contains(where: { origin in
                  guard let allowed = URL(string: origin),
                        let allowedHost = allowed.host else { return false }
                  let actualPort = url.port ?? 443
                  let allowedPort = allowed.port ?? 443
                  return allowed.scheme == "https"
                      && allowedHost.caseInsensitiveCompare(host) == .orderedSame
                      && allowedPort == actualPort
              }) else {
            throw ExtensionSourceError.invocation(.invalidResponse)
        }
        return url
    }

    // MARK: - Feeds

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        try await listings(.search, key: "search:\(title)", limit: limit, offset: offset,
                           fields: ["query": title])
    }

    func popular(limit: Int, offset: Int) async throws -> [Manga] {
        try await listings(.popular, key: "popular", limit: limit, offset: offset, fields: [:])
    }

    func newTitles(limit: Int, offset: Int) async throws -> [Manga] {
        try await listings(.newTitles, key: "newTitles", limit: limit, offset: offset, fields: [:])
    }

    func mangaByTag(tag: String, limit: Int, offset: Int) async throws -> [Manga] {
        try await listings(.tagBrowse, key: "tag:\(tag)", limit: limit, offset: offset,
                           fields: ["tag": tag])
    }

    func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] {
        var fields: [String: Any] = [:]
        if let language = languageArgument(language) { fields["language"] = language }
        let page = try await paged(.latestUpdates, key: "latestUpdates:\(language)",
                                   limit: limitTitles, offset: offset, fields: fields) { value in
            let page = try self.validator.validateUpdatePage(value)
            return (page.items, page.nextCursor, page.exhausted)
        }
        return page.map { $0.toMangaUpdate(sourceID: id) }
    }

    private func listings(_ operation: SourceOperation,
                          key: String,
                          limit: Int,
                          offset: Int,
                          fields: [String: Any]) async throws -> [Manga] {
        let page = try await paged(operation, key: key, limit: limit, offset: offset,
                                   fields: fields) { value in
            let page = try self.validator.validateListingPage(value)
            return (page.items, page.nextCursor, page.exhausted)
        }
        return page.map { $0.toManga(sourceID: id) }
    }

    // MARK: - Detail, chapters, pages

    func mangaDetail(id: String) async throws -> MangaDetail {
        let value = try await invoke(.detail, request: ["listingId": id])
        return try validated { try validator.validateDetail(value).value.toMangaDetail() }
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        let value = try await invoke(.chapters, request: ["listingId": mangaId])
        return try validated { try validator.validateChapters(value).value.map { $0.toChapter() } }
    }

    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
        let value = try await invoke(.pages, request: ["chapterId": chapterId,
                                                        "quality": preferDataSaver ? "dataSaver" : "original"])
        return try validated { try validator.validatePages(value).value.map(\.url) }
    }

    // MARK: - Invocation

    /// One operation, one fresh runtime. The runtime is per invocation because the
    /// host's log capability is (it carries the invocation id and operation); the
    /// `JSContext` was already per invocation inside `ExtensionRuntime`.
    private func invoke(_ operation: SourceOperation, request: [String: Any]) async throws -> Any {
        guard declaration.capabilities.supports(operation) else {
            throw SourceError.unsupported(operation.rawValue)
        }
        let invocationID = UUID()
        let admitted: [ExtensionHostCapability]? = await MainActor.run {
            guard lifecycle.isActive(declaration.qualifiedId) else { return nil }
            return host.capabilities(for: declaration, operation: operation, invocationID: invocationID)
        }
        guard let capabilities = admitted else {
            throw ExtensionSourceError.unavailable(name: declaration.name)
        }
        let runtime = ExtensionRuntime(bundleScript: script,
                                       declaration: declaration,
                                       capabilities: capabilities)
        do {
            return try await runtime.invoke(operation, request: request)
        } catch let error as ExtensionInvocationError {
            // A cancelled invocation is the caller's own cancellation coming back, and
            // every view model already treats `CancellationError` as "superseded".
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw ExtensionSourceError.invocation(error.code)
        }
    }

    /// Schema failures are `invalid_response` in the design's taxonomy; the validator's
    /// field path stays in its own error for logs, and the reader sees the host's copy.
    private func validated<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ExtensionSchemaError {
            throw ExtensionSourceError.invocation(error.code)
        }
    }

    /// The language the host may pass, per the design's "Language contract": nothing for
    /// a `fixed` Source, and never a value the declaration does not list.
    private func languageArgument(_ language: String) -> String? {
        guard declaration.languages.mode != .fixed,
              declaration.languages.tags.contains(language) else { return nil }
        return language
    }

    // MARK: - Paging

    /// Serves `offset` from a cursor-paged operation. `parse` validates one page and
    /// returns its items, next cursor and exhaustion.
    private func paged<Item>(_ operation: SourceOperation,
                             key: String,
                             limit: Int,
                             offset: Int,
                             fields: [String: Any],
                             parse: (Any) throws -> ([Item], String?, Bool)) async throws -> [Item] {
        var position = cursors.startingPoint(for: key, offset: offset)
        while true {
            switch position {
            case .exhausted:
                return []
            case .page(let at, let cursor):
                var request = fields
                request["limit"] = limit
                if let cursor { request["cursor"] = cursor }
                let value = try await invoke(operation, request: request)
                let (items, next, exhausted) = try validated { try parse(value) }
                cursors.record(key: key, after: at, limit: limit, next: next, exhausted: exhausted)
                if at == offset { return items }
                // Walking forward from the last known cursor toward `offset`. A step
                // that lands no nearer means the offsets do not line up with this
                // limit, and no number of further steps would fix that.
                let following = cursors.startingPoint(for: key, offset: offset)
                if case .page(let reached, _) = following, reached <= at {
                    throw ExtensionSourceError.pageOutOfSequence
                }
                position = following
            }
        }
    }
}

/// The offset → cursor memory for one Source. Keyed by feed (operation plus its
/// argument), then by the offset a cursor leads to. Cursors are stored and replayed
/// opaquely; the only arithmetic here is on offsets the caller supplied.
private final class CursorLedger {

    enum StartingPoint: Equatable {
        /// Invoke with this cursor; the page starts at `offset`.
        case page(offset: Int, cursor: String?)
        /// The feed ended at or before this offset; nothing to fetch.
        case exhausted
    }

    private struct Feed {
        /// Offset → the cursor that fetches the page starting there. Offset 0 is the
        /// initial `null` cursor and is always known.
        var cursors: [Int: String?] = [0: nil]
        /// The first offset known to be past the end, once a page said `exhausted`.
        var endsAt: Int?
    }

    private let lock = NSLock()
    private var feeds: [String: Feed] = [:]

    /// Where to start for `offset`: the exact cursor when one is remembered, otherwise
    /// the nearest earlier one to walk forward from.
    func startingPoint(for key: String, offset: Int) -> StartingPoint {
        lock.withLock {
            let feed = feeds[key] ?? Feed()
            if let end = feed.endsAt, offset >= end { return .exhausted }
            if let cursor = feed.cursors[offset] { return .page(offset: offset, cursor: cursor) }
            let nearest = feed.cursors.keys.filter { $0 < offset }.max() ?? 0
            return .page(offset: nearest, cursor: feed.cursors[nearest] ?? nil)
        }
    }

    /// Records what the page starting at `offset` said about the one after it. "Exactly
    /// one of a non-null `nextCursor` or `exhausted: true` must be present" — the
    /// validator has already enforced that, so `next == nil` here means exhausted.
    func record(key: String, after offset: Int, limit: Int, next: String?, exhausted: Bool) {
        lock.withLock {
            var feed = feeds[key] ?? Feed()
            let following = offset + limit
            if exhausted || next == nil {
                feed.endsAt = min(feed.endsAt ?? following, following)
            } else {
                feed.cursors[following] = next
                if let end = feed.endsAt, end <= following { feed.endsAt = nil }
            }
            feeds[key] = feed
        }
    }
}
