//
//  HomeViewModel.swift
//  MangaCarta
//
//  Created by Elias Magdaleno on 10/8/25.
//

import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var popular: [Manga] = []
    @Published var latestUpdates: [MangaUpdate] = []
    @Published var newTitles: [Manga] = []

    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    /// Where `source` comes from. Two cases rather than an optional registry with a
    /// singleton fallback: the fallback was silently wrong whenever the graph was built
    /// with an injected registry, and it will get worse once sources are installable.
    private enum SourceBinding {
        /// A fixed source, injected by a test.
        case fixed(MangaSource)
        /// The graph's registry, read at access time.
        case registry(SourceRegistry)
    }

    private let binding: SourceBinding

    /// The source these browse feeds come from — resolved at read time so a Settings
    /// switch re-sources Home without an app relaunch.
    var source: MangaSource {
        switch binding {
        case .fixed(let source): return source
        case .registry(let registry): return registry.active
        }
    }
    /// The source id the current feed arrays were loaded from (nil before first load).
    private var loadedSourceID: String?
    /// The in-flight full-home load. Superseded loads are cancelled so a slow fetch from
    /// a previously-active source can never clobber the rails after a source switch.
    private var loadTask: Task<Void, Never>?

    /// A fixed source. Tests use this; nothing in the app does.
    init(source: MangaSource) {
        self.binding = .fixed(source)
    }

    /// The graph's registry — the one `AppComposition` was built with, which the view
    /// hands over from the environment. It is `SourceRegistry.shared` in production and a
    /// different object under a UI-test fixture, and reading the singleton instead is the
    /// bug this initializer exists to make impossible.
    init(registry: SourceRegistry) {
#if DEBUG
        if UpdatesUITestFixture.state != nil {
            self.binding = .fixed(UpdatesUITestSource())
            return
        }
#endif
        self.binding = .registry(registry)
    }

    func loadHome() {
        // Clear stale feeds when the active source changed since the last load, so the
        // previous source's rails don't linger while the new one fetches.
        let activeID = source.id
        if let loaded = loadedSourceID, loaded != activeID {
            popular = []; latestUpdates = []; newTitles = []
            errorMessage = nil
        }
        loadedSourceID = activeID
        loadTask?.cancel()
        loadTask = Task {
            await loadHomeAsync()
        }
    }

    func refresh() {
        loadHome()
    }

    private func loadHomeAsync() async {
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let popularTask: [Manga] = source.homeFeedCapabilities.contains(.popular)
                ? source.popular(limit: 20, offset: 0) : []
            async let updatesTask: [MangaUpdate] = source.homeFeedCapabilities.contains(.latestUpdates)
                ? source.latestUpdates(limitTitles: 20, language: "en") : []
            async let newTitlesTask: [Manga] = source.homeFeedCapabilities.contains(.newTitles)
                ? source.newTitles(limit: 20, offset: 0) : []

            let popular = try await popularTask
            let updates = try await updatesTask
            let newTitles = try await newTitlesTask
            // A superseded load must never write: a newer loadHome() owns the state now.
            guard !Task.isCancelled else { return }
            self.popular = popular
            self.latestUpdates = updates
            self.newTitles = newTitles
        } catch is CancellationError {
            // Superseded, not failed — don't surface cancellation as an error.
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.errorMessage = error.localizedDescription
        }
        if !Task.isCancelled { isLoading = false }
    }

    func reloadPopular(limit: Int = 20, offset: Int = 0) {
        let expectedID = source.id
        Task {
            do {
                let items = try await source.popular(limit: limit, offset: offset)
                guard self.source.id == expectedID else { return }
                self.popular = items
            } catch is CancellationError {
            } catch {
                guard self.source.id == expectedID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func reloadLatestUpdates(limit: Int = 20, lang: String = "en") {
        let expectedID = source.id
        Task {
            do {
                let items = try await source.latestUpdates(limitTitles: limit, language: lang)
                guard self.source.id == expectedID else { return }
                self.latestUpdates = items
            } catch is CancellationError {
            } catch {
                guard self.source.id == expectedID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func reloadNewTitles(limit: Int = 20, offset: Int = 0) {
        let expectedID = source.id
        Task {
            do {
                let items = try await source.newTitles(limit: limit, offset: offset)
                guard self.source.id == expectedID else { return }
                self.newTitles = items
            } catch is CancellationError {
            } catch {
                guard self.source.id == expectedID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

}
