import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("MALHubAdultTests")
struct MALHubAdultTests {
    @Test func testPreviewNSFWFailsClosed() async {
        let values: [MALNSFW?] = [.white, .gray, .black, .unknown("future"), nil]
        for value in values {
            let model = await makeModel(nsfw: value, genres: [])
            #expect(model.canSearchAllSources == (value == .white))
            let enabled = await makeModel(nsfw: value, genres: [], showAdultContent: true)
            #expect(enabled.canSearchAllSources)
        }
        for genre in ["Hentai", "hentai", "Erotica", "EROTICA"] {
            let model = await makeModel(nsfw: .white, genres: [genre])
            #expect(!model.canSearchAllSources)
        }
    }

    private func makeModel(nsfw: MALNSFW?, genres: [String], showAdultContent: Bool = false) async -> MALHubPreviewModel {
        let directory = TestDirectory("MALHubAdult")
        defer { directory.remove() }
        let candidate = MALDiscoveryCandidate(malId: Int.random(in: 1...100_000), title: "Title",
                                              coverURL: nil, reason: .recommendation, resolvedListing: nil)
        let detail = MyAnimeListMangaDetail(id: candidate.malId, title: "Title", synopsis: nil,
                                            mainPicture: nil,
                                            genres: genres.enumerated().map { .init(id: $0.offset, name: $0.element) },
                                            relatedManga: nil, recommendations: nil, nsfw: nsfw)
        let model = MALHubPreviewModel(candidate: candidate,
                                       detailStore: MALDetailStore(directory: directory.url),
                                       showAdultContent: showAdultContent) { _ in detail }
        await model.load()
        return model
    }
}
