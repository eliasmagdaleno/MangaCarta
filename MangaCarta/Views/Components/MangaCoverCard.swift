//
//  MangaCoverCard.swift
//  MangaCarta
//
//  A cover card in the "Ink & Seal" voice: hairline-framed art (like a printed
//  plate), a serif title, and a monospaced metadata stamp.
//

import SwiftUI

struct MangaCoverCard: View {
    let title: String          // Title shown under the cover
    let coverURL: URL?         // Remote cover URL (may be nil)
    var stamp: String? = nil   // Optional metadata stamp, e.g. "CH·012" or "NEW"
    var stampTinted = false    // Draw the stamp in the seal color
    var badge: String? = nil   // Top-left unread count; the rendered label states its meaning.
    var fill = false           // Fill the grid cell's width (3-up grid) vs. fixed 128pt rail card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Framed cover plate.
            coverBox
                .overlay(
                    CachedAsyncImage(url: coverURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            CoverPlaceholder()
                        case .empty:
                            CoverPlaceholder(showsSpinner: true)
                        @unknown default:
                            CoverPlaceholder()
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: Gutter.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Gutter.cardRadius)
                        .strokeBorder(Ink.hairline, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text("\(badge) unread")
                            .font(.inkMono(10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Ink.seal)
                            )
                            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                            .padding(6)
                    }
                }
                .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 3)

            // Title — always reserves two lines so the stamp below aligns
            // across cards regardless of how long each title is.
            Text(title)
                .font(.system(.footnote, design: .serif).weight(.semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(2, reservesSpace: true)

            // Metadata stamp.
            if let stamp {
                InkStamp(text: stamp, tinted: stampTinted)
            }
        }
        .frame(maxWidth: fill ? .infinity : Gutter.coverWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        [title, badge.map { "\($0) unread chapters" }, stamp]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The sized, clipped box the cover art fills. In `fill` mode the grid cell
    /// drives the width and the height follows the cover aspect ratio; otherwise
    /// it's the fixed rail-card size.
    @ViewBuilder private var coverBox: some View {
        if fill {
            Color.clear
                .aspectRatio(Gutter.coverWidth / Gutter.coverHeight, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            Color.clear
                .frame(width: Gutter.coverWidth, height: Gutter.coverHeight)
        }
    }
}
