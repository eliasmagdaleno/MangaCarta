//
//  SearchView.swift
//  MangaCarta
//

import SwiftUI

/// The same two-step as `HomeView`, for the same reason: a `@StateObject` built in `init`
/// cannot see the environment, so the registry is read here and passed down as a value.
struct SearchView: View {
    @EnvironmentObject private var registry: SourceRegistry

    var body: some View {
        SearchScreen(registry: registry)
    }
}

private struct SearchScreen: View {
    @StateObject private var vm: SearchViewModel
    @ObservedObject private var registry: SourceRegistry

    init(registry: SourceRegistry) {
        _registry = ObservedObject(wrappedValue: registry)
        _vm = StateObject(wrappedValue: SearchViewModel(registry: registry))
    }

    @AppStorage("settings.showAdultSources") private var showAdultSources = false
    @Environment(\.selectAppTab) private var selectAppTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""

    var body: some View {
        NavigationStack {
            if let source = vm.source {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Gutter.section) {
                    // Search source picker — same chip bar as Home, but it only
                    // scopes search and never changes the app-wide active source.
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Search source · only affects these results", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.footnote)
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, Gutter.page)

                        SourceChipBar(
                            sources: registry.visibleSources(includeAdult: showAdultSources),
                            activeID: vm.selectedSourceID ?? registry.activeSourceID,
                            accessibilityVerb: "Search"
                        ) { id in
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                vm.selectSource(id: id)
                            }
                        }
                    }

                    SearchResults(
                        loader: vm.loader,
                        hasSearched: vm.hasSearched,
                        sourceName: source.name,
                        onRetry: { vm.retry() }
                    )
                }
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(Ink.background)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search titles")
            .onChange(of: query) { _, newValue in
                vm.queryChanged(newValue)
            }
            .onChange(of: showAdultSources) { _, newValue in
                // If the source being searched just got hidden, fall back to the
                // app's active (non-adult) source.
                let visible = registry.visibleSources(includeAdult: newValue)
                let current = vm.selectedSourceID ?? registry.activeSourceID
                if !visible.contains(where: { $0.id == current }) {
                    vm.selectSource(id: registry.activeSourceID)
                }
            }
            } else {
                InkEmptyState(
                    symbol: "books.vertical",
                    title: "No sources installed",
                    message: "Add a repository you trust in Settings to install Sources. MangaCarta does not provide or host content.",
                    actionTitle: "Open Settings",
                    action: { selectAppTab(.settings) }
                )
            }
        }
    }
}

/// The state-dependent body below the source picker: idle prompt, spinner,
/// error notice, empty result, or the paged results grid. Observes the loader
/// directly so it re-renders as pages arrive.
private struct SearchResults: View {
    @ObservedObject var loader: PagedMangaLoader
    let hasSearched: Bool
    let sourceName: String
    let onRetry: () -> Void

    var body: some View {
        if !hasSearched {
            emptyState(
                title: "Search \(sourceName)",
                message: "Find manga by title. Results come from the source selected above."
            )
        } else if let error = loader.errorMessage, loader.items.isEmpty {
            VStack(spacing: 14) {
                InkNotice(error)
                Button("Try again", action: onRetry)
                    .font(.inkMono(12, weight: .semibold))
                    .foregroundStyle(Ink.seal)
            }
            .padding(.horizontal, Gutter.page)
        } else if loader.items.isEmpty && loader.isLoading {
            InkLoading("Searching \(sourceName)")
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if loader.items.isEmpty {
            emptyState(
                title: "No results",
                message: "No titles matched your search on \(sourceName)."
            )
        } else {
            PagedMangaGrid(loader: loader)
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        InkEmptyState(symbol: "magnifyingglass", title: title, message: message)
            .frame(minHeight: 360)
    }
}

#Preview {
    SearchView()
        .environmentObject(SourceRegistry.shared)
}
