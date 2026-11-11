import SwiftUI

@MainActor
final class MALHubRailsViewModel: ObservableObject {
    @Published private(set) var related: [MALDiscoveryCandidate] = []
    @Published private(set) var similar: [MALDiscoveryCandidate] = []
    @Published private(set) var isLoading = false

    private let registry: SourceRegistry
    private let provider: MoreLikeThisProvider?
    private let fetchDetail: @Sendable (Int) async throws -> MyAnimeListMangaDetail
    private let showAdultContent: () -> Bool
    private var loadedFor: String?

    init(registry: SourceRegistry, provider: MoreLikeThisProvider? = nil,
         showAdultContent: @escaping () -> Bool = AdultContentSetting.current,
         fetchDetail: @escaping @Sendable (Int) async throws -> MyAnimeListMangaDetail = {
             try await MyAnimeListAPI.mangaDetail(id: $0)
         }) {
        self.registry = registry
        self.provider = provider
        self.showAdultContent = showAdultContent
        self.fetchDetail = fetchDetail
    }

    func load(for manga: Manga, detailStore: MALDetailStore,
              fetchDetail: (@Sendable (Int) async throws -> MyAnimeListMangaDetail)? = nil,
              entityStore: EntityResolutionStore? = nil) async {
        guard loadedFor != manga.id else { return }
        loadedFor = manga.id
        isLoading = true
        defer { isLoading = false }
        let registry = registry
        let provider = provider ?? MoreLikeThisProvider(
            store: entityStore ?? .shared,
            detailStore: detailStore,
            fetchDetail: fetchDetail ?? self.fetchDetail,
            source: { registry.externalIdSource })
        guard let discovery = await provider.detailDiscovery(
            for: manga,
            showAdultContent: showAdultContent(),
            admits: { registry.admitsForDiscovery($0) }) else { return }
        related = discovery.related
        similar = discovery.similar
    }
}

enum MALHubCardAccessibility {
    static func label(for candidate: MALDiscoveryCandidate) -> String {
        let reason: String
        switch candidate.reason {
        case .related(_, let label): reason = label.lowercased()
        case .recommendation: reason = "recommended by MyAnimeList"
        }
        let availability = candidate.resolvedListing == nil
            ? "not on your Sources"
            : "on your Sources"
        return "\(candidate.title), \(reason), \(availability)"
    }
}
