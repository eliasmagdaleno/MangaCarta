import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("MALHubRailsTests")
struct MALHubRailsTests {
    /// The detail page's view model splits one MAL detail into Related and More Like This,
    /// and a second `.task` run for the same manga (a re-appear) fetches nothing more.
    @Test func testRailsLoadOncePerMangaAndSplitRelatedFromSimilar() async {
        let directory = TestDirectory("MALHubRails")
        let defaults = TestDefaults("MALHubRails")
        defer { directory.remove() }
        defer { defaults.remove() }
        let fetches = FetchCounter()
        let detail = MyAnimeListMangaDetail(
            id: 1, title: "Parent", synopsis: nil, mainPicture: nil, genres: nil,
            relatedManga: [.init(node: .init(id: 2, title: "Related", mainPicture: nil,
                                            alternativeTitles: nil, mediaType: "manga"),
                                  relationType: "sequel", relationTypeFormatted: "Sequel")],
            recommendations: [.init(node: .init(id: 3, title: "Similar", mainPicture: nil,
                                                alternativeTitles: nil, mediaType: "manga"),
                                    numRecommendations: 1)], nsfw: .white)
        let registry = SourceRegistry(sources: [], defaults: defaults.defaults)
        let model = MALHubRailsViewModel(registry: registry, showAdultContent: { true })
        let parent = Manga(id: "parent", sourceId: "source", title: "Parent", description: "",
                           status: "ongoing", year: nil, coverURL: nil, malId: 1)
        let store = MALDetailStore(directory: directory.url)
        let fetch: @Sendable (Int) async throws -> MyAnimeListMangaDetail = { _ in
            await fetches.increment()
            return detail
        }
        let entities = EntityResolutionStore(defaults: defaults.defaults)
        await model.load(for: parent, detailStore: store, fetchDetail: fetch, entityStore: entities)
        await model.load(for: parent, detailStore: store, fetchDetail: fetch, entityStore: entities)
        #expect(model.related.map(\.title) == ["Related"])
        #expect(model.similar.map(\.title) == ["Similar"])
        #expect(await fetches.count == 1)
    }

    @Test func testSwitchOffRendersOnlyResolvedAdmittedCards() {
        let resolved = Manga(id: "resolved", sourceId: "source", title: "Resolved",
                             description: "", status: "ongoing", year: nil, coverURL: nil, malId: 2)
        let detail = MyAnimeListMangaDetail(
            id: 1, title: "Parent", synopsis: nil, mainPicture: nil, genres: nil,
            relatedManga: [.init(node: .init(id: 2, title: "Resolved", mainPicture: nil,
                                            alternativeTitles: nil, mediaType: "manga"),
                                  relationType: "sequel", relationTypeFormatted: "Sequel")],
            recommendations: [.init(node: .init(id: 3, title: "Unknown", mainPicture: nil,
                                                alternativeTitles: nil, mediaType: "manga"),
                                    numRecommendations: 1)], nsfw: .white)
        let projected = MALDiscoveryProjection.project(detail: detail, parentMALID: 1,
                                                       parentListingID: "parent",
                                                       resolutions: [2: resolved], showAdultContent: false,
                                                       admits: { _ in true }, recommendationLimit: 8)
        #expect(projected.related.count == 1)
        #expect(projected.similar.isEmpty)
    }

    @Test func testCardAccessibilityLabelNamesTitleReasonAndAvailability() {
        let related = MALDiscoveryCandidate(malId: 1, title: "Vinland Saga", coverURL: nil,
                                            reason: .related(type: "sequel", label: "Sequel"),
                                            resolvedListing: Manga(id: "1", sourceId: "a",
                                                                   title: "Vinland Saga", description: "",
                                                                   status: "ongoing", year: nil, coverURL: nil,
                                                                   malId: 1))
        let recommendation = MALDiscoveryCandidate(malId: 2, title: "Planetes", coverURL: nil,
                                                    reason: .recommendation, resolvedListing: nil)
        #expect(MALHubCardAccessibility.label(for: related) == "Vinland Saga, sequel, on your Sources")
        #expect(MALHubCardAccessibility.label(for: recommendation) == "Planetes, recommended by MyAnimeList, not on your Sources")
    }
}

private actor FetchCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
