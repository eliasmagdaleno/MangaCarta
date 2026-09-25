//
//  ExtensionSourceRegistrar.swift
//  MangaCarta
//
//  Mirrors the installed set into `SourceRegistry`. `SourceLifecycleRegistry` knows
//  which qualified ids are registered and with what declaration; `RepositoryStore`
//  holds each bundle's script bytes and the reader's "Treat as adult" elevation; the
//  app browses and reads through `SourceRegistry`. This type is the one place that
//  reads the first two and writes the third, so "registration changing at runtime
//  reaches the picker, fulfillment ranking and adult gating" is true by construction:
//  they all read `SourceRegistry.sources`, and this rewrites it on every change.
//
//  It owns no lifecycle state. `sync()` is a pure function of the two stores it reads
//  — run it twice and the second run changes nothing — and the only thing it keeps is
//  the `ExtensionSource` instances it built, so an unchanged Source keeps its identity
//  (and its cursor memory) across an unrelated lifecycle event.
//

import Combine
import Foundation
import UIKit

@MainActor
final class ExtensionSourceRegistrar {

    private let store: RepositoryStore
    private let lifecycle: SourceLifecycleRegistry
    private let host: any ExtensionSourceHosting
    private let registry: SourceRegistry

    private var built: [QualifiedSourceID: ExtensionSource] = [:]
    private var subscription: AnyCancellable?

    init(store: RepositoryStore,
         lifecycle: SourceLifecycleRegistry,
         host: any ExtensionSourceHosting,
         registry: SourceRegistry) {
        self.store = store
        self.lifecycle = lifecycle
        self.host = host
        self.registry = registry

        // Two triggers, because two stores change independently: every lifecycle
        // transition (install, disable, uninstall, reinstall, a launch restore), and
        // every persisted record change — an update's new script, or an adult
        // elevation, neither of which moves the lifecycle registry. `@Published` emits
        // before the property is set, so the emitted snapshot is the one read here.
        lifecycle.didChange = { [weak self] in
            guard let self else { return }
            self.sync(self.store.snapshot)
        }
        subscription = store.$snapshot
            .dropFirst()
            .sink { [weak self] snapshot in self?.sync(snapshot) }
        sync(store.snapshot)
    }

    /// Rebuilds the installed set from what is registered right now. Registration
    /// order is install order, oldest first, so the ranking's last tiebreak (ADR-0004)
    /// is stable across launches.
    func sync(_ snapshot: RepositoryStore.Snapshot) {
        // The lifecycle registry is intentionally in-memory. Retained records (notably
        // uninstalled Sources, and Sources refused during launch validation) therefore
        // still need to contribute their qualified ids from the persisted snapshot, or
        // historical Listings will fall back to the active Source after a relaunch.
        let persistedSourceIDs = Set(snapshot.sources.keys.map(\.rawValue))
        registry.setKnownSourceIDs(persistedSourceIDs.union(lifecycle.knownSourceIDs))
        var next: [QualifiedSourceID: ExtensionSource] = [:]
        var sources: [ExtensionSource] = []
        let records = snapshot.sources.values.sorted {
            ($0.installedAt, $0.qualifiedId.rawValue) < ($1.installedAt, $1.qualifiedId.rawValue)
        }
        for record in records where lifecycle.isActive(record.qualifiedId) {
            // A registered id always has a declaration; a bundle whose script is missing
            // from disk cannot run and is left out rather than registered broken.
            guard let declaration = lifecycle.declaration(for: record.qualifiedId),
                  let data = store.scriptData(for: record.bundleId, in: record.repositoryID),
                  let script = String(data: data, encoding: .utf8) else { continue }
            // Effective class = max(declared, local elevation) (design §7.2). The
            // elevation is only ever `mixed`, so any elevation at all means adult.
            let isNSFW = declaration.adult != .none || record.localAdultElevation != nil
            let source: ExtensionSource
            if let existing = built[record.qualifiedId],
               existing.declaration == declaration,
               existing.script == script,
               existing.isNSFW == isNSFW {
                source = existing
            } else {
                source = ExtensionSource(declaration: declaration, script: script, isNSFW: isNSFW,
                                         lifecycle: lifecycle, host: host)
            }
            next[record.qualifiedId] = source
            sources.append(source)
        }
        built = next
        registry.setInstalledSources(sources)
    }
}

// MARK: - The production host

/// `ExtensionHostCapabilityFactory` already builds the four typed capabilities per
/// invocation; installing them at `context.host` is a matter of wrapping each in its
/// JavaScript adapter. The invocation context is the app's real state: a background
/// invocation must never present a browser challenge (ADR-0003 Amendment 3), and the
/// only thing that knows whether this is one is `UIApplication`.
extension ExtensionHostCapabilityFactory: ExtensionSourceHosting {
    func capabilities(for declaration: SourceDeclaration,
                      operation: SourceOperation,
                      invocationID: UUID) -> [ExtensionHostCapability] {
        let context: HostInvocationContext =
            UIApplication.shared.applicationState == .background ? .background : .foreground
        let typed = capabilities(for: declaration,
                                 operation: operation,
                                 invocationID: invocationID,
                                 context: context)
        return [HostHTTPJSCapability(client: typed.http),
                HostBrowserJSCapability(extractor: MainActorBrowserExtractor(capability: typed.browser)),
                HostStorageJSCapability(storage: typed.storage),
                HostLogJSCapability(logger: typed.log)]
    }
}
