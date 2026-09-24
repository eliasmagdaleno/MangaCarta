//
//  ChapterListView.swift
//  MangaCarta
//
//  The full chapter list for a manga: newest/oldest sort toggle + multi-select
//  batch actions (mark read/unread). Pushed from the detail page's "Show all N
//  chapters" affordance; the detail page itself shows only a short preview.
//

import SwiftUI

struct ChapterListView: View {
    let manga: Manga
    let chapters: [Chapter]
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var works: WorkStore
    @EnvironmentObject private var updates: UpdateStateStore
    /// The graph's registry, so the reader opens on the same source the rest of the app
    /// resolves through — not whatever `SourceRegistry.shared` happens to hold.
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var descending = true
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sortChapters(chapters, descending: descending)) { chapter in
                    if isSelecting {
                        Button {
                            toggleSelection(chapter.id)
                        } label: {
                            ChapterRow(chapter: chapter, selecting: true,
                                       selected: selectedIDs.contains(chapter.id))
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            // The row advertises a saved position (ChapterRow's resume marker),
                            // so tapping it has to honour one — ADR-0014 decision 11.
                            if let source = registry.source(for: manga) {
                                ReaderView(manga: manga, chapter: chapter,
                                           source: source,
                                           initialPosition: history.entry(forChapter: chapter.id)?.position,
                                           chapters: chapters)
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
                                let sorted = sortChapters(chapters, descending: descending)
                                if let idx = sorted.firstIndex(where: { $0.id == chapter.id }) {
                                    history.markRead(manga: manga, chapters: Array(sorted[idx...]))
                                }
                            } label: {
                                Label("Mark all below as read", systemImage: "arrow.down.to.line")
                            }
                        }
                        .accessibilityAction(named: readActionName(for: chapter)) {
                            history.toggleRead(manga: manga, chapter: chapter)
                        }
                        .accessibilityAction(named: "Mark this and all below as read") {
                            markAllBelow(chapter)
                        }
                    }
                    Divider().overlay(Ink.hairline)
                        .padding(.leading, Gutter.page)
                }
            }
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isSelecting {
                Label("Use Select for batch changes, or press and hold a chapter for more actions.",
                      systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Gutter.page)
                    .padding(.vertical, 10)
                    .background(Ink.surfaceAlt)
            }
        }
        .background(Ink.background)
        .navigationTitle("Chapters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            isSelecting = false
                            selectedIDs.removeAll()
                        }
                    } label: {
                        Text("CANCEL")
                            .font(.inkMono(11, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Ink.seal)
                    }
                    // Uppercase with letter tracking is a typographic choice; spelled out
                    // letter by letter it is not a word (issue #90, checklist 5.2).
                    .accessibilityLabel("Cancel")
                } else {
                    HStack(spacing: 16) {
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { isSelecting = true }
                        } label: {
                            Text("SELECT")
                                .font(.inkMono(11, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(Ink.seal)
                        }
                        .accessibilityLabel("Select chapters")
                        .accessibilityHint("Choose several chapters to mark read or unread")
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { descending.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.arrow.down")
                                Text(descending ? "NEWEST" : "OLDEST")
                            }
                            .font(.inkMono(11, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Ink.seal)
                        }
                        // The glyph pair reads as "arrow up arrow down" and the word as
                        // initials; neither says what the control does (checklist 5.8).
                        .accessibilityLabel("Sort order")
                        .accessibilityValue(descending ? "Newest first" : "Oldest first")
                        .accessibilityHint("Reverses the chapter order")
                    }
                }
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            selectedIDs = allSelected ? [] : Set(chapters.map(\.id))
                        }
                    }
                    Spacer()
                    Button("Mark Unread") { markSelected(read: false) }
                        .disabled(selectedIDs.isEmpty)
                    Button("Mark Read") { markSelected(read: true) }
                        .disabled(selectedIDs.isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .accessibilityIdentifier("chapterListScreen")
        .task { clearNewlyDiscovered() }
    }

    private var allSelected: Bool {
        !chapters.isEmpty && selectedIDs.count == chapters.count
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func markSelected(read: Bool) {
        let picked = chapters.filter { selectedIDs.contains($0.id) }
        if read {
            history.markRead(manga: manga, chapters: picked)
        } else {
            history.markUnread(manga: manga, chapters: picked)
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            isSelecting = false
            selectedIDs.removeAll()
        }
    }

    private func readActionName(for chapter: Chapter) -> String {
        history.isRead(chapterId: chapter.id) ? "Mark as unread" : "Mark as read"
    }

    private func markAllBelow(_ chapter: Chapter) {
        let sorted = sortChapters(chapters, descending: descending)
        guard let index = sorted.firstIndex(where: { $0.id == chapter.id }) else { return }
        history.markRead(manga: manga, chapters: Array(sorted[index...]))
    }

    private func clearNewlyDiscovered() {
        guard let workId = works.workId(for: ListingKey(manga)) else { return }
        updates.clearNewlyDiscovered(workId: workId)
    }
}
