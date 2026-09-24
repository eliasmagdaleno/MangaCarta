//
//  CategoryGridView.swift
//  MangaCarta
//
//  A full-screen 3-wide grid for a Home category (e.g. "Popular"), pushed onto
//  the Home navigation stack when the user taps "See all". Reuses
//  `MangaCoverCard` in fill mode, mirroring the Library grid.
//

import SwiftUI

struct CategoryGridView: View {
    @EnvironmentObject private var registry: SourceRegistry
    let title: String
    /// Shown only until page one arrives, so pushing in from a rail doesn't flash an
    /// empty grid. Deliberately NOT seeded into the loader: that would populate its
    /// `seenIDs`, making page one read as all-duplicates and ending the feed at once.
    private let initialItems: [Manga]
    private let pagedFetch: (_ limit: Int, _ offset: Int) async throws -> [Manga]

    @StateObject private var loader: PagedMangaLoader
    @State private var loadedOnce = false

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 180), spacing: Gutter.rail)
    ]

    /// An infinite-scroll grid over a paged feed.
    /// - Parameter pageSize: Raise it for feeds that shrink after server-side dedupe
    ///   (latest-updates pages chapters, not manga), so a page still fills a screen.
    init(title: String,
         initialItems: [Manga] = [],
         pageSize: Int = 24,
         pagedFetch: @escaping (_ limit: Int, _ offset: Int) async throws -> [Manga]) {
        self.title = title
        self.initialItems = initialItems
        self.pagedFetch = pagedFetch
        _loader = StateObject(wrappedValue: PagedMangaLoader(pageSize: pageSize))
    }

    var body: some View {
        ScrollView {
            content
        }
        .background(Ink.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            loader.load(fetch: pagedFetch)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = loader.errorMessage, loader.items.isEmpty {
            VStack(spacing: 14) {
                InkNotice(error)
                Button("Try again") { loader.retry() }
                    .font(.inkMono(12, weight: .semibold))
                    .foregroundStyle(Ink.seal)
            }
            .padding(Gutter.page)
        } else if loader.items.isEmpty && loader.isLoading {
            // Page one is still in flight — hold the rail's covers in place.
            placeholderGrid
        } else if loader.items.isEmpty && loadedOnce {
            InkEmptyState(
                symbol: "tray",
                title: "No results",
                message: "Nothing found for \(title)."
            )
            .padding(.top, 80)
        } else {
            PagedMangaGrid(loader: loader)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
    }

    /// The seeded covers from the rail, rendered while page one loads. Static — the
    /// loader owns paging, so these carry no load-more hook and are replaced wholesale.
    private var placeholderGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Gutter.section) {
            ForEach(initialItems) { manga in
                NavigationLink(destination: MangaDetailView(manga: manga, registry: registry)) {
                    MangaCoverCard(
                        title: manga.title,
                        coverURL: manga.coverURL,
                        stamp: manga.year.map { String($0) },
                        fill: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Gutter.page)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .overlay(alignment: .bottom) {
            if initialItems.isEmpty {
                InkLoading("Loading \(title)")
                    .padding(.vertical, 40)
            }
        }
    }
}
