//
//  HistoryView.swift
//  MangaCarta
//
//  The "History" tab: a reverse-chronological log of chapters read, grouped by
//  day. Tapping a row reopens that exact chapter and page.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    /// The graph's registry, so the reader opens on the same source the rest of the app
    /// resolves through — not whatever `SourceRegistry.shared` happens to hold.
    @EnvironmentObject private var registry: SourceRegistry
    @Environment(\.selectAppTab) private var selectAppTab

    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    InkEmptyState(
                        symbol: "clock.arrow.circlepath",
                        title: "No reading history",
                        message: "Open a chapter and it will appear here so you can continue later.",
                        actionTitle: "Find Something to Read",
                        action: { selectAppTab(.search) }
                    )
                } else {
                    List {
                        ForEach(groupedEntries, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.value) { entry in
                                    row(entry)
                                }
                                .onDelete { offsets in delete(in: group.value, at: offsets) }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Ink.background)
            .navigationTitle("History")
            .toolbar {
                if !history.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { showingClearConfirmation = true }
                            .foregroundStyle(Ink.seal)
                            .confirmationDialog(
                                "Clear Reading History?",
                                isPresented: $showingClearConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("Clear All History", role: .destructive) {
                                    history.clear()
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This will remove all chapters from your history tab, but your read progress will be preserved.")
                            }
                    }
                }
            }
        }
    }

    private func row(_ entry: ReadingEntry) -> some View {
        NavigationLink {
            if let source = registry.source(for: entry.asManga) {
                ReaderView(manga: entry.asManga, chapter: entry.asChapter,
                           source: source,
                           initialPosition: entry.position)
            } else {
                Text("Source unavailable")
            }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: entry.coverURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: CoverPlaceholder()
                    }
                }
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.mangaTitle)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text("CH·\(entry.chapterNumber) · page \(entry.page + 1)/\(max(entry.pageCount, entry.page + 1))")
                        .font(.inkMono(11, weight: .medium))
                        .foregroundStyle(Ink.seal)
                    Text(entry.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.footnote)
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel(
            relativeTime: entry.updatedAt.formatted(.relative(presentation: .named))))
        .listRowBackground(Ink.background)
        .contextMenu {
            NavigationLink {
                MangaDetailView(manga: entry.asManga)
            } label: {
                Label("View Manga Details", systemImage: "book")
            }

            Button(role: .destructive) {
                history.delete(entry)
            } label: {
                Label("Delete from History", systemImage: "trash")
            }
        }
    }

    private var groupedEntries: [(key: String, value: [ReadingEntry])] {
        var order: [String] = []
        var buckets: [String: [ReadingEntry]] = [:]
        for entry in history.entries {
            let key = Self.dayLabel(entry.updatedAt)
            if buckets[key] == nil { buckets[key] = []; order.append(key) }

            // Only add the first (most recent) entry per manga for the given day
            if !(buckets[key]?.contains(where: { $0.mangaId == entry.mangaId }) ?? false) {
                buckets[key]?.append(entry)
            }
        }
        return order.map { ($0, buckets[$0]!) }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month().day().year())
    }

    private func delete(in group: [ReadingEntry], at offsets: IndexSet) {
        for index in offsets { history.delete(group[index]) }
    }
}

// Internal rather than fileprivate: `asManga` is the Manga that reaches the reader on the
// resume path, so it is what `HistoryStore.record` reads `malId` off — behaviour with a test
// behind it (ADR-0018 amendment 1), not a view-local convenience.
extension ReadingEntry {
    var asManga: Manga {
        Manga(
            id: mangaId,
            sourceId: sourceId ?? MangaDexSource.sourceID,
            title: mangaTitle,
            description: "",
            status: "unknown",
            year: nil,
            coverURL: coverURL,
            malId: malId
        )
    }
    var asChapter: Chapter {
        Chapter(id: chapterId, number: chapterNumber, title: nil)
    }

    /// The history row as one spoken sentence (issue #90).
    ///
    /// The row draws "CH·5 · page 3/20", which is three separate pieces of typography —
    /// a stamp abbreviation, two middle dots, and a slash — and none of them is a word.
    /// `relativeTime` is passed in already formatted because the row renders it that way
    /// and the phrasing is the formatter's job, not this one's.
    func accessibilityLabel(relativeTime: String) -> String {
        let total = max(pageCount, page + 1)
        return "\(mangaTitle), Chapter \(chapterNumber), page \(page + 1) of \(total), \(relativeTime)"
    }
}

#Preview {
    HistoryView().environmentObject(HistoryStore())
}
