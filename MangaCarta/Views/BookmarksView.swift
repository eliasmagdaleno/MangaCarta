//
//  BookmarksView.swift
//  MangaCarta
//
//  The "Library" tab: manga saved by the user organized into collections.
//  Renders saved items as a grid filtered by selected collection tab,
//  with quick collection management.
//

import SwiftUI
import UniformTypeIdentifiers

struct BookmarksView: View {
    static let updatesFilterID = "updates"
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var works: WorkStore
    @EnvironmentObject private var updates: UpdateStateStore
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.selectAppTab) private var selectAppTab

    @State private var selectedCollectionId: String
    @State private var showingManagementSheet = false
    @State private var refreshBannerMessage: String? = nil
    @State private var showingRefreshBanner = false
    @State private var showingImporter = false
    @StateObject private var importer = LocalImportViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 180), spacing: Gutter.rail)
    ]

    init(initialCollectionId: String = "all") {
        _selectedCollectionId = State(initialValue: initialCollectionId)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !library.items.isEmpty {
                    collectionPickerBar
                }

                let displayedItems = displayedLibraryItems

                Group {
                    if library.items.isEmpty {
                        InkEmptyState(
                            symbol: "books.vertical",
                            title: "Your library is empty",
                            message: "Import CBZ or ZIP files from Files. MangaCarta does not provide or host content.",
                            actionTitle: "Import from Files",
                            action: { showingImporter = true }
                        )
                    } else if displayedItems.isEmpty {
                        InkEmptyState(
                            symbol: "folder.badge.questionmark",
                            title: "No titles in this collection",
                            message: "Add a saved title to this collection, or manage which collections are shown.",
                            actionTitle: "Manage Collections",
                            action: { showingManagementSheet = true }
                        )
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Gutter.section) {
                                ForEach(displayedItems) { item in
                                    let unread = item.unreadCount(readNumbers: history.readChapterNumbers(forManga: item.id))
                                    NavigationLink(destination: MangaDetailView(manga: item.asManga, registry: registry)) {
                                        MangaCoverCard(
                                            title: item.title,
                                            coverURL: item.coverURL,
                                            badge: unread > 0 ? "\(unread)" : nil,
                                            fill: true
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    // The grid's only stable handle for UI tests; the label is
                                    // the title, which varies with whatever is in the library.
                                    .accessibilityIdentifier("libraryCoverCard")
                                }
                            }
                            .padding(.horizontal, Gutter.page)
                            .padding(.top, 12)
                            .padding(.bottom, 32)
                        }
                        .background(Ink.background)
                        .refreshable {
                            await refreshLibrary()
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if showingRefreshBanner, let message = refreshBannerMessage {
                    HStack(spacing: 8) {
                        if library.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Ink.seal)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Ink.seal)
                        }
                        Text(message)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Ink.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Ink.surface)
                            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Ink.hairline, lineWidth: 1)
                    )
                    // One stop, not a silent spinner beside its own message (issue #109).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .background(Ink.background)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshLibrary() }
                    } label: {
                        Label("Refresh Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isRefreshing)
                    .accessibilityHint("Checks saved titles for new chapters")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingManagementSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Manage Collections")
                }
            }
            .sheet(isPresented: $showingManagementSheet) {
                CollectionManagementView()
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [UTType.zip, UTType.mangaCartaCBZ],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { importer.importFiles(urls) }
            }
            .overlay(alignment: .top) {
                LocalImportBanner(model: importer, onCancel: importer.cancel)
                    .padding(.top, 8)
            }
            .task { importer.configure(registry: registry, library: library, works: works) }
        }
    }

    private func refreshLibrary() async {
        guard !library.isRefreshing else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            refreshBannerMessage = "Updating library…"
            showingRefreshBanner = true
        }

        await library.refresh()

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            refreshBannerMessage = "Library updated"
        }
        UIAccessibility.post(notification: .announcement, argument: "Library updated")

        try? await Task.sleep(for: .seconds(4.5))
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            showingRefreshBanner = false
        }
    }

    // MARK: - Collection Tab Bar

    private var collectionPickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All Manga" tab
                collectionTabChip(
                    id: "all",
                    title: "All",
                    count: library.items.count
                )

                collectionTabChip(
                    id: Self.updatesFilterID,
                    title: "Updates",
                    count: updateMangaIDs.count
                )

                // Enabled collections tabs
                ForEach(library.enabledCollections) { collection in
                    let count = library.items(in: collection.id).count
                    collectionTabChip(
                        id: collection.id,
                        title: collection.name,
                        count: count
                    )
                }
            }
            .padding(.horizontal, Gutter.page)
            .padding(.vertical, 8)
        }
        .background(Ink.surfaceAlt.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Ink.hairline)
                .frame(height: 1)
        }
    }

    private func collectionTabChip(id: String, title: String, count: Int) -> some View {
        let isSelected = selectedCollectionId == id
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                selectedCollectionId = id
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                Text("(\(count))")
                    .font(.caption.weight(isSelected ? .bold : .regular))
                    .opacity(isSelected ? 0.9 : 0.6)
            }
            .foregroundStyle(isSelected ? Ink.seal : Ink.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Ink.sealSoft : Ink.surface)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Ink.seal : Ink.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var updateMangaIDs: Set<String> {
        return Set(LibraryUpdatesPresentation.summaries(
            works: works, library: library, history: history,
            updates: updates
        ).filter { $0.newlyDiscoveredCount > 0 }.map(\.displayManga.id))
    }

    private var displayedLibraryItems: [LibraryItem] {
        if selectedCollectionId == Self.updatesFilterID {
            return library.items.filter { updateMangaIDs.contains($0.id) }
        }
        return library.items(in: selectedCollectionId)
    }
}

private extension LibraryItem {
    /// A minimal `Manga` for navigation; the detail view refetches full data by id.
    var asManga: Manga {
        // `nil` because `LibraryItem` has no id to carry, not because one is being dropped —
        // ADR-0018's Scope excludes it deliberately (saved-but-unread items never reach the
        // taste profile). Contrast `ReadingEntry.asManga`, which does carry it.
        Manga(id: id, sourceId: sourceId ?? LegacySourceID.unattributed, title: title,
              description: "", status: "unknown", year: nil, coverURL: coverURL, malId: nil)
    }
}

#Preview {
    let works = WorkStore()
    BookmarksView()
        .environmentObject(LibraryStore())
        .environmentObject(HistoryStore())
        .environmentObject(works)
        .environmentObject(UpdateStateStore(works: works))
}
