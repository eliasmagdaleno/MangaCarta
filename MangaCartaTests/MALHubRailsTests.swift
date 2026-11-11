import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("MALHubRailsTests")
struct MALHubRailsTests {
    @Test func testRailsLoadOncePerMangaAndSplitRelatedFromSimilar() {
        let related = MALDiscoveryCandidate(malId: 2, title: "Related", coverURL: nil,
                                             reason: .related(type: "sequel", label: "Sequel"),
                                             resolvedListing: nil)
        let similar = MALDiscoveryCandidate(malId: 3, title: "Similar", coverURL: nil,
                                             reason: .recommendation, resolvedListing: nil)
        let discovery = MALDetailDiscovery(related: [related], similar: [similar])
        #expect(discovery.related.map(\.title) == ["Related"])
        #expect(discovery.similar.map(\.title) == ["Similar"])
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
