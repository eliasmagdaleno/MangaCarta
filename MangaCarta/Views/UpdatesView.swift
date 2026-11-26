//
//  UpdatesView.swift
//  MangaCarta
//
//  The Updates destination (spec 2026-11-09, slice 2): newly discovered chapters, by the
//  local day of each Work's newest discovery, then by Work.
//

import SwiftUI

/// Reads the graph's registry and fulfillment coordinator from the environment and hands
/// them to the screen, whose `@StateObject` loader is built in `init` — before the
/// environment exists (the same reason as `HomeView`).
struct UpdatesView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var fulfillment: FulfillmentCoordinator

    var body: some View {
        UpdatesScreen(registry: registry, fulfillment: fulfillment)
    }
}

private struct UpdatesScreen: View {
    @ObservedObject private var registry: SourceRegistry
    @StateObject private var loader: UpdatesChapterLoader

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var works: WorkStore
    @EnvironmentObject private var updates: UpdateStateStore
    @Environment(\.selectAppTab) private var selectAppTab

    /// Works the reader collapsed. Groups start expanded; collapsing one stops it fetching.
    @State private var collapsed: Set<WorkID> = []

    init(registry: SourceRegistry, fulfillment: FulfillmentCoordinator) {
        _registry = ObservedObject(wrappedValue: registry)
        _loader = StateObject(wrappedValue: UpdatesChapterLoader(
            resolve: UpdatesChapterLoader.live(registry: registry, fulfillment: fulfillment)))
    }

    var body: some View {
        let summaries = LibraryUpdatesPresentation.summaries(
            works: works, library: library, history: history, updates: updates, registry: registry)
        let timeline = UpdatesTimeline(summaries: summaries, updates: updates)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: Gutter.section) {
                if library.items.isEmpty {
                    noSavedWorks
                } else {
                    UpdatesScreenHeader(
                        newChapterCount: timeline.newChapterCount,
                        lastChecked: summaries.compactMap(\.lastSuccessfulCheck).max(),
                        isRefreshing: library.isRefreshing,
                        refresh: { Task { await refresh() } },
                        markAllSeen: { markAllSeen(timeline) })

                    let recovery = Set(summaries.flatMap(\.recoverySummaries)).sorted()
                    if !recovery.isEmpty {
                        InkNotice("Couldn't check \(recovery.joined(separator: ", ")). Pull to refresh to try again.")
                            .padding(.horizontal, Gutter.page)
                            .accessibilityIdentifier("updatesRecoveryNotice")
                    }

                    if timeline.isEmpty {
                        upToDate
                    } else {
                        ForEach(timeline.sections) { section in
                            daySection(section)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Ink.background)
        .refreshable { await refresh() }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("updatesScreen")
    }

    // MARK: Sections

    private func daySection(_ section: UpdatesTimeline.DaySection) -> some View {
        VStack(alignment: .leading, spacing: Gutter.rail) {
            InkSectionHeader(section.title)
                .accessibilityIdentifier("updatesDayHeading")
            ForEach(section.works) { group in
                UpdatesWorkGroup(
                    group: group,
                    resolution: loader.resolutions[group.id],
                    isExpanded: !collapsed.contains(group.id),
                    toggle: { toggle(group.id) },
                    request: { loader.request(group.id, displayManga: group.summary.displayManga) },
                    retry: { loader.retry(group.id, displayManga: group.summary.displayManga) },
                    markSeen: { markSeen(group) },
                    openSettings: { selectAppTab(.settings) })
                .padding(.horizontal, Gutter.page)
            }
        }
    }

    private var noSavedWorks: some View {
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
        .accessibilityIdentifier("updatesNoSavedWorks")
    }

    private var upToDate: some View {
        VStack(alignment: .leading, spacing: 10) {
            InkSectionHeader("You’re up to date")
            Text("New chapters will appear here when saved titles are checked.")
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, Gutter.page)
        }
        .accessibilityIdentifier("updatesUpToDate")
    }

    // MARK: Actions

    private func toggle(_ workId: WorkID) {
        if collapsed.contains(workId) { collapsed.remove(workId) } else { collapsed.insert(workId) }
    }

    private func markAllSeen(_ timeline: UpdatesTimeline) {
        timeline.markAllSeen(in: updates)
        UIAccessibility.post(notification: .announcement, argument: "All updates marked seen")
    }

    private func markSeen(_ group: UpdatesTimeline.WorkGroup) {
        updates.clearNewlyDiscovered(workId: group.id)
        UIAccessibility.post(notification: .announcement,
                             argument: "\(group.summary.displayManga.title) marked seen")
    }

    /// The shared Library refresh seam — the same `LibraryRefreshCoordinator` pass Home and
    /// Library run — never a Source directly. Known rows stay through it; afterwards every
    /// fetched chapter list is stale and the Works still shown fetch again.
    private func refresh() async {
        guard !library.isRefreshing else { return }
        await library.refresh()
        let summaries = LibraryUpdatesPresentation.summaries(
            works: works, library: library, history: history, updates: updates, registry: registry)
        let timeline = UpdatesTimeline(summaries: summaries, updates: updates)
        loader.invalidate(keeping: Set(timeline.workIds))
        for group in timeline.sections.flatMap(\.works) where loader.resolutions[group.id] != nil
            && !collapsed.contains(group.id) {
            loader.request(group.id, displayManga: group.summary.displayManga)
        }
        let failed = Set(summaries.flatMap(\.recoverySummaries)).sorted()
        let announcement = failed.isEmpty
            ? "Updates refreshed"
            : "Updates refreshed. Couldn't check \(failed.joined(separator: ", "))."
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }
}

// MARK: - Header

private struct UpdatesScreenHeader: View {
    let newChapterCount: Int
    let lastChecked: Date?
    let isRefreshing: Bool
    let refresh: () -> Void
    let markAllSeen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Gutter.rail))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(countText)
                    .font(.headline)
                    .foregroundStyle(Ink.primary)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("updatesStatus")

            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Gutter.rail) }

            HStack(spacing: 8) {
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(isRefreshing)
                    .accessibilityLabel(isRefreshing ? "Refreshing updates" : "Refresh updates")
                    .accessibilityHint("Checks saved titles for new chapters")
                    .accessibilityIdentifier("updatesScreenRefreshButton")

                Button("Mark all seen", action: markAllSeen)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .foregroundStyle(newChapterCount == 0 ? Ink.tertiary : Ink.seal)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Ink.sealSoft)
                        .opacity(newChapterCount == 0 ? 0 : 1))
                    .disabled(newChapterCount == 0)
                    .accessibilityHint("Clears the new marks. Chapters stay unread.")
                    .accessibilityIdentifier("updatesMarkAllSeenButton")
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, Gutter.page)
    }

    private var countText: String {
        newChapterCount == 1 ? "1 new chapter" : "\(newChapterCount) new chapters"
    }

    private var statusText: String {
        if isRefreshing { return "Checking saved titles…" }
        guard let lastChecked else { return "Not checked yet" }
        return "Last checked \(lastChecked.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Work group

private struct UpdatesWorkGroup: View {
    let group: UpdatesTimeline.WorkGroup
    let resolution: UpdatesChapterResolution?
    let isExpanded: Bool
    let toggle: () -> Void
    let request: () -> Void
    let retry: () -> Void
    let markSeen: () -> Void
    let openSettings: () -> Void

    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.imageCache) private var imageCache
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var summary: WorkUpdateSummary { group.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                chapters
                    // Lazy: a group's chapters are fetched the first time it is both expanded
                    // and on screen — never for a collapsed group or one scrolled past.
                    .onAppear(perform: request)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline, lineWidth: 1))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            NavigationLink {
                MangaDetailView(manga: summary.displayManga, registry: registry)
            } label: {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: Gutter.rail))
                layout {
                    CachedAsyncImage(url: summary.displayManga.coverURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            CoverPlaceholder()
                        }
                    }
                    .frame(width: 44, height: 62)
                    .clipShape(.rect(cornerRadius: Gutter.cardRadius))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.displayManga.title)
                            .font(.inkDisplay(17))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        InkStamp(text: newText.uppercased(), tinted: true)
                        if summary.isMuted {
                            Text("Muted")
                                .font(.caption)
                                .foregroundStyle(Ink.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.accessibilityLabel)
                .accessibilityHint("Opens the title's chapter list")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("updatesWorkHeader")
            .accessibilityAction(named: "Mark seen", markSeen)

            VStack(spacing: 0) {
                Menu {
                    Button("Mark seen", systemImage: "checkmark.circle", action: markSeen)
                        .accessibilityIdentifier("updatesWorkMarkSeen")
                    // The notification-actions spec adds Mute/Unmute here.
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(Ink.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Actions for \(summary.displayManga.title)")
                .accessibilityIdentifier("updatesWorkMenu")

                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Ink.tertiary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(isExpanded ? "Hide new chapters" : "Show new chapters")
                .accessibilityValue(summary.displayManga.title)
                .accessibilityIdentifier("updatesWorkExpand")
            }
        }
    }

    private var newText: String {
        group.ordinals.count == 1 ? "1 new chapter" : "\(group.ordinals.count) new chapters"
    }

    // MARK: Chapters

    @ViewBuilder
    private var chapters: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch resolution {
            case .sourceUnavailable?:
                sourceUnavailable
                ForEach(group.ordinals, id: \.self) { ordinal in
                    ordinalRow(ordinal, detail: nil)
                }
            case .failed(_, let message)?:
                VStack(alignment: .leading, spacing: 6) {
                    InkNotice("Couldn't load chapters. \(message)")
                    HStack(spacing: 16) {
                        Button("Try Again", action: retry)
                            .accessibilityIdentifier("updatesChaptersRetry")
                        chapterListLink
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Ink.seal)
                    .frame(minHeight: 44)
                }
                ForEach(group.ordinals, id: \.self) { ordinal in
                    ordinalRow(ordinal, detail: nil)
                }
            case .loaded(let manga, let chapters)?:
                let rows = UpdatesChapterRow.rows(ordinals: group.ordinals, chapters: chapters)
                ForEach(rows) { row in
                    switch row {
                    case .chapter(_, let chapter):
                        readerLink(chapter, manga: manga, chapters: chapters)
                    case .unmatched(let ordinal), .pending(let ordinal):
                        ordinalRow(ordinal, detail: "Not in the current chapter list")
                    }
                }
                if rows.contains(where: { if case .unmatched = $0 { true } else { false } }) {
                    chapterListLink
                        .font(.subheadline.bold())
                        .foregroundStyle(Ink.seal)
                        .frame(minHeight: 44)
                }
            case .loading?, nil:
                ForEach(group.ordinals, id: \.self) { ordinal in
                    ordinalRow(ordinal, detail: nil)
                }
                .accessibilityHidden(true)
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading chapters")
                        .font(.footnote)
                        .foregroundStyle(Ink.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading \(newText) for \(summary.displayManga.title)")
                .accessibilityIdentifier("updatesChaptersLoading")
            }
        }
    }

    private var sourceUnavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            InkNotice("Source unavailable. Add its repository in Settings to read these chapters.")
            Button("Open Settings", action: openSettings)
                .font(.subheadline.bold())
                .foregroundStyle(Ink.seal)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("updatesSourceUnavailable")
    }

    private var chapterListLink: some View {
        NavigationLink("View chapter list") {
            MangaDetailView(manga: summary.displayManga, registry: registry)
        }
        .accessibilityIdentifier("updatesViewChapterList")
    }

    private func readerLink(_ chapter: Chapter, manga: Manga, chapters: [Chapter]) -> some View {
        NavigationLink {
            if let source = registry.source(id: manga.sourceId) {
                ReaderView(manga: manga, chapter: chapter,
                           source: source,
                           imageCache: imageCache,
                           initialPosition: history.entry(for: chapter, in: manga)?.position,
                           chapters: chapters)
            } else {
                UnavailableSourceView()
            }
        } label: {
            HStack(spacing: 8) {
                ChapterRow(chapter: chapter, manga: manga)
                InkStamp(text: "NEW", tinted: true)
            }
            .contentShape(.rect)
            // "New" is spoken, not only stamped.
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("updatesChapterLink")
    }

    /// A discovered chapter with no fetched chapter behind it (yet, or at all).
    private func ordinalRow(_ ordinal: ChapterOrdinal, detail: String?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chapter \(ordinal.value.description)")
                    .font(.body)
                    .foregroundStyle(Ink.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Ink.tertiary)
                }
            }
            Spacer(minLength: 0)
            InkStamp(text: "NEW", tinted: true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("updatesChapterUnresolved")
    }
}

// MARK: - Temporary UI-test route

/// Pushes `UpdatesView` at launch under `-uitest-open-updates`, so the slice 2 UI tests can
/// reach the screen before slice 3 replaces Home's and Library's "View all" links with real
/// entry points. Debug-only, and a no-op without the argument. Slice 3 deletes it.
struct UITestUpdatesRoute: ViewModifier {
#if DEBUG
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains("-uitest-open-updates")

    func body(content: Content) -> some View {
        content.navigationDestination(isPresented: $isPresented) { UpdatesView() }
    }
#else
    func body(content: Content) -> some View { content }
#endif
}
