//
//  RepositoryTransport.swift
//  MangaCarta
//
//  The network the installer does not own. `RepositoryIndex` and its parser are S2's,
//  in `Models/RepositoryIndex.swift`; this file is only the boundary the installer
//  fetches through. Production composes URLSession with `RepositoryIndexValidator`;
//  tests hand the installer an index directly.
//

import Foundation

/// What an index fetch came back with.
enum RepositoryIndexFetchOutcome: Equatable, Sendable {
    case index(RepositoryIndex)
    /// The host answered a permanent redirect (301/308). Per the design's "What keeps an
    /// identity" table the installer applies nothing until the reader confirms the new
    /// URL is theirs to trust; the stored URL is unchanged and the redirected index is not
    /// applied.
    case movedPermanently(to: URL)
}

/// Bounds on index and script size are the transport's — `RepositoryFormatLimits`, which
/// are tunables under the design's "Bounds" evidence gate.
protocol RepositoryTransport: Sendable {
    /// Fetches and parses the index at exactly `url` — nothing appended or guessed. An
    /// index-level rejection is thrown as the parser's own located error.
    func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome
    /// Fetches a bundle's script bytes as served. The digest check is the installer's.
    func fetchScript(at url: URL) async throws -> Data
}
