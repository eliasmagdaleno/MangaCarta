//
//  RepositoryIndexSeam.swift
//  MangaCarta
//
//  **A seam, to be deleted when S2 merges.** The typed result of parsing a repository
//  index — what the installer consumes. The repository format design's "The index
//  document" and "Index validation" sections own the wire shape and the index-level
//  rules; the parser that applies them is Phase 4 S2's slice, and S2 owns
//  `Models/RepositoryIndex.swift`, where its real `RepositoryIndex` / `RepositoryBundle`
//  live. This file carries the same type names, shaped from the design, so that
//  integrating S2 is deleting this file and keeping the call sites, not renaming them.
//  `RepositoryTransport` is the one part expected to outlive the seam.
//
//  What is deliberately *not* here: any parsing. An index that reaches the installer as a
//  `RepositoryIndex` has already passed the index-level tier (well-formed JSON, known
//  format, bundle grammar, script URL policy, digest shape, and the whole-index `localId`
//  uniqueness rule). The declaration-level tier — `SourceDeclarationValidator` under the
//  qualified id the installer mints — is the installer's, because the qualified id is its
//  input and nothing else has one.
//

import Foundation

/// A repository index the installer can work from.
struct RepositoryIndex: Equatable, Sendable {
    /// The index's own format number, distinct from any bundle's `version` and from a
    /// declaration's `hostAPI` range — the design's "Three version numbers".
    let format: Int
    /// Display text, not identity.
    let name: String
    /// May be empty: a repository with nothing to offer is valid.
    let bundles: [RepositoryBundle]
}

/// One declaration record **exactly as served**. Raw on purpose: the installer
/// re-validates it from these bytes under the qualified id it mints (ADR-0003 Amendment
/// 4, decision 4) and persists it as served, not as a typed value. A `SourceDeclaration`
/// exists only as the validator's output.
struct RepositorySourceRecord: Equatable, Sendable {
    let rawJSON: JSONValue
    /// The `localId` string if the record carries one; grammar is the validator's.
    let localID: String?
}

/// One engine script plus the declarations that select it — the unit of fetch and of
/// update.
struct RepositoryBundle: Equatable, Sendable {
    /// Stable across versions; the same grammar as `localId`.
    let id: String
    /// Strictly increasing across releases. An integer, never semver.
    let version: Int
    /// Already resolved against the index URL and already policy-checked.
    let scriptURL: URL
    /// 64 lowercase hex characters: the SHA-256 of the script bytes as served.
    let scriptSHA256: String
    /// In index order.
    let sources: [RepositorySourceRecord]
}

/// What an index fetch came back with.
enum RepositoryIndexFetchOutcome: Equatable, Sendable {
    case index(RepositoryIndex)
    /// The host answered a permanent redirect (301/308). Per the design's "What keeps an
    /// identity" table the installer applies nothing until the reader confirms the new
    /// URL is theirs to trust; the stored URL is unchanged and the redirected index is not
    /// applied.
    case movedPermanently(to: URL)
}

/// The network the installer does not own. Production composes URLSession with S2's
/// parser; tests hand the installer an index directly. Bounds on index and script size
/// are the transport's (the design's "Bounds": tunables under the open evidence gate).
protocol RepositoryTransport: Sendable {
    /// Fetches and parses the index at exactly `url` — nothing appended or guessed. An
    /// index-level rejection is thrown as the parser's own located error.
    func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome
    /// Fetches a bundle's script bytes as served. The digest check is the installer's.
    func fetchScript(at url: URL) async throws -> Data
}
