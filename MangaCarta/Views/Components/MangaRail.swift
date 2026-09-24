//
//  MangaRail.swift
//  MangaCarta
//
//  A horizontal, scrollable rail of cover cards. Expects `Manga` to already
//  carry `coverURL`. Generous gutters keep it breathing like a printed spread.
//

import SwiftUI

struct MangaRail: View {
    @EnvironmentObject private var registry: SourceRegistry
    let items: [Manga]
    /// Optional per-item stamp text, e.g. chapter labels keyed by manga id.
    var stampFor: ((Manga) -> String?)? = nil
    var stampTinted = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Gutter.rail) {
                ForEach(items, id: \.id) { manga in
                    NavigationLink(destination: MangaDetailView(manga: manga, registry: registry)) {
                        MangaCoverCard(
                            title: manga.title,
                            coverURL: manga.coverURL,
                            stamp: stampFor?(manga),
                            stampTinted: stampTinted
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mangaCoverCard")
                }
            }
            .padding(.horizontal, Gutter.page)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
