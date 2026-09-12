//
//  InstalledSourceDataEraser.swift
//  MangaCarta
//
//  The production `SourceDataErasing`: what "Erase data" (repository format design §6.8)
//  removes for one qualified id — the `host.storage` namespace, through the repository's
//  own host-only administrative operation, and the per-Source WebKit data store
//  (`WKWebsiteDataStore.remove(forIdentifier:)`, ADR-0003 Amendment 3). Kept apart from
//  `ExtensionInstaller` so the installer's file names nothing from WebKit.
//

import Foundation

struct InstalledSourceDataEraser: SourceDataErasing {
    private let storage: HostStorageRepository

    init(storage: HostStorageRepository) {
        self.storage = storage
    }

    func eraseData(for id: QualifiedSourceID) async throws {
        try await storage.eraseUserData(for: id)
        await ExtensionBrowserStore.removeData(for: id)
    }
}
