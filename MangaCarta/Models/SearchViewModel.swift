//
//  SearchViewModel.swift
//  MangaCarta
//
//  Drives the Search tab: a debounced, source-scoped title search whose results
//  page through a shared `PagedMangaLoader`. Source resolution mirrors
//  `HomeViewModel` (read-time via the registry) so switching the searched source
//  re-sources results without recreating the view model.
//

import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    /// Owns results / pagination / loading state; the view observes it directly.
    let loader: PagedMangaLoader

    /// The source to search; nil follows the registry's active source.
    @Published var selectedSourceID: String? = nil
    /// True once a non-empty query has been submitted — distinguishes the idle
    /// prompt from a genuine "no results".
    @Published private(set) var hasSearched = false

    /// Where `source` comes from. Mirrors `HomeViewModel.SourceBinding`, and for the same
    /// reason: a singleton fallback is silently wrong whenever the graph was built with an
    /// injected registry.
    private enum SourceBinding {
        /// A fixed source, injected by a test.
        case fixed(MangaSource)
        /// The graph's registry, read at access time.
        case registry(SourceRegistry)
    }

    private let binding: SourceBinding
    private let debounce: Duration
    private var debounceTask: Task<Void, Never>?
    private var lastQuery = ""

    /// A fixed source. Tests use this; nothing in the app does.
    convenience init(source: MangaSource,
                     debounce: Duration = .milliseconds(350),
                     pageSize: Int = 24) {
        self.init(binding: .fixed(source), debounce: debounce, pageSize: pageSize)
    }

    /// The graph's registry, handed over from the environment by `SearchView`. See
    /// `HomeViewModel.init(registry:)` for why the singleton is not an acceptable default.
    convenience init(registry: SourceRegistry,
                     debounce: Duration = .milliseconds(350),
                     pageSize: Int = 24) {
        self.init(binding: .registry(registry), debounce: debounce, pageSize: pageSize)
    }

    private init(binding: SourceBinding, debounce: Duration, pageSize: Int) {
        self.binding = binding
        self.debounce = debounce
        self.loader = PagedMangaLoader(pageSize: pageSize)
    }

    /// The source these results come from — resolved at read time so a chip switch
    /// or a Settings source change is reflected on the next search.
    var source: MangaSource? {
        switch binding {
        case .fixed(let source):
            return source
        case .registry(let registry):
            return selectedSourceID.flatMap { registry.source(id: $0) } ?? registry.active
        }
    }

    /// Called on every keystroke from `.searchable`. Debounces, then searches.
    func queryChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = trimmed
        debounceTask?.cancel()

        guard !trimmed.isEmpty else {
            hasSearched = false
            loader.reset()
            return
        }

        debounceTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.runSearch(trimmed)
        }
    }

    /// Switch the searched source and immediately re-run the current query.
    func selectSource(id: String) {
        guard id != selectedSourceID else { return }
        selectedSourceID = id
        debounceTask?.cancel()
        if lastQuery.isEmpty {
            loader.reset()
            hasSearched = false
        } else {
            runSearch(lastQuery)
        }
    }

    /// Re-run the last query (e.g. after an error).
    func retry() {
        guard !lastQuery.isEmpty else { return }
        runSearch(lastQuery)
    }

    private func runSearch(_ query: String) {
        hasSearched = true
        // Capture the source as a value so the escaping fetch closure doesn't
        // reach back into main-actor state, and so a later source switch can't
        // change which source this in-flight page belongs to.
        guard let source = self.source else { return }
        loader.load { limit, offset in
            try await source.search(title: query, limit: limit, offset: offset)
        }
    }
}
