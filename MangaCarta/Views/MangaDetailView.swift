//
//  MangaDetailView.swift
//  MangaCarta
//

import SwiftUI

struct MangaDetailView: View {
    let manga: Manga
    @StateObject private var vm: MangaDetailViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var works: WorkStore
    @EnvironmentObject private var updates: UpdateStateStore
    @EnvironmentObject private var engine: RecommendationEngine
    @EnvironmentObject private var fulfillment: FulfillmentCoordinator
    @EnvironmentObject private var sourcePreferences: SourcePreferenceStore
    @Environment(\.dismiss) private var dismiss
    /// The graph's registry, not the singleton. They are the same object in production and
    /// different ones under a UI-test fixture, and reading the wrong one made every source
    /// lookup on this page miss.
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var coverWidth: CGFloat = 132
    @ScaledMetric(relativeTo: .title) private var coverHeight: CGFloat = 188
    @StateObject private var moreLikeThis: MoreLikeThisViewModel
    @State private var synopsisExpanded = false
    @State private var showingWebPage = false
    @State private var showingLocalDeleteConfirmation = false
    @State private var localSizeText = "calculating size…"
    @State private var deletionError: String?

    init(manga: Manga, registry: SourceRegistry) {
        self.manga = manga
        _vm = StateObject(wrappedValue: MangaDetailViewModel(manga: manga))
        _moreLikeThis = StateObject(wrappedValue: MoreLikeThisViewModel(registry: registry))
    }

    /// The registered source this manga came from (nil if its source was unregistered).
    private var mangaSource: MangaSource? {
        registry.source(id: manga.sourceId)
    }
    private var isLocalManga: Bool { manga.sourceId == LocalSource.sourceID }

    @State private var mangaWebURL: URL?

    // MARK: - Source (ADR-0004)

    /// This manga's Work, once it has one. A Work is minted at a commitment point, so a
    /// title merely being browsed legitimately has none — and with no Work there are no
    /// other Listings to offer.
    private var workID: WorkID? {
        works.workId(for: ListingKey(manga))
    }

    private var sourcePicker: SourcePickerPresentation? {
        guard let workID else { return nil }
        let candidates = fulfillment.candidates(for: workID)
        return SourcePickerPresentation(
            candidates: candidates,
            current: vm.activeListing,
            names: Dictionary(uniqueKeysWithValues: registry.sources.map { ($0.id, $0.name) }))
    }

    /// Opens the page on the Listing the reader pinned, if they pinned one.
    ///
    /// Only a **pin** redirects, never the ranking. Arriving here means tapping a specific
    /// card, and silently serving a different source's chapters than the one just tapped
    /// would be surprising. A pin is the reader having said otherwise, on this title, on
    /// purpose (ADR-0004 Amendment 1).
    private func applyPinnedSource() {
        // Bind the view model to the graph's registry first. It has no source until this
        // runs: `init` happens before the environment exists, and the singleton it used to
        // reach there was right in production and wrong under a fixture — the failure mode
        // was a detail page that could not load its chapters.
        vm.adopt(registry: registry)
        guard let workID,
              let pinned = sourcePreferences.choice(for: workID),
              pinned != vm.activeListing,
              registry.source(id: pinned.sourceId) != nil else { return }
        vm.retarget(to: pinned, using: registry)
    }

    /// Counts the Work's uncounted Listings in the background, so the picker can say how
    /// many chapters each has. Runs on the detail page and nowhere else: counting the whole
    /// library eagerly is the strategy ADR-0004 rejects.
    private func reconcileListingCounts() async {
        guard let workID else { return }
        await fulfillment.reconcile(workID)
    }

    /// The stamp, which becomes a picker only when there is somewhere else to read from.
    /// One Listing is not a choice, so it renders exactly as it always has.
    @ViewBuilder
    private var sourceControl: some View {
        if let sourcePicker, sourcePicker.offersAChoice, let workID {
            SourcePickerStamp(
                presentation: sourcePicker,
                isPinned: sourcePreferences.choice(for: workID) != nil,
                select: { listing in
                    sourcePreferences.choose(listing, for: workID)
                    vm.retarget(to: listing, using: registry)
                    vm.load()
                },
                useBestAvailable: {
                    sourcePreferences.clearChoice(for: workID)
                    if let best = fulfillment.chosenListing(for: workID) {
                        vm.retarget(to: best, using: registry)
                        vm.load()
                    }
                })
        } else {
            SourceStamp(sourceID: manga.sourceId,
                        name: mangaSource?.name ?? manga.sourceId)
        }
    }

    private func clearNewlyDiscovered() {
        guard let workId = works.workId(for: ListingKey(manga)) else { return }
        updates.clearNewlyDiscovered(workId: workId)
    }

    /// Whether this title has been *refused* a catalog match, so the empty "More Like This"
    /// section can say why instead of disappearing.
    ///
    /// Nil-safe by design, and both nils mean "say nothing": a title with no Work has never
    /// been committed to (read, saved, rated — ADR-0007), so the drain has not tried and
    /// there is no answer to report. Inferring it from the source instead would be guessing,
    /// against this area's standing precision bias (`MALTitleMatcher`, ADR-0005).
    private var isUnmatchable: Bool {
        guard let id = works.workId(for: ListingKey(manga)),
              let work = works.work(id) else { return false }
        return engine.isUnmatchable(work)
    }

    /// This manga's source when it can browse by genre — otherwise nil, so the genre
    /// chips render as plain, non-tappable metadata.
    private var tagBrowseSource: MangaSource? {
        guard let mangaSource, mangaSource.supportsTagBrowse else { return nil }
        return mangaSource
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Gutter.section) {
                hero
                actionRow
                if !vm.tags.isEmpty { tags }
                if !vm.description.isEmpty || vm.isLoading { description }
                chapters
                if !moreLikeThis.items.isEmpty {
                    moreLikeThisRail
                } else if isUnmatchable {
                    // The empty section explains itself rather than vanishing (ADR-0005's
                    // first implied requirement). Ordered after the rail check so a title
                    // that somehow has both never shows the notice instead of results.
                    UnmatchedTitleNotice()
                }
            }
            .padding(.bottom, 40)
        }
        .background(Ink.background)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            applyPinnedSource()
            vm.load()
        }
        .task { await reconcileListingCounts() }
        .task { await loadLocalSize() }
        .task { mangaWebURL = try? await mangaSource?.webURL(forManga: manga.id) }
        .task { await moreLikeThis.load(for: manga) }
        .task { clearNewlyDiscovered() }
        .onChange(of: vm.detailTags) { _, tags in
            // Ungated: every source has tags, and this is what makes non-MangaDex
            // reading count (ADR-0007 slice 3). Never mints — see `noteListingTags`.
            works.noteListingTags(tags, for: manga)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let url = mangaWebURL {
                    Button {
                        showingWebPage = true
                    } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel("Open on \(mangaSource?.name ?? "web")")
                    .sheet(isPresented: $showingWebPage) {
                        SafariView(url: url)
                            .ignoresSafeArea()
                    }
                }
            }
        }
        .alert("Delete \(manga.title) from this iPhone?", isPresented: $showingLocalDeleteConfirmation) {
            Button("Delete from Device", role: .destructive) {
                guard let local = mangaSource as? LocalSource else { return }
                Task {
                    do {
                        try await LocalLibraryDeletion(local: local.store, library: library, works: works)
                            .delete(itemId: manga.id)
                        dismiss()
                    } catch {
                        deletionError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The imported file (\(formattedLocalSize)) is removed from MangaCarta and can't be recovered. Reading history is kept.")
        }
        .alert("Couldn't delete from device", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "The imported file could not be removed.")
        }
    }

    // MARK: Hero — cover plate on flat paper: title, authors, metadata stamps.

    private var hero: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 16))

        return layout {
            // Cover plate.
            AsyncImage(url: manga.coverURL) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .empty: CoverPlaceholder(showsSpinner: true)
                default: CoverPlaceholder()
                }
            }
            .frame(width: min(coverWidth, 198), height: min(coverHeight, 282))
            .clipShape(RoundedRectangle(cornerRadius: Gutter.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Gutter.cardRadius)
                    .strokeBorder(Ink.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(manga.title)
                    .font(.inkDisplay(26))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !vm.authors.isEmpty {
                    Text(vm.authors.joined(separator: " · "))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Ink.seal)
                        .lineLimit(2)
                }

                // Source first — "where is this from" leads the stamp row.
                // The scroll area escapes the trailing page margin so chips run
                // to the screen edge, matching the genre row below.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        sourceControl
                        if let year = manga.year {
                            InkStamp(text: String(year))
                        }
                        InkStamp(text: manga.status.uppercased())
                        if let rating = vm.contentRating, !rating.isEmpty {
                            InkStamp(text: rating.uppercased(), tinted: true)
                        }
                    }
                    .padding(.trailing, Gutter.page)
                }
                .padding(.trailing, -Gutter.page)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Gutter.page)
        .padding(.top, 12)
    }

    // MARK: Actions — one primary (Continue), one compact library toggle.

    @ViewBuilder private var actionRow: some View {
        let entry = history.latestEntry(forManga: manga.id)
        let action = resumeAction(entry: entry, chapters: vm.chapters)
        HStack(spacing: 10) {
            if let action {
                continueLink(action, progress: continueProgress(action: action, entry: entry))
                libraryToggle
            } else if vm.isLoading {
                // Chapters still loading — placeholder keeps the layout stable.
                HStack(spacing: 8) {
                    ProgressView().tint(Ink.seal)
                    Text("Start Reading")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Ink.tertiary)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.sealSoft.opacity(0.5)))
                // Issue #109. This is a placeholder holding the layout still, not the
                // button — it is not tappable and there is nothing yet to start. Speaking
                // the drawn "Start Reading" would announce a control that is not there,
                // which is worse than silence because it is wrong.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading chapters")
                libraryToggle
            } else {
                // No readable chapters — the library toggle gets its words back.
                let inLibrary = library.contains(manga.id)
                let assignedIds = library.collectionIds(for: manga.id)
                Menu {
                    Section {
                        Button {
                            if isLocalManga { showingLocalDeleteConfirmation = true } else {
                                withAnimation(.snappy(duration: 0.2)) { library.toggle(manga) }
                            }
                        } label: {
                            Label(
                                isLocalManga ? "Delete from Device" : (inLibrary ? "Remove from Library" : "Quick Add to Library"),
                                systemImage: inLibrary ? "trash" : "bookmark"
                            )
                        }
                    }
                    Section("Collections") {
                        ForEach(library.enabledCollections) { collection in
                            let isInCollection = assignedIds.contains(collection.id)
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    library.toggleCollection(for: manga, collectionId: collection.id)
                                }
                            } label: {
                                Label(
                                    collection.name,
                                    systemImage: isInCollection ? "checkmark.square.fill" : "square"
                                )
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: inLibrary ? "bookmark.fill" : "bookmark")
                        Text(inLibrary ? "In Library" : "Add to Library")
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .opacity(0.7)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(inLibrary ? Ink.seal : Color.white)
                    .background(RoundedRectangle(cornerRadius: 12).fill(inLibrary ? Ink.sealSoft : Ink.seal))
                } primaryAction: {
                            if isLocalManga { showingLocalDeleteConfirmation = true } else {
                                withAnimation(.snappy(duration: 0.2)) { library.toggle(manga) }
                            }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Gutter.page)
    }

    private func continueLink(_ action: ResumeAction, progress: Double?) -> some View {
        NavigationLink {
            if let source = registry.source(for: manga) {
                ReaderView(manga: manga, chapter: action.chapter,
                           source: source,
                           initialPosition: action.startPosition, chapters: vm.chapters)
            } else {
                UnavailableSourceView()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Ink.seal)

                // A thin ink-fill rule showing how far into the chapter you are.
                if let progress {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.9))
                                    .frame(width: geo.size.width * progress)
                            }
                            .frame(height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }

                // Centered label with a start marker; the page stamp rides inline.
                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(action.label)
                        .lineLimit(1)
                    // The page only: a stamp reading "p.4·62%" tells the reader nothing
                    // they can act on, and the hairline fill already carries the fraction.
                    if case .cont(_, let position) = action {
                        Text("· p.\(position.page + 1)")
                            .font(.inkMono(11, weight: .semibold))
                            .opacity(0.85)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var libraryToggle: some View {
        let inLibrary = library.contains(manga.id)
        let assignedIds = library.collectionIds(for: manga.id)

        return Menu {
            Section {
                Button {
                    if isLocalManga { showingLocalDeleteConfirmation = true } else {
                        withAnimation(.snappy(duration: 0.2)) { library.toggle(manga) }
                    }
                } label: {
                    Label(
                        isLocalManga ? "Delete from Device" : (inLibrary ? "Remove from Library" : "Quick Add to Library"),
                        systemImage: inLibrary ? "trash" : "bookmark"
                    )
                }
            }
            Section("Collections") {
                ForEach(library.enabledCollections) { collection in
                    let isInCollection = assignedIds.contains(collection.id)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            library.toggleCollection(for: manga, collectionId: collection.id)
                        }
                    } label: {
                        Label(
                            collection.name,
                            systemImage: isInCollection ? "checkmark.square.fill" : "square"
                        )
                    }
                }
            }
        } label: {
            Image(systemName: inLibrary ? "bookmark.fill" : "bookmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.seal)
                .frame(width: 50, height: 50)
                .background(RoundedRectangle(cornerRadius: 12).fill(inLibrary ? Ink.sealSoft : Ink.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(inLibrary ? Ink.seal : Ink.hairline, lineWidth: inLibrary ? 1.5 : 1)
                )
        } primaryAction: {
            if isLocalManga { showingLocalDeleteConfirmation = true } else {
                withAnimation(.snappy(duration: 0.2)) { library.toggle(manga) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLocalManga ? "Delete from Device" : (inLibrary ? "Manage Library Collections" : "Add to Library"))
    }

    private var formattedLocalSize: String {
        localSizeText
    }

    private func loadLocalSize() async {
        guard isLocalManga, let source = mangaSource as? LocalSource else { return }
        let megabytes = Double(await source.store.itemSize(itemId: manga.id)) / 1_048_576
        localSizeText = String(format: "%.1f MB", megabytes)
    }

    // MARK: Tags

    private var tags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.tags, id: \.self) { tag in
                    if let source = tagBrowseSource {
                        NavigationLink {
                            CategoryGridView(title: tag, pagedFetch: { limit, offset in
                                try await source.mangaByTag(tag: tag, limit: limit, offset: offset)
                            })
                        } label: {
                            chip(tag, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Browse \(tag)")
                    } else {
                        chip(tag, interactive: false)
                    }
                }
            }
            .padding(.horizontal, Gutter.page)
        }
    }

    /// A single genre chip. Interactive chips (source supports tag browse) read as
    /// tappable in the seal voice; plain chips are quiet metadata. Mono + uppercase
    /// keeps every chip the same height regardless of the tag's length.
    @ViewBuilder
    private func chip(_ tag: String, interactive: Bool) -> some View {
        Text(tag.uppercased())
            .font(.inkMono(10, weight: .medium))
            .tracking(0.5)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(interactive ? Ink.seal : Ink.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(interactive ? Ink.sealSoft : Ink.surface))
            .overlay(Capsule().strokeBorder(interactive ? Ink.seal : Ink.hairline, lineWidth: 1))
    }

    // MARK: Description

    private var description: some View {
        VStack(alignment: .leading, spacing: 10) {
            InkSectionHeader("Synopsis", eyebrow: "About")
            VStack(alignment: .leading, spacing: 8) {
                Text(vm.description.isEmpty ? "No synopsis available." : vm.description)
                    .font(.body)
                    .foregroundStyle(Ink.secondary)
                    .lineSpacing(3)
                    .lineLimit(synopsisExpanded ? nil : 4)

                // Only offer the toggle when the text is long enough to clip.
                if vm.description.count > 220 {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { synopsisExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(synopsisExpanded ? "Show less" : "Show more")
                            Image(systemName: synopsisExpanded ? "chevron.up" : "chevron.down")
                        }
                        .font(.inkMono(11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Ink.seal)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Gutter.page)
        }
    }

    // MARK: More Like This — MAL-sourced cross-source recommendations, bottom of page.

    private var moreLikeThisRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            InkSectionHeader("More Like This", eyebrow: "Similar titles")
            MangaRail(items: moreLikeThis.items)
        }
        .accessibilityIdentifier("moreLikeThisSection")
    }

    // MARK: Chapters

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 12) {
            InkSectionHeader("Chapters", eyebrow: "\(vm.chapters.count) available")
                .padding(.trailing, Gutter.page)

            if !vm.chapters.isEmpty {
                Label("Press and hold a chapter for read actions", systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Gutter.page)
            }

            if let error = vm.errorMessage, vm.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    InkNotice("Chapters couldn't load. \(error)")
                    Button("Try Chapters Again", action: vm.load)
                        .font(.subheadline.bold())
                        .foregroundStyle(Ink.seal)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, Gutter.page)
            } else if vm.chapters.isEmpty {
                Text(vm.isLoading ? "Loading chapters…" : "No chapters yet.")
                    .font(.footnote)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.horizontal, Gutter.page)
            } else {
                VStack(spacing: 0) {
                    ForEach(chapterPreview(vm.chapters, limit: 5)) { chapter in
                        NavigationLink {
                            // The row advertises a saved position (ChapterRow's resume marker),
                            // so tapping it has to honour one — ADR-0014 decision 11.
                            if let source = registry.source(for: manga) {
                                ReaderView(manga: manga, chapter: chapter,
                                           source: source,
                                           initialPosition: history.entry(forChapter: chapter.id)?.position,
                                           chapters: vm.chapters)
                            } else {
                                UnavailableSourceView()
                            }
                        } label: {
                            ChapterRow(chapter: chapter)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            let read = history.isRead(chapterId: chapter.id)
                            Button {
                                history.toggleRead(manga: manga, chapter: chapter)
                            } label: {
                                Label(read ? "Mark as unread" : "Mark as read",
                                      systemImage: read ? "circle" : "checkmark.circle")
                            }

                            Button {
                                let sorted = sortChapters(vm.chapters, descending: true)
                                if let idx = sorted.firstIndex(where: { $0.id == chapter.id }) {
                                    history.markRead(manga: manga, chapters: Array(sorted[idx...]))
                                }
                            } label: {
                                Label("Mark all below as read", systemImage: "arrow.down.to.line")
                            }
                        }
                        .accessibilityAction(named: history.isRead(chapterId: chapter.id)
                                             ? "Mark as unread" : "Mark as read") {
                            history.toggleRead(manga: manga, chapter: chapter)
                        }
                        .accessibilityAction(named: "Mark this and all below as read") {
                            let sorted = sortChapters(vm.chapters, descending: true)
                            guard let index = sorted.firstIndex(where: { $0.id == chapter.id }) else {
                                return
                            }
                            history.markRead(manga: manga, chapters: Array(sorted[index...]))
                        }
                        Divider().overlay(Ink.hairline)
                            .padding(.leading, Gutter.page)
                    }

                    if vm.chapters.count > 5 {
                        NavigationLink {
                            ChapterListView(manga: manga, chapters: vm.chapters)
                        } label: {
                            HStack {
                                Text("Show all \(vm.chapters.count) chapters")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Ink.seal)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Ink.tertiary)
                            }
                            .padding(.horizontal, Gutter.page)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("showAllChaptersButton")
                    }
                }
            }
        }
    }

}

private extension ResumeAction {
    var chapter: Chapter {
        switch self {
        case .start(let c), .next(let c), .cont(let c, _), .reread(let c): return c
        }
    }
    var startPosition: ReadingPosition {
        switch self {
        case .start, .next, .reread: return ReadingPosition(page: 0)
        case .cont(_, let position): return position
        }
    }
    var label: String {
        switch self {
        case .start:                 return "Start Reading"
        case .cont(let c, _):        return "Continue · Ch \(c.number)"
        case .next(let c):           return "Start Ch \(c.number)"
        case .reread(let c):         return "Read Again · Ch \(c.number)"
        }
    }
}
