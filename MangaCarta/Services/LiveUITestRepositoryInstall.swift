//
//  LiveUITestRepositoryInstall.swift
//  MangaCarta
//
//  `-uitest-install-repository <index URL>` for the live UI tests in `MangaCartaUITests.swift`.
//  No remote Source ships in the app (ADR-0003 Amendment 6), so a live test that browses
//  MangaDex or WeebCentral has to install one first, and it does so through the same
//  installer a reader's "Add repository" uses.
//

#if DEBUG
import Foundation

@MainActor
enum LiveUITestRepositoryInstall {
    static let flag = "-uitest-install-repository"

    static var requestedURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(string: arguments[index + 1])
    }

    /// The `-uitest-source` value, when it names a Source by its `localId` (`mangadex`)
    /// rather than by the qualified id an install mints.
    private static var requestedLocalID: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uitest-source"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Installs every Source the repository lists that is not installed yet, then makes the
    /// `-uitest-source` one active.
    ///
    /// **Idempotent by URL.** An active repository at `url` is refreshed, never added again:
    /// a second add would mint a new repository UUID, and every Listing the reader had
    /// reconnected to the first one would stop resolving. A removed record at `url` is
    /// reconnected under its old UUID, which is `addRepository`'s default.
    ///
    /// Adult acknowledgement is answered yes for the duration, and adult Sources are made
    /// visible: MangaDex declares `mixed`, and a hidden Source is one no test can browse.
    static func run(url: URL,
                    extensions: AppComposition.ExtensionComposition,
                    registry: SourceRegistry,
                    defaults: UserDefaults = .standard) async {
        let installer = extensions.installer
        let repositoryID: UUID
        do {
            if let existing = extensions.repositories.repository(at: url), existing.state == .active {
                repositoryID = existing.id
                // Before the network: a test that searches at once must not search another Source.
                selectRequestedSource(in: repositoryID, registry: registry)
                _ = try await installer.refresh(repositoryID)
            } else {
                repositoryID = try await installer.addRepository(at: url).id
            }
        } catch {
            NSLog("[uitest] repository at %@ could not be added: %@", url.absoluteString, "\(error)")
            return
        }

        defaults.set(true, forKey: RepositorySettingsViewModel.declaredAgeKey)
        defaults.set(true, forKey: RepositorySettingsViewModel.showAdultSourcesKey)
        let previous = extensions.adultAcknowledgement.present
        extensions.adultAcknowledgement.present = { _ in true }
        defer { extensions.adultAcknowledgement.present = previous }

        for localId in (installer.listings[repositoryID]?.entries ?? []).compactMap(\.localId) {
            let id = ExtensionInstaller.qualifiedID(repositoryID: repositoryID, localId: localId)
            if let record = extensions.repositories.source(id), record.state != .uninstalled { continue }
            do {
                _ = try await installer.install(localId: localId, from: repositoryID)
            } catch {
                NSLog("[uitest] %@ could not be installed: %@", localId, "\(error)")
            }
        }

        selectRequestedSource(in: repositoryID, registry: registry)
    }

    private static func selectRequestedSource(in repositoryID: UUID, registry: SourceRegistry) {
        guard let localId = requestedLocalID, registry.source(id: localId) == nil else { return }
        let id = ExtensionInstaller.qualifiedID(repositoryID: repositoryID, localId: localId).rawValue
        if registry.source(id: id) != nil, registry.activeSourceID != id { registry.activeSourceID = id }
    }
}
#endif
