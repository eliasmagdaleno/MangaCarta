import SwiftUI

struct WorkUpdateRow: View {
    @EnvironmentObject private var registry: SourceRegistry
    let summary: WorkUpdateSummary

    var body: some View {
        NavigationLink {
            MangaDetailView(manga: summary.displayManga, registry: registry)
        } label: {
            HStack(spacing: Gutter.rail) {
                AsyncImage(url: summary.displayManga.coverURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        CoverPlaceholder()
                    }
                }
                .frame(width: 48, height: 68)
                .clipShape(.rect(cornerRadius: Gutter.cardRadius))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.displayManga.title)
                        .font(.headline)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                    Text(chapterText)
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                    if summary.newlyDiscoveredCount > 0 {
                        Text("NEW")
                            .font(.inkMono(10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Ink.seal)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Ink.sealSoft, in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel)
    }

    private var chapterText: String { summary.unreadChapterText }
}
