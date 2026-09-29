//
//  CachedAsyncImage.swift
//  MangaCarta
//
//  A drop-in replacement for `AsyncImage(url:content:)` that resolves through
//  `ImageCache` (memory → disk → network) instead of re-fetching every time the
//  view appears. It hands the same `AsyncImagePhase` to its content closure, so
//  existing `switch phase { … }` call sites work unchanged.
//
//  Retry is driven the same way as before: the reader recreates this view via
//  `.id(reloadToken)`, which resets `phase` and re-runs the load.
//

import SwiftUI

private struct ImageCacheEnvironmentKey: EnvironmentKey {
    /// Previews only. The app injects `AppComposition.imageCache`, whose reporter the
    /// shared instance lacks, so a view that fell back here would never report.
    static let defaultValue: ImageCache = .shared
}

extension EnvironmentValues {
    var imageCache: ImageCache {
        get { self[ImageCacheEnvironmentKey.self] }
        set { self[ImageCacheEnvironmentKey.self] = newValue }
    }
}

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @Environment(\.imageCache) private var imageCache
    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let image = await imageCache.loadImage(for: url) {
            phase = .success(Image(uiImage: image))
        } else {
            phase = .failure(URLError(.cannotDecodeContentData))
        }
    }
}
