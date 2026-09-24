//
//  PagedMangaGrid.swift
//  MangaCarta
//
//  The shared infinite-scroll results grid: a 3-wide cover grid over a
//  `PagedMangaLoader`, appending the next page as the user nears the bottom.
//  Renders only the grid and its load-more footer — callers own the
//  surrounding ScrollView, empty states, and error notices.
//

import SwiftUI

struct PagedMangaGrid: View {
    @EnvironmentObject private var registry: SourceRegistry
    @ObservedObject var loader: PagedMangaLoader

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 180), spacing: Gutter.rail)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Gutter.section) {
            ForEach(loader.items) { manga in
                NavigationLink(destination: MangaDetailView(manga: manga, registry: registry)) {
                    MangaCoverCard(
                        title: manga.title,
                        coverURL: manga.coverURL,
                        stamp: manga.year.map { String($0) },
                        fill: true
                    )
                }
                .buttonStyle(.plain)
                .onAppear { loader.loadMoreIfNeeded(current: manga) }
            }
        }
        .padding(.horizontal, Gutter.page)

        if loader.isLoadingMore {
            // Named, because this one *appears* — a reader who has just reached the end
            // of the grid otherwise cannot tell more results are coming from the list
            // having ended.
            InkLoading("Loading more titles")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }
}
