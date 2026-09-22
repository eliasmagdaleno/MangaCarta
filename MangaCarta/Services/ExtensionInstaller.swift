//
//  ExtensionInstaller.swift
//  MangaCarta
//
//  The path from a URL the reader types to a Source in `SourceLifecycleRegistry`, and
//  every gesture after that: refresh, install, update, disable, uninstall, remove, erase,
//  change URL, treat as adult. The repository format design's "Operations" section owns
//  what each does; ADR-0003 Amendment 4 owns why.
//
//  Three things this type is built around:
//
//  * **It mints identity, and nothing else does.** A repository's UUID is minted at first
//    add and persisted; the qualified Source id is that UUID joined to the declaration's
//    `localId` — `qualifiedID(repositoryID:localId:)` below is the one producer, and
//    nothing anywhere may split one. The reader's gesture is the only thing that tells a
//    move ("Change repository URL": same UUID) from a replacement ("Add": new UUID).
//  * **It wraps the registry; it does not duplicate it.** `SourceLifecycleRegistry` owns
//    the state machine and the `validateUpdate` rule. This type drives the transitions
//    from repository events and persists the result in `RepositoryStore`.
//  * **A typed declaration is a validated one.** Every declaration handed to the registry
//    is `SourceDeclarationValidator`'s output from the raw JSON as served, under the id
//    minted here — at install, at update, and again at every launch from the stored
//    bytes. There is no other way to obtain one (#161).
//
//  Atomicity, per the design's "Operations": on any failure nothing the reader can observe
//  changes. Each operation does its fallible work — fetch, digest, validate, the update
//  rule — before touching anything, then persists (one atomic `commit`), then moves the
//  registry, which by then cannot refuse.
//

import CryptoKit
import Foundation

// MARK: - Seams

/// What "Erase data" actually erases for one Source: the `host.storage` namespace and
/// the per-Source WebKit data store. `InstalledSourceDataEraser` is the production
/// conformer; tests record what would have been erased.
protocol SourceDataErasing: Sendable {
    func eraseData(for id: QualifiedSourceID) async throws
}

/// What the one-time acknowledgement sheet shows for a `mixed` or `adultOnly` install
/// (design §7.1, ADR-0022 Amendment 1). Declining ends the install with nothing persisted.
struct AdultInstallAcknowledgement: Equatable, Sendable {
    let sourceName: String
    let repositoryName: String
    let classification: AdultClassification
}

// MARK: - Results

/// What the most recent successful add, refresh or URL change found in a repository's
/// index, per declaration, under this repository's identity.
struct RepositoryListing: Equatable {
    struct Entry: Equatable {
        let bundleId: String
        let bundleVersion: Int
        /// Key path within the index, in the style of `SourceDeclarationError`.
        let path: String
        /// `nil` when the served record carries no usable `localId` — nothing can be
        /// minted for it, and `outcome` says why it was refused.
        let localId: String?
        /// As served. What a later install re-validates and persists.
        let rawDeclaration: JSONValue
        /// A declaration-level failure rejects this entry and nothing else (design §4).
        let outcome: Result<SourceDeclaration, SourceDeclarationError>

        var declaration: SourceDeclaration? {
            if case .success(let declaration) = outcome { return declaration }
            return nil
        }
    }

    let index: RepositoryIndex
    let entries: [Entry]
    /// Bundle id → the version the index now offers, for bundles with an installed Source
    /// whose installed version is lower. `version` is the only trigger.
    let availableUpdates: [String: Int]
    /// Installed Sources this index no longer lists. They stay installed and runnable.
    let noLongerListed: [QualifiedSourceID]

    func entry(localId: String) -> Entry? {
        entries.first { $0.localId == localId }
    }
}

enum RepositoryRefreshOutcome: Equatable {
    case refreshed(RepositoryListing)
    /// Nothing was applied; the reader confirms with `changeRepositoryURL`.
    case movedPermanently(to: URL)
}

// MARK: - Errors

enum ExtensionInstallError: Error, Equatable {
    case unknownRepository(UUID)
    case repositoryRemoved(UUID)
    case repositoryAlreadyAdded(UUID, URL)
    case indexMoved(from: URL, to: URL)
    /// Two declarations in one index would mint the same qualified id. Names both.
    case qualifiedIDCollision(localId: String, first: String, second: String)
    case notRefreshed(UUID)
    case notListed(localId: String)
    case declarationRejected(localId: String, SourceDeclarationError)
    case alreadyInstalled(QualifiedSourceID)
    case bundleUpdatePending(bundleId: String, installed: Int, offered: Int)
    case scriptDigestMismatch(expected: String, actual: String)
    case adultAcknowledgementDeclined(localId: String)
    case noUpdateAvailable(bundleId: String)
    /// `validateUpdate` refused; the installed Source is intact.
    case updateRefused(localId: String, SourceDeclarationError)
    case unknownSource(QualifiedSourceID)
    case sourceStillInstalled(QualifiedSourceID)
    case repositoryStillActive(UUID)
    case lifecycle(SourceLifecycleError)
    case persistence(String)

    /// The sentence the reader sees (Phase 4 acceptance criterion 10).
    var message: String {
        switch self {
        case .unknownRepository:
            return "That repository is not in your list."
        case .repositoryRemoved:
            return "That repository was removed. Add it again to use it."
        case .repositoryAlreadyAdded(_, let url):
            return "\(url.absoluteString) is already in your repositories."
        case .indexMoved(let from, let to):
            return "The repository at \(from.absoluteString) has moved to \(to.absoluteString). "
                + "Add the new address instead."
        case .qualifiedIDCollision(let localId, let first, let second):
            return "This repository lists the Source id '\(localId)' twice, at \(first) and "
                + "\(second), so it cannot say which one it means."
        case .notRefreshed:
            return "The repository's index has not been loaded yet. Refresh it first."
        case .notListed(let localId):
            return "The repository no longer lists a Source '\(localId)'."
        case .declarationRejected(let localId, let error):
            return "The Source '\(localId)' cannot be installed: \(error.message)"
        case .alreadyInstalled:
            return "That Source is already installed."
        case .bundleUpdatePending(let bundleId, let installed, let offered):
            return "The bundle '\(bundleId)' is installed at version \(installed) but the repository "
                + "now offers version \(offered). Update it before installing another Source from it."
        case .scriptDigestMismatch(let expected, let actual):
            return "The engine script does not match what the repository promised "
                + "(expected SHA-256 \(expected), received \(actual))."
        case .adultAcknowledgementDeclined:
            return "The install was cancelled. Nothing was added."
        case .noUpdateAvailable(let bundleId):
            return "There is no update for '\(bundleId)'."
        case .updateRefused(let localId, let error):
            return "The update for '\(localId)' was refused and nothing changed: \(error.message)"
        case .unknownSource:
            return "That Source is not installed."
        case .sourceStillInstalled:
            return "Uninstall the Source before erasing its data."
        case .repositoryStillActive:
            return "Remove the repository before erasing its data."
        case .lifecycle(let error):
            return "The Source's state could not be changed: \(error)"
        case .persistence(let reason):
            return reason
        }
    }
}

// MARK: - Installer

@MainActor
final class ExtensionInstaller {

    let store: RepositoryStore
    let registry: SourceLifecycleRegistry

    private let transport: any RepositoryTransport
    private let dataEraser: any SourceDataErasing
    private let hostAPI: HostAPISupport
    private let acknowledgeAdult: (AdultInstallAcknowledgement) async -> Bool
    private let updateRule: (SourceDeclaration, SourceDeclaration) -> SourceDeclarationError?
    private let now: () -> Date

    /// Per repository, what its most recent successful add / refresh / URL change found.
    /// In memory only: a listing is a view of a remote document, not the reader's data.
    private(set) var listings: [UUID: RepositoryListing] = [:]

    /// Sources whose stored declaration failed re-validation at launch — by a tightened
    /// validator or a retired Host API version. Shown, not uninstalled.
    private(set) var launchRefusals: [QualifiedSourceID: SourceDeclarationError] = [:]

    /// - Parameters:
    ///   - updateRule: the identity rule an update is checked against before the registry
    ///     is touched. Production passes the validator's own; it is a parameter so a test
    ///     can prove a refusal surfaces as a failed update, which honest inputs cannot
    ///     reach (the id is minted from the same `localId` the update is matched on).
    init(store: RepositoryStore,
         registry: SourceLifecycleRegistry,
         transport: any RepositoryTransport,
         dataEraser: any SourceDataErasing,
         hostAPI: HostAPISupport = .v1,
         acknowledgeAdult: @escaping (AdultInstallAcknowledgement) async -> Bool,
         updateRule: @escaping (SourceDeclaration, SourceDeclaration) -> SourceDeclarationError?
            = SourceDeclarationValidator.validateUpdate,
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.registry = registry
        self.transport = transport
        self.dataEraser = dataEraser
        self.hostAPI = hostAPI
        self.acknowledgeAdult = acknowledgeAdult
        self.updateRule = updateRule
        self.now = now
    }

    // MARK: Identity

    /// The only producer of a `QualifiedSourceID`: the repository UUID in lowercase
    /// hyphenated form, a single `:`, then `localId` (design §5.2). Written down so the
    /// WebKit store identifier derived from it stays stable forever; nothing may parse it.
    static func qualifiedID(repositoryID: UUID, localId: String) -> QualifiedSourceID {
        QualifiedSourceID(rawValue: "\(repositoryID.uuidString.lowercased()):\(localId)")
    }

    // MARK: Launch

    /// Re-validates every stored declaration from its raw JSON and reconnects the registry
    /// (ADR-0003 Amendment 4, decision 4). A refusal is recorded in `launchRefusals` with
    /// the validator's error; the record is never uninstalled on the app's behalf.
    func restoreInstalledSources() {
        launchRefusals = [:]
        for record in store.snapshot.sources.values where record.state != .uninstalled {
            switch SourceDeclarationValidator.validate(json: record.declaration,
                                                       qualifiedId: record.qualifiedId,
                                                       hostAPI: hostAPI) {
            case .success(let declaration):
                do {
                    try registry.reinstall(declaration)
                    if record.state == .disabled { try registry.disable(record.qualifiedId) }
                } catch let error as SourceLifecycleError {
                    if case .declarationInvalid(let reason) = error {
                        launchRefusals[record.qualifiedId] = reason
                    }
                } catch {}
            case .failure(let error):
                launchRefusals[record.qualifiedId] = error
            }
        }
    }

    // MARK: Add repository (§6.1)

    /// Adds the repository whose index is at exactly `url`. Installs nothing.
    ///
    /// A URL matching a **removed** repository's record reconnects that identity by
    /// default (`reconnectRemoved`); "add as new" mints a fresh UUID instead.
    @discardableResult
    func addRepository(at url: URL,
                       reconnectRemoved: Bool = true,
                       repositoryID requestedID: UUID? = nil) async throws -> RepositoryRecord {
        if let existing = store.repository(at: url), existing.state == .active {
            throw ExtensionInstallError.repositoryAlreadyAdded(existing.id, url)
        }
        let removed = reconnectRemoved
            ? store.repositories.first { $0.indexURL == url && $0.state == .removed }
            : nil
        // Provisional until the index is accepted; discarded on any rejection.
        let repositoryID = removed?.id ?? requestedID ?? UUID()

        let index: RepositoryIndex
        switch try await transport.fetchIndex(at: url) {
        case .index(let fetched):
            index = fetched
        case .movedPermanently(let destination):
            throw ExtensionInstallError.indexMoved(from: url, to: destination)
        }
        let listing = try makeListing(index, repositoryID: repositoryID)

        let timestamp = now()
        var record = removed ?? RepositoryRecord(id: repositoryID,
                                                 indexURL: url,
                                                 name: index.name,
                                                 addedAt: timestamp,
                                                 lastRefreshedAt: nil,
                                                 state: .active,
                                                 format: index.format,
                                                 boundKey: nil)
        record.indexURL = url
        record.name = index.name
        record.format = index.format
        record.lastRefreshedAt = timestamp
        record.state = .active
        try persist { $0.repositories[repositoryID] = record }
        listings[repositoryID] = listing
        return record
    }

    // MARK: Refresh (§6.2)

    /// Re-fetches and re-validates under the existing UUID. A failure leaves the previous
    /// listing in place; a permanent redirect applies nothing until confirmed.
    @discardableResult
    func refresh(_ repositoryID: UUID) async throws -> RepositoryRefreshOutcome {
        let record = try activeRepository(repositoryID)
        return try await applyIndex(fetchedFrom: record.indexURL, to: record)
    }

    // MARK: Change repository URL (§6.6)

    /// The reader asserting "same repository, new address": validates the index at `url`
    /// under the **existing** UUID and, only if accepted, moves the stored URL. This is
    /// also how a permanent redirect is confirmed.
    @discardableResult
    func changeRepositoryURL(_ repositoryID: UUID, to url: URL) async throws -> RepositoryRefreshOutcome {
        let record = try activeRepository(repositoryID)
        return try await applyIndex(fetchedFrom: url, to: record)
    }

    private func applyIndex(fetchedFrom url: URL,
                            to record: RepositoryRecord) async throws -> RepositoryRefreshOutcome {
        let index: RepositoryIndex
        switch try await transport.fetchIndex(at: url) {
        case .index(let fetched):
            index = fetched
        case .movedPermanently(let destination):
            return .movedPermanently(to: destination)
        }
        let listing = try makeListing(index, repositoryID: record.id)

        var updated = record
        updated.indexURL = url
        updated.name = index.name
        updated.format = index.format
        updated.lastRefreshedAt = now()
        try persist { $0.repositories[record.id] = updated }
        listings[record.id] = listing
        return .refreshed(listing)
    }

    // MARK: Install (§6.3)

    /// Installs one Source the most recent refresh listed as installable.
    @discardableResult
    func install(localId: String, from repositoryID: UUID) async throws -> InstalledSourceRecord {
        let repository = try activeRepository(repositoryID)
        let (entry, bundle) = try installableEntry(localId: localId, in: repositoryID)
        let qualifiedId = Self.qualifiedID(repositoryID: repositoryID, localId: localId)
        let existing = store.source(qualifiedId)
        if let existing, existing.state != .uninstalled {
            throw ExtensionInstallError.alreadyInstalled(qualifiedId)
        }

        // Step 1: the script, digest-checked against the index's promise.
        let script = try await fetchVerifiedScript(for: bundle)

        // Step 2: the declaration, validated again from the raw JSON as served, under the
        // id minted here. This value is the only kind the registry ever receives.
        let declaration = try validated(entry.rawDeclaration, localId: localId, as: qualifiedId)

        // §7.1: the acknowledgement comes before anything is persisted or registered.
        if declaration.adult != .none {
            let acknowledgement = AdultInstallAcknowledgement(sourceName: declaration.name,
                                                              repositoryName: repository.name,
                                                              classification: declaration.adult)
            guard await acknowledgeAdult(acknowledgement) else {
                throw ExtensionInstallError.adultAcknowledgementDeclined(localId: localId)
            }
        }

        // Step 3, checked before anything is written so the registry cannot refuse after
        // persistence: a reconnect goes through `validateUpdate`; a first registration
        // has nothing to refuse.
        let reconnecting = registry.state(for: qualifiedId) != nil
        if reconnecting, let remembered = registry.declaration(for: qualifiedId),
           let refusal = SourceDeclarationValidator.validateUpdate(from: remembered, to: declaration) {
            throw ExtensionInstallError.lifecycle(.declarationInvalid(refusal))
        }

        // Step 4: persist — script file first (invisible without a record), then the
        // records in one commit; the file is removed again if the commit fails.
        let timestamp = now()
        let record = InstalledSourceRecord(qualifiedId: qualifiedId,
                                           repositoryID: repositoryID,
                                           localId: localId,
                                           bundleId: bundle.id,
                                           declaration: entry.rawDeclaration,
                                           state: .registered,
                                           localAdultElevation: existing?.localAdultElevation,
                                           installedAt: existing?.installedAt ?? timestamp,
                                           updatedAt: timestamp)
        let bundleKey = InstalledBundleKey(repositoryID: repositoryID, bundleId: bundle.id)
        let bundleWasInstalled = store.bundle(bundle.id, in: repositoryID) != nil
        try store.writeScript(script, for: bundle.id, in: repositoryID)
        do {
            try persist { snapshot in
                snapshot.sources[qualifiedId] = record
                if snapshot.bundles[bundleKey] == nil {
                    snapshot.bundles[bundleKey] = InstalledBundleRecord(repositoryID: repositoryID,
                                                                        bundleId: bundle.id,
                                                                        version: bundle.version,
                                                                        scriptSHA256: bundle.scriptSHA256)
                }
            }
        } catch {
            if !bundleWasInstalled { store.deleteScript(for: bundle.id, in: repositoryID) }
            throw error
        }

        do {
            if reconnecting {
                try registry.reinstall(declaration)
            } else {
                try registry.register(declaration)
            }
        } catch let error as SourceLifecycleError {
            throw ExtensionInstallError.lifecycle(error)
        }
        launchRefusals[qualifiedId] = nil
        return record
    }

    /// The precondition of §6.3: the Source's declaration validated in the most recent
    /// refresh. Also refuses a new Source from a bundle whose installed sibling is on a
    /// different version — they would share one script file — until the bundle is updated.
    private func installableEntry(localId: String,
                                  in repositoryID: UUID) throws -> (RepositoryListing.Entry, RepositoryBundle) {
        guard let listing = listings[repositoryID] else {
            throw ExtensionInstallError.notRefreshed(repositoryID)
        }
        guard let entry = listing.entry(localId: localId),
              let bundle = listing.index.bundles.first(where: { $0.id == entry.bundleId }) else {
            throw ExtensionInstallError.notListed(localId: localId)
        }
        if case .failure(let error) = entry.outcome {
            throw ExtensionInstallError.declarationRejected(localId: localId, error)
        }
        if let installedBundle = store.bundle(bundle.id, in: repositoryID),
           installedBundle.version != bundle.version {
            throw ExtensionInstallError.bundleUpdatePending(bundleId: bundle.id,
                                                            installed: installedBundle.version,
                                                            offered: bundle.version)
        }
        return (entry, bundle)
    }

    // MARK: Update bundle (§6.4)

    /// Applies an update the most recent refresh offered: all-or-nothing across every
    /// installed Source the bundle supplies. Any refusal — a bad digest, a declaration
    /// that no longer validates, or `validateUpdate` — ends the update with the registry,
    /// the records and the script file untouched (Phase 4 acceptance criterion 5).
    func updateBundle(_ bundleId: String, in repositoryID: UUID) async throws {
        _ = try activeRepository(repositoryID)
        guard let listing = listings[repositoryID] else {
            throw ExtensionInstallError.notRefreshed(repositoryID)
        }
        guard let offered = listing.availableUpdates[bundleId],
              let bundle = listing.index.bundles.first(where: { $0.id == bundleId }),
              let installedBundle = store.bundle(bundleId, in: repositoryID),
              offered > installedBundle.version else {
            throw ExtensionInstallError.noUpdateAvailable(bundleId: bundleId)
        }

        // Step 1.
        let script = try await fetchVerifiedScript(for: bundle)

        // Step 2: nothing is touched until every installed Source has passed.
        let staged = try stagedUpdates(from: listing, bundleId: bundleId, repositoryID: repositoryID)

        // Step 3: persist, then reconnect each through the registry.
        let previousScript = store.scriptData(for: bundleId, in: repositoryID)
        let timestamp = now()
        try store.writeScript(script, for: bundleId, in: repositoryID)
        do {
            try persist { snapshot in
                let key = InstalledBundleKey(repositoryID: repositoryID, bundleId: bundleId)
                snapshot.bundles[key] = InstalledBundleRecord(repositoryID: repositoryID,
                                                              bundleId: bundleId,
                                                              version: bundle.version,
                                                              scriptSHA256: bundle.scriptSHA256)
                for item in staged {
                    var record = item.record
                    record.declaration = item.rawDeclaration
                    record.updatedAt = timestamp
                    snapshot.sources[record.qualifiedId] = record
                }
            }
        } catch {
            if let previousScript { try? store.writeScript(previousScript, for: bundleId, in: repositoryID) }
            throw error
        }

        for item in staged {
            do {
                try registry.reinstall(item.declaration)
                // `reinstall` lands on `.registered`; a Source the reader disabled stays
                // disabled through an update.
                if item.record.state == .disabled { try registry.disable(item.record.qualifiedId) }
            } catch let error as SourceLifecycleError {
                throw ExtensionInstallError.lifecycle(error)
            }
            launchRefusals[item.record.qualifiedId] = nil
        }
    }

    private struct StagedUpdate {
        let record: InstalledSourceRecord
        let declaration: SourceDeclaration
        let rawDeclaration: JSONValue
    }

    /// Every installed Source the new bundle lists, validated from raw JSON under its
    /// existing qualified id, then checked against the installed declaration by the
    /// update rule. The first refusal ends the update.
    private func stagedUpdates(from listing: RepositoryListing,
                               bundleId: String,
                               repositoryID: UUID) throws -> [StagedUpdate] {
        var staged: [StagedUpdate] = []
        for record in store.sources(inBundle: bundleId, repositoryID: repositoryID)
        where record.state != .uninstalled {
            guard let entry = listing.entry(localId: record.localId) else { continue }
            let next = try validated(entry.rawDeclaration, localId: record.localId, as: record.qualifiedId)
            if let previous = registry.declaration(for: record.qualifiedId),
               let refusal = updateRule(previous, next) {
                throw ExtensionInstallError.updateRefused(localId: record.localId, refusal)
            }
            staged.append(StagedUpdate(record: record, declaration: next, rawDeclaration: entry.rawDeclaration))
        }
        return staged
    }

    // MARK: Disable / enable / uninstall (§6.5)

    func disable(_ id: QualifiedSourceID) throws {
        try transition(id, to: .disabled) { try registry.disable(id) }
    }

    func enable(_ id: QualifiedSourceID) throws {
        try transition(id, to: .registered) {
            // The registry has no separate "enable": re-registering the declaration it
            // already remembers is the transition, and `validateUpdate` trivially passes.
            guard let declaration = registry.declaration(for: id) else {
                throw SourceLifecycleError.unknownSource
            }
            try registry.reinstall(declaration)
        }
    }

    /// Unregisters; retains the record, storage, WebKit store, Listings and pins (§8.2).
    func uninstall(_ id: QualifiedSourceID) throws {
        try transition(id, to: .uninstalled) { try registry.uninstall(id) }
    }

    private func transition(_ id: QualifiedSourceID,
                            to state: SourceLifecycleRegistry.State,
                            registryMove: () throws -> Void) throws {
        guard var record = store.source(id) else { throw ExtensionInstallError.unknownSource(id) }
        record.state = state
        try persist { $0.sources[id] = record }
        do {
            try registryMove()
        } catch let error as SourceLifecycleError {
            throw ExtensionInstallError.lifecycle(error)
        }
    }

    // MARK: Remove repository (§6.7)

    /// Uninstalls every Source the repository supplied (retaining their data) and marks
    /// the record removed. The record and its UUID persist; the scripts do not.
    func removeRepository(_ repositoryID: UUID) throws {
        var record = try activeRepository(repositoryID)
        let installed = store.sources(in: repositoryID).filter { $0.state != .uninstalled }
        record.state = .removed
        try persist { snapshot in
            snapshot.repositories[repositoryID] = record
            for source in installed {
                var retained = source
                retained.state = .uninstalled
                snapshot.sources[source.qualifiedId] = retained
            }
            for key in snapshot.bundles.keys where key.repositoryID == repositoryID {
                snapshot.bundles[key] = nil
            }
        }
        for source in installed {
            do {
                try registry.uninstall(source.qualifiedId)
            } catch let error as SourceLifecycleError {
                // A Source refused at launch was never registered; uninstalling it is
                // a record change only.
                guard error == .unknownSource else { throw ExtensionInstallError.lifecycle(error) }
            }
        }
        store.deleteScripts(in: repositoryID)
        listings[repositoryID] = nil
    }

    // MARK: Erase data (§6.8)

    /// The reader's explicit data-removal action for one uninstalled Source: erases its
    /// `host.storage` namespace and WebKit store, and deletes the record. Library
    /// references keyed by the id stay where they are.
    func eraseData(for id: QualifiedSourceID) async throws {
        guard let record = store.source(id) else { throw ExtensionInstallError.unknownSource(id) }
        guard record.state == .uninstalled else { throw ExtensionInstallError.sourceStillInstalled(id) }
        try await dataEraser.eraseData(for: id)
        try persist { $0.sources[id] = nil }
        launchRefusals[id] = nil
    }

    /// Erases every retained Source of a removed repository and deletes the repository
    /// record, so a later add of the same URL is a new identity.
    func eraseData(forRepository repositoryID: UUID) async throws {
        guard let record = store.repository(repositoryID) else {
            throw ExtensionInstallError.unknownRepository(repositoryID)
        }
        guard record.state == .removed else { throw ExtensionInstallError.repositoryStillActive(repositoryID) }
        for source in store.sources(in: repositoryID) {
            try await dataEraser.eraseData(for: source.qualifiedId)
            try persist { $0.sources[source.qualifiedId] = nil }
            launchRefusals[source.qualifiedId] = nil
        }
        try persist { $0.repositories[repositoryID] = nil }
    }

    // MARK: Treat as adult (§6.9)

    func treatAsAdult(_ id: QualifiedSourceID) throws {
        try setElevation(.mixed, for: id)
    }

    func clearAdultElevation(_ id: QualifiedSourceID) throws {
        try setElevation(nil, for: id)
    }

    private func setElevation(_ elevation: AdultClassification?, for id: QualifiedSourceID) throws {
        guard var record = store.source(id) else { throw ExtensionInstallError.unknownSource(id) }
        record.localAdultElevation = elevation
        try persist { $0.sources[id] = record }
    }

    /// Effective class = max(declared, local elevation) (design §7.2). `nil` when the
    /// declared class is unknown — a Source refused at launch has no validated
    /// declaration to read it from — never `none`.
    func effectiveAdultClassification(for id: QualifiedSourceID) -> AdultClassification? {
        guard let declared = registry.declaration(for: id)?.adult else { return nil }
        guard let elevation = store.source(id)?.localAdultElevation else { return declared }
        return Self.rank(declared) >= Self.rank(elevation) ? declared : elevation
    }

    private static func rank(_ classification: AdultClassification) -> Int {
        switch classification {
        case .none: return 0
        case .mixed: return 1
        case .adultOnly: return 2
        }
    }

    // MARK: - Internals

    private func activeRepository(_ id: UUID) throws -> RepositoryRecord {
        guard let record = store.repository(id) else { throw ExtensionInstallError.unknownRepository(id) }
        guard record.state == .active else { throw ExtensionInstallError.repositoryRemoved(id) }
        return record
    }

    /// The declaration-level tier of index validation (design §4), under this
    /// repository's identity: each served record is validated with the qualified id
    /// minted for it, and a record it refuses is reported with the validator's own error
    /// and does not affect its neighbours. The one whole-index rule applied here is the
    /// one only the minter can apply — two records that would mint the same qualified id.
    private func makeListing(_ index: RepositoryIndex, repositoryID: UUID) throws -> RepositoryListing {
        var entries: [RepositoryListing.Entry] = []
        var seen: [String: String] = [:]
        for (bundleIndex, bundle) in index.bundles.enumerated() {
            for (sourceIndex, served) in bundle.sources.enumerated() {
                let path = "bundles[\(bundleIndex)].sources[\(sourceIndex)]"
                let raw = served.rawJSON
                let localId = raw.objectValue?["localId"]?.stringValue
                if let localId {
                    if let first = seen[localId] {
                        throw ExtensionInstallError.qualifiedIDCollision(localId: localId,
                                                                          first: first,
                                                                          second: path)
                    }
                    seen[localId] = path
                }
                let outcome: Result<SourceDeclaration, SourceDeclarationError>
                if let localId {
                    outcome = SourceDeclarationValidator.validate(
                        json: raw,
                        qualifiedId: Self.qualifiedID(repositoryID: repositoryID, localId: localId),
                        hostAPI: hostAPI)
                } else if raw.objectValue?["localId"] == nil {
                    outcome = .failure(.missingKey(path: "localId"))
                } else {
                    outcome = .failure(.wrongType(path: "localId", expected: "string"))
                }
                entries.append(RepositoryListing.Entry(bundleId: bundle.id,
                                                       bundleVersion: bundle.version,
                                                       path: path,
                                                       localId: localId,
                                                       rawDeclaration: raw,
                                                       outcome: outcome))
            }
        }

        var availableUpdates: [String: Int] = [:]
        var noLongerListed: [QualifiedSourceID] = []
        for record in store.sources(in: repositoryID) where record.state != .uninstalled {
            guard let entry = entries.first(where: { $0.localId == record.localId }) else {
                noLongerListed.append(record.qualifiedId)
                continue
            }
            if let installed = store.bundle(record.bundleId, in: repositoryID),
               entry.bundleVersion > installed.version {
                availableUpdates[entry.bundleId] = entry.bundleVersion
            }
        }
        return RepositoryListing(index: index,
                                 entries: entries,
                                 availableUpdates: availableUpdates,
                                 noLongerListed: noLongerListed)
    }

    private func validated(_ raw: JSONValue,
                           localId: String,
                           as qualifiedId: QualifiedSourceID) throws -> SourceDeclaration {
        switch SourceDeclarationValidator.validate(json: raw, qualifiedId: qualifiedId, hostAPI: hostAPI) {
        case .success(let declaration):
            return declaration
        case .failure(let error):
            throw ExtensionInstallError.declarationRejected(localId: localId, error)
        }
    }

    private func fetchVerifiedScript(for bundle: RepositoryBundle) async throws -> Data {
        let script = try await transport.fetchScript(at: bundle.scriptURL)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        guard digest == bundle.scriptSHA256 else {
            throw ExtensionInstallError.scriptDigestMismatch(expected: bundle.scriptSHA256, actual: digest)
        }
        return script
    }

    private func persist(_ mutate: (inout RepositoryStore.Snapshot) throws -> Void) throws {
        do {
            try store.commit(mutate)
        } catch let error as RepositoryStore.StoreError {
            if case .write(let reason) = error { throw ExtensionInstallError.persistence(reason) }
            throw error
        }
    }
}
