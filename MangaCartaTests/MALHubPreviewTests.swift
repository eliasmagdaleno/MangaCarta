import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("MALHubPreviewTests")
struct MALHubPreviewTests {
    @Test func testPreviewShowsCachedCoverThenLoadsTappedDetailOnce() async {
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let cover = URL(string: "https://example.com/cover.jpg")!
        let candidate = MALDiscoveryCandidate(malId: 42, title: "Card title", coverURL: cover,
                                              reason: .recommendation, resolvedListing: nil)
        let calls = PreviewCallCounter()
        let value = MyAnimeListMangaDetail(id: 42, title: "Card title", synopsis: "Synopsis",
                                            mainPicture: nil, genres: [.init(id: 1, name: "Action")],
                                            relatedManga: nil, recommendations: nil,
                                            nsfw: .white,
                                            alternativeTitles: .init(synonyms: ["Alt"], en: nil, ja: nil))
        let store = MALDetailStore(directory: directory.url)
        let first = MALHubPreviewModel(candidate: candidate, detailStore: store, showAdultContent: false) { _ in
            await calls.increment()
            return value
        }
        #expect(first.title == "Card title")
        #expect(first.coverURL == cover)
        await first.load()
        let second = MALHubPreviewModel(candidate: candidate, detailStore: store, showAdultContent: false) { _ in
            await calls.increment()
            return value
        }
        await second.load()
        #expect(await calls.value == 1)
        #expect(second.synopsis == "Synopsis")
        #expect(second.alternativeTitles == ["Alt"])
    }

    @Test func testPreviewDetailFailureKeepsCoverAndTitle() async {
        let candidate = MALDiscoveryCandidate(malId: 42, title: "Card title",
                                              coverURL: URL(string: "https://example.com/cover.jpg"),
                                              reason: .recommendation, resolvedListing: nil)
        let model = MALHubPreviewModel(candidate: candidate, detailStore: MALDetailStore(), showAdultContent: false) { _ in
            throw PreviewError.failed
        }
        await model.load()
        #expect(model.title == "Card title")
        #expect(model.coverURL != nil)
        #expect(model.detailsUnavailable)
        #expect(!model.canSearchAllSources)
    }
}

private enum PreviewError: Error { case failed }

private actor PreviewCallCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}
