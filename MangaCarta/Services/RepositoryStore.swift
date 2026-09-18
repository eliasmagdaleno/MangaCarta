//
//  RepositoryStore.swift
//  MangaCarta
//
//  What the installer persists — the three records the repository format design's "What
//  the installer persists" section names, plus each installed bundle's script as a file.
//  One JSON file under Application Support, `repositories.json`, written atomically the
//  way `UpdateStateStore` writes `updates.json`; script bytes live beside it under
//  `extension-scripts/<repository UUID>/<bundle id>.js`, so two installed Sources from one
//  bundle share one copy.
//
//  Two things this store is deliberately not:
//
//  * It is not the lifecycle. `SourceLifecycleRegistry` owns registered / disabled /
//    uninstalled and the `validateUpdate` rule; this file only remembers the resulting
//    state across launches. The installer (`ExtensionInstaller`) is what drives both.
//  * It is not debounced. `UpdateStateStore` coalesces a burst of chapter checks; an
//    install is rare and the design's "Operations" section makes each one atomic — on any
//    failure nothing the reader can observe changes — so every mutation here is one
//    `commit` that writes the file first and publishes the new state only if the write
//    succeeded. A failed write leaves memory and disk both as they were.
//
//  Retention (design §8.2): uninstall and repository removal keep the installed-Source
//  record so the qualified-id binding survives; only the reader's explicit erase deletes
//  one. That policy is the installer's; this store just has no code path that removes a
//  record as a side effect of anything else.
//

import Foundation

// MARK: - Records

/// The repository record. `id` is minted by the installer at first add and never derived
/// from anything a maintainer controls (ADR-0003 Amendment 4, decision 2).
struct RepositoryRecord: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case active
        /// Removed by the reader, record retained so a later add of the same URL can
        /// reconnect (design §5.3). Only "Erase data" deletes the record itself.
        case removed
    }

    let id: UUID
    var indexURL: URL
    /// As last seen in the index. Display text, not identity.
    var name: String
    let addedAt: Date
    var lastRefreshedAt: Date?
    var state: State
    /// Of the last accepted index.
    var format: Int
    /// Reserved for the signed format (design §5.4). Format 1 never sets it; it exists so
    /// the key binds to an identity that already exists rather than replacing one.
    var boundKey: String?
}

/// One installed bundle: the script file's version and digest. The bytes are on disk.
struct InstalledBundleRecord: Codable, Equatable, Sendable {
    let repositoryID: UUID
    let bundleId: String
    var version: Int
    var scriptSHA256: String
}

/// One installed Source. The declaration is kept **raw, as served** — never the typed
/// value — and re-validated at every launch (ADR-0003 Amendment 4, decision 4).
struct InstalledSourceRecord: Codable, Equatable, Sendable {
    let qualifiedId: QualifiedSourceID
    let repositoryID: UUID
    let localId: String
    var bundleId: String
    var declaration: JSONValue
    var state: SourceLifecycleRegistry.State
    /// The reader's "Treat as adult" (design §6.9, §7.2): only ever `.mixed`, only ever
    /// set by the reader, never lowered by an update. `nil` means the reader has set
    /// nothing, and the declared class alone applies.
    var localAdultElevation: AdultClassification?
    let installedAt: Date
    var updatedAt: Date
}

/// Identifies an installed bundle: bundle ids are unique only within a repository.
struct InstalledBundleKey: Hashable, Sendable {
    let repositoryID: UUID
    let bundleId: String
}

// MARK: - Store

@MainActor
final class RepositoryStore: ObservableObject {

    /// Everything persisted, as one value, so a mutation can be staged, written, and only
    /// then published.
    struct Snapshot: Equatable {
        var repositories: [UUID: RepositoryRecord] = [:]
        var bundles: [InstalledBundleKey: InstalledBundleRecord] = [:]
        var sources: [QualifiedSourceID: InstalledSourceRecord] = [:]
    }

    enum StoreError: Error, Equatable {
        case write(String)
        case unreadable
    }

    @Published private(set) var snapshot = Snapshot()

    private let directory: URL
    private var loaded = false
    private var loadError: StoreError?

    private var fileURL: URL { directory.appendingPathComponent("repositories.json") }
    private var scriptsDirectory: URL {
        directory.appendingPathComponent("extension-scripts", isDirectory: true)
    }

    init(directory: URL = WorkStore.applicationSupportDirectory()) {
        self.directory = directory
        try? loadIfNeeded()
    }

    // MARK: Lookup

    var repositories: [RepositoryRecord] { Array(snapshot.repositories.values) }

    func repository(_ id: UUID) -> RepositoryRecord? {
        snapshot.repositories[id]
    }

    /// Any record — active or removed — whose stored URL is `url`. Used by "Add" to offer
    /// the reconnect the design's identity table describes for a removed repository.
    func repository(at url: URL) -> RepositoryRecord? {
        snapshot.repositories.values.first { $0.indexURL == url }
    }

    func bundle(_ bundleId: String, in repositoryID: UUID) -> InstalledBundleRecord? {
        snapshot.bundles[InstalledBundleKey(repositoryID: repositoryID, bundleId: bundleId)]
    }

    func source(_ id: QualifiedSourceID) -> InstalledSourceRecord? {
        snapshot.sources[id]
    }

    /// Every installed-Source record a repository supplied, in a stable order, including
    /// uninstalled ones — those are retained records, not absent ones.
    func sources(in repositoryID: UUID) -> [InstalledSourceRecord] {
        snapshot.sources.values
            .filter { $0.repositoryID == repositoryID }
            .sorted { $0.localId < $1.localId }
    }

    func sources(inBundle bundleId: String, repositoryID: UUID) -> [InstalledSourceRecord] {
        sources(in: repositoryID).filter { $0.bundleId == bundleId }
    }

    // MARK: Mutation

    /// Applies `mutate` to a copy of the snapshot, writes the copy, and publishes it only
    /// if the write succeeded. A thrown error from `mutate` or from the write leaves both
    /// memory and disk untouched.
    func commit(_ mutate: (inout Snapshot) throws -> Void) throws {
        try loadIfNeeded()
        var staged = snapshot
        try mutate(&staged)
        try write(staged)
        snapshot = staged
    }

    // MARK: Script files

    func scriptFileURL(for bundleId: String, in repositoryID: UUID) -> URL {
        scriptsDirectory
            .appendingPathComponent(repositoryID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("\(bundleId).js", isDirectory: false)
    }

    func scriptData(for bundleId: String, in repositoryID: UUID) -> Data? {
        try? Data(contentsOf: scriptFileURL(for: bundleId, in: repositoryID))
    }

    /// Writes a script where its bundle record will point. A script file with no record
    /// is invisible to the reader, which is why the installer writes it *before* the
    /// record and deletes it again if the record's commit fails.
    func writeScript(_ data: Data, for bundleId: String, in repositoryID: UUID) throws {
        let url = scriptFileURL(for: bundleId, in: repositoryID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.write("The engine script could not be saved: \(error.localizedDescription)")
        }
    }

    func deleteScript(for bundleId: String, in repositoryID: UUID) {
        try? FileManager.default.removeItem(at: scriptFileURL(for: bundleId, in: repositoryID))
    }

    /// Removes every script a repository holds. Scripts are re-fetchable and are not the
    /// reader's data, so this is what repository removal does to them.
    func deleteScripts(in repositoryID: UUID) {
        let folder = scriptsDirectory.appendingPathComponent(repositoryID.uuidString.lowercased(),
                                                             isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Persistence

    private func write(_ staged: Snapshot) throws {
        let payload = RepositoryStorePersisted(
            repositories: staged.repositories.values.sorted { $0.addedAt < $1.addedAt },
            bundles: staged.bundles.values.sorted { ($0.repositoryID.uuidString, $0.bundleId)
                < ($1.repositoryID.uuidString, $1.bundleId) },
            sources: staged.sources.values.sorted { $0.qualifiedId.rawValue < $1.qualifiedId.rawValue }
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            throw StoreError.write("The repository list could not be saved: \(error.localizedDescription)")
        }
    }

    func loadIfNeeded() throws {
        if let loadError { throw loadError }
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let payload: RepositoryStorePersisted
        do {
            payload = try JSONDecoder().decode(RepositoryStorePersisted.self, from: data)
        } catch {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let corruptURL = directory.appendingPathComponent("repositories.json.corrupt-\(timestamp)")
            do {
                try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            } catch {
                // Keep the original in place when quarantine itself fails; either way,
                // the unreadable state prevents a later commit from overwriting it.
            }
            loadError = .unreadable
            throw StoreError.unreadable
        }
        var loadedSnapshot = Snapshot()
        for record in payload.repositories { loadedSnapshot.repositories[record.id] = record }
        for record in payload.bundles {
            loadedSnapshot.bundles[InstalledBundleKey(repositoryID: record.repositoryID,
                                                      bundleId: record.bundleId)] = record
        }
        for record in payload.sources { loadedSnapshot.sources[record.qualifiedId] = record }
        snapshot = loadedSnapshot
    }
}

private struct RepositoryStorePersisted: Codable {
    let repositories: [RepositoryRecord]
    let bundles: [InstalledBundleRecord]
    let sources: [InstalledSourceRecord]
}
