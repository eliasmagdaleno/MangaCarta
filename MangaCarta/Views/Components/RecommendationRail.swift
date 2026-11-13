//
//  RecommendationRail.swift
//  MangaCarta
//
//  The "For You" rail: cover cards carrying a per-item reason ("More Action") and a
//  long-press menu to refine taste (Not interested / More like this). Mirrors MangaRail's
//  layout so it sits flush with the other Home rails.
//

import SwiftUI

struct RecommendationRail: View {
    @EnvironmentObject private var registry: SourceRegistry
    let items: [ScoredManga]
    let onNotInterested: (Manga) -> Void
    let onMoreLikeThis: (Manga) -> Void
    var onOpen: ((Manga, Int) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Gutter.rail) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, rec in
                    NavigationLink(destination: MangaDetailView(manga: rec.manga, registry: registry)) {
                        MangaCoverCard(
                            title: rec.manga.title,
                            coverURL: rec.manga.coverURL,
                            stamp: rec.reason,
                            stampTinted: true
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { onOpen?(rec.manga, index) })
                    .accessibilityIdentifier("recommendationCard")
                    .contextMenu {
                        Button("More like this", systemImage: "plus.circle") {
                            onMoreLikeThis(rec.manga)
                        }
                        Button("Not interested", systemImage: "hand.thumbsdown", role: .destructive) {
                            onNotInterested(rec.manga)
                        }
                    }
                }
            }
            .padding(.horizontal, Gutter.page)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
