//
//  HomeView.swift
//  MangaCarta
//

import SwiftUI

/// Home, minus one thing it cannot do for itself: a `@StateObject` is built in `init`,
/// which runs before the environment exists, so `HomeScreen` below cannot read the graph's
/// registry there. This wrapper reads it — in a `body`, where the environment does exist —
/// and hands it over as a plain argument. Without it the view model could only reach
/// `SourceRegistry.shared`, which is the graph's registry in production and a different
/// object under a UI-test fixture.
struct HomeView: View {
    @EnvironmentObject private var registry: SourceRegistry

    var body: some View {
        HomeScreen(registry: registry)
    }
}

struct UnavailableSourceView: View {
    var body: some View {
        InkEmptyState(symbol: "externaldrive.badge.xmark", title: "Source unavailable",
                      message: "This title's Source is not installed. Add its repository in Settings to read it.",
                      actionTitle: "Open Settings", action: {})
    }
}

private struct HomeScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var vm: HomeViewModel
    @ObservedObject private var registry: SourceRegistry

    init(registry: SourceRegistry) {
        _registry = ObservedObject(wrappedValue: registry)
        _vm = StateObject(wrappedValue: HomeViewModel(registry: registry))
    }

    @EnvironmentObject private var engine: RecommendationEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var works: WorkStore
    @EnvironmentObject private var updates: UpdateStateStore
    @Environment(\.selectAppTab) private var selectAppTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("settings.showAdultSources") private var showAdultSources = false

    var body: some View {
        // Capture the browse source as a value so the escaping "See all" fetch closures
        // don't reach back into MainActor-isolated state.
        return NavigationStack {
            if let source = vm.source {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Gutter.section) {

                    // Source switcher — every visible source, one tap away.
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Browse source · changes Home discovery", systemImage: "globe")
                            .font(.footnote)
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, Gutter.page)

                        SourceChipBar(
                            sources: registry.visibleSources(includeAdult: showAdultSources),
                            activeID: registry.activeSourceID
                        ) { id in
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                registry.activeSourceID = id
                            }
                        }
                    }

                    if let err = vm.errorMessage {
                        VStack(alignment: .leading, spacing: 10) {
                            InkNotice("Home couldn't update. \(err)")
                            Button("Try Home Again", action: vm.refresh)
                                .font(.subheadline.bold())
                                .foregroundStyle(Ink.seal)
                                .frame(minHeight: 44)
                        }
                        .padding(.horizontal, Gutter.page)
                    }

                    if vm.isLoading && vm.popular.isEmpty {
                        loadingRail
                    }

                    let updateSummaries = LibraryUpdatesPresentation.summaries(
                        works: works, library: library, history: history, updates: updates)
                    let discoveredUpdates = updateSummaries.filter { $0.newlyDiscoveredCount > 0 }
                    if library.items.isEmpty {
                        noSavedWorksState
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            UpdatesHeader(
                                totalUnread: updateSummaries.reduce(0) { $0 + $1.unreadChapterCount },
                                lastChecked: updateSummaries.compactMap(\.lastSuccessfulCheck).max(),
                                isRefreshing: library.isRefreshing,
                                refresh: refreshUpdates
                            )
                            let recoverySources = Set(updateSummaries.flatMap(\.recoverySummaries)).sorted()
                            if !recoverySources.isEmpty {
                                InkNotice("Couldn't check \(recoverySources.joined(separator: ", ")). Try again.")
                                    .padding(.horizontal, Gutter.page)
                            }
                            if !discoveredUpdates.isEmpty {
                                ForEach(LibraryUpdatesPresentation.homeSummaries(discoveredUpdates)) { summary in
                                    WorkUpdateRow(summary: summary)
                                        .padding(.horizontal, Gutter.page)
                                }
                                if discoveredUpdates.count > UpdateTuning.homeSummaryLimit {
                                    NavigationLink("View all \(discoveredUpdates.count) updates") {
                                        BookmarksView(initialCollectionId: BookmarksView.updatesFilterID)
                                    }
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Ink.seal)
                                    .padding(.horizontal, Gutter.page)
                                    .frame(minHeight: 44)
                                }
                            }
                        }
                    }

                    // Personalized rail #0 — hidden until there's enough reading signal,
                    // except when the engine reports the gate can never open (ADR-0015).
                    if !engine.recommendations.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            (dynamicTypeSize.isAccessibilitySize
                             ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                             : AnyLayout(ZStackLayout(alignment: .trailing))) {
                                InkSectionHeader("For You", eyebrow: "Based on your reading")
                                NavigationLink {
                                    // Recommendations are a bounded ranked list, so the
                                    // grid loads the full pool once then ends (offset > 0
                                    // → empty page → PagedMangaLoader stops).
                                    CategoryGridView(
                                        title: "For You",
                                        initialItems: engine.recommendations.map(\.manga),
                                        pagedFetch: { _, offset in
                                            offset == 0 ? await engine.rankedRecommendations() : []
                                        })
                                } label: {
                                    HStack(spacing: 3) {
                                        Text("See all")
                                        Image(systemName: "chevron.right")
                                    }
                                    .font(.inkMono(11, weight: .semibold))
                                    .foregroundStyle(Ink.seal)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, Gutter.page)
                            }
                            RecommendationRail(
                                items: engine.recommendations,
                                onNotInterested: { engine.markNotInterested($0) },
                                onMoreLikeThis: { engine.markMoreLikeThis($0) }
                            )
                            // Only when the rail is thinner than the history behind it.
                            // At parity it renders nothing — see ForYouBasisNotice.
                            if case .ready(let tagged, let of) = engine.railState, tagged < of {
                                ForYouBasisNotice(tagged: tagged, of: of)
                            }
                        }
                    } else if engine.railState == .noTaggableSignal {
                        // The only closed gate that gets words. `building` and
                        // `needMoreReading` still render nothing, deliberately: a
                        // first-launch reader does not need the recommender's internals
                        // reported as a progress bar (ADR-0015).
                        ForYouUnavailableNotice()
                    }

                    let titles = source.homeRailTitles.count >= 3 ? source.homeRailTitles : ["Popular", "Recently Updated", "Newly Added"]
                    // Eyebrows describe each feed's true ordering; sources that
                    // don't provide them just show the plain serif title.
                    let eyebrows = source.homeRailEyebrows

                    if source.homeFeedCapabilities.contains(.popular) {
                        section(titles[0], eyebrow: eyebrows.count > 0 ? eyebrows[0] : nil,
                                items: vm.popular,
                                stamp: yearStamp,
                                pagedFetch: { limit, offset in
                                    try await source.popular(limit: limit, offset: offset)
                                })
                    }

                    if source.homeFeedCapabilities.contains(.latestUpdates) {
                        section(titles[1], eyebrow: eyebrows.count > 1 ? eyebrows[1] : nil,
                                items: vm.latestUpdates.map { $0.manga },
                                stamp: source.latestRailShowsNewBadge ? { _ in "NEW" } : yearStamp,
                                tinted: source.latestRailShowsNewBadge,
                                // Pages the underlying chapter feed, which dedupes down to far
                                // fewer manga — so ask for a bigger page to still fill a screen.
                                pageSize: 48,
                                pagedFetch: { limit, offset in
                                    try await source
                                        .latestUpdates(limitTitles: limit, language: "en", offset: offset)
                                        .map { $0.manga }
                                })
                    }

                    if source.homeFeedCapabilities.contains(.newTitles) {
                        section(titles[2], eyebrow: eyebrows.count > 2 ? eyebrows[2] : nil,
                                items: vm.newTitles,
                                stamp: yearStamp,
                                pagedFetch: { limit, offset in
                                    try await source.newTitles(limit: limit, offset: offset)
                                })
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(Ink.background)
            .task(id: registry.activeSourceID) { vm.loadHome() }
            .task { engine.load() }
            // Pull-to-refresh reseeds the exploration mix and rebuilds from the latest
            // reading signal — the only way a cold-start rail surfaces (or reshuffles)
            // without relaunching, since the Home tab stays alive so `.task` fires once.
            .refreshable { await engine.refresh() }
            .navigationTitle("Read")
            .navigationBarTitleDisplayMode(.large)
            } else {
                noSourcesState
                    .navigationTitle("Read")
                    .navigationBarTitleDisplayMode(.large)
            }
        }
    }

    private var noSourcesState: some View {
        InkEmptyState(
            symbol: "books.vertical",
            title: "No sources installed",
            message: "Add a repository you trust in Settings to install Sources. MangaCarta does not provide or host content.",
            actionTitle: "Open Settings",
            action: { selectAppTab(.settings) }
        )
    }

    // A titled section: header + rail. Hidden until it has content.
    @ViewBuilder
    private func section(_ title: String, eyebrow: String?,
                         items: [Manga],
                         stamp: @escaping (Manga) -> String?,
                         tinted: Bool = false,
                         pageSize: Int = 24,
                         pagedFetch: @escaping (_ limit: Int, _ offset: Int) async throws -> [Manga]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                (dynamicTypeSize.isAccessibilitySize
                 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                 : AnyLayout(ZStackLayout(alignment: .trailing))) {
                    InkSectionHeader(title, eyebrow: eyebrow)
                    NavigationLink {
                        CategoryGridView(title: title, initialItems: items,
                                         pageSize: pageSize, pagedFetch: pagedFetch)
                    } label: {
                        HStack(spacing: 3) {
                            Text("See all")
                            Image(systemName: "chevron.right")
                        }
                        .font(.inkMono(11, weight: .semibold))
                        .foregroundStyle(Ink.seal)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, Gutter.page)
                }
                MangaRail(items: items, stampFor: stamp, stampTinted: tinted)
            }
        }
    }

    private func yearStamp(_ manga: Manga) -> String? {
        manga.year.map { String($0) }
    }

    private func refreshUpdates() {
        guard !library.isRefreshing else { return }
        Task {
            await library.refresh()
            let summaries = LibraryUpdatesPresentation.summaries(
                works: works, library: library, history: history, updates: updates)
            let failed = Set(summaries.flatMap(\.recoverySummaries))
            let announcement = failed.isEmpty
                ? "Library updates complete"
                : "Library updates complete. Some sources need another check."
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    private var noSavedWorksState: some View {
        VStack(alignment: .leading, spacing: 10) {
            InkSectionHeader("Keep your library current", eyebrow: "Updates")
            Text("Save titles to your Library to keep their chapters current.")
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, Gutter.page)
            HStack(spacing: 12) {
                Button("Browse Titles") { selectAppTab(.home) }
                Button("Search Titles") { selectAppTab(.search) }
            }
            .font(.subheadline.bold())
            .foregroundStyle(Ink.seal)
            .padding(.horizontal, Gutter.page)
            .frame(minHeight: 44)
        }
    }

    // Skeleton rail shown on first load.
    //
    // The four tiles are one visual device, not four things (issue #109, checklist 7.3).
    // Left alone they became four consecutive silent focus stops under a heading that said
    // only "Loading" — a reader who cannot see the empty covers swiped through four
    // elements that announced nothing to learn nothing. Hidden, the rail is one sentence
    // naming what is loading and from where.
    private var loadingRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            InkSectionHeader("Loading", eyebrow: vm.source?.name ?? "Source")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Gutter.rail) {
                    ForEach(0..<4, id: \.self) { _ in
                        CoverPlaceholder(showsSpinner: true)
                            .frame(width: Gutter.coverWidth, height: Gutter.coverHeight)
                            .clipShape(RoundedRectangle(cornerRadius: Gutter.cardRadius))
                    }
                }
                .padding(.horizontal, Gutter.page)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading titles from \(vm.source?.name ?? "source")")
        }
    }
}

/// A quiet inline error notice in the app's voice — seal-tinted, not alarming red.
struct InkNotice: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Ink.seal)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ink.sealSoft))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let library = LibraryStore()
    let history = HistoryStore()
    let taste = TasteProfileStore()
    let works = WorkStore()
    return HomeView()
        .environmentObject(SourceRegistry.shared)
        .environmentObject(library)
        .environmentObject(history)
        .environmentObject(taste)
        .environmentObject(works)
        .environmentObject(UpdateStateStore(works: works))
        .environmentObject(RecommendationEngine(history: history, library: library,
                                                profileStore: taste, workStore: works))
}
