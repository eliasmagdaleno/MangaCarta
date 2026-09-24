//
//  MoreLikeThisViewModel.swift
//  MangaCarta
//
//  Backs the detail-page "More Like This" rail. Loads once per manga via
//  MoreLikeThisProvider; publishes the resolved MangaDex titles for MangaRail. Empty
//  `items` means "no rail" — the view hides the section (graceful, like the For You rail).
//

import SwiftUI

@MainActor
final class MoreLikeThisViewModel: ObservableObject {
    @Published private(set) var items: [Manga] = []
    @Published private(set) var isLoading = false

    private let provider: MoreLikeThisProvider
    private var loadedFor: String?

    // `provider` is built in the (main-actor-isolated) init body rather than as a default
    // argument: default args evaluate in a nonisolated context and can't call the
    // @MainActor `MoreLikeThisProvider` initializer. Production passes the graph registry;
    // tests may pass a provider explicitly.
    init(registry: SourceRegistry, provider: MoreLikeThisProvider? = nil) {
        self.provider = provider ?? MoreLikeThisProvider(
            source: { registry.externalIdSource })
    }

    /// Idempotent per manga id: loads recommendations once for a given manga. Safe to
    /// call from `.task` on every appear — a repeat call for the same manga is a no-op.
    func load(for manga: Manga) async {
        guard loadedFor != manga.id else { return }
        loadedFor = manga.id
        isLoading = true
        defer { isLoading = false }
        items = await provider.recommendations(for: manga)
    }
}
