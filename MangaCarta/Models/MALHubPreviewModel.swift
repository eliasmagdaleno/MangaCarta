import SwiftUI

@MainActor
final class MALHubPreviewModel: ObservableObject {
    let candidate: MALDiscoveryCandidate
    @Published private(set) var synopsis: String?
    @Published private(set) var genres: [String] = []
    @Published private(set) var alternativeTitles: [String] = []
    @Published private(set) var nsfw: MALNSFW?
    @Published private(set) var isLoading = false
    @Published private(set) var detailsUnavailable = false
    let showAdultContent: Bool

    private let detailStore: MALDetailStore
    private let fetch: @Sendable (Int) async throws -> MyAnimeListMangaDetail
    private var didLoad = false

    var title: String { candidate.title }
    var coverURL: URL? { candidate.coverURL }
    var canSearchAllSources: Bool {
        if showAdultContent { return true }
        guard let nsfw, nsfw == .white, !detailsUnavailable else { return false }
        let blocked = genres.contains { name in
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "hentai" || normalized == "erotica"
        }
        return !blocked
    }

    init(candidate: MALDiscoveryCandidate, detailStore: MALDetailStore, showAdultContent: Bool,
         fetch: @escaping @Sendable (Int) async throws -> MyAnimeListMangaDetail = { try await MyAnimeListAPI.mangaDetail(id: $0) }) {
        self.candidate = candidate
        self.detailStore = detailStore
        self.showAdultContent = showAdultContent
        self.fetch = fetch
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        defer { isLoading = false }
        guard let detail = await detailStore.detail(for: candidate.malId, fetch: fetch) else {
            detailsUnavailable = true; return
        }
        synopsis = detail.synopsis
        genres = detail.genres?.map(\.name) ?? []
        alternativeTitles = detail.allTitles.dropFirst().map { $0 }
        nsfw = detail.nsfw
    }
}
