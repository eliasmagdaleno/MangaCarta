import Foundation
import XCTest
@testable import MangaCarta

// Fixtures intentionally keep the setup close to each acceptance case.
// swiftlint:disable line_length

@MainActor
final class MALHubProjectionTests: XCTestCase {
    func testRelatedAndRecommendationsShareOneCachedDetailFetch() async {
        let detail = fixtureDetail()
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let defaults = makeTestDefaults(#function)
        let manga = fixtureManga(id: "parent", malId: detail.id)
        let forward = MALEntityResolver(store: EntityResolutionStore(defaults: defaults))
        let reverse = MALReverseResolver(store: EntityResolutionStore(defaults: makeTestDefaults(#function)), search: { _ in [] }, fetchByIds: { _ in [] }, fetchTitles: { _ in [] }, source: { nil })
        let calls = HubCallCounter()
        let provider = MoreLikeThisProvider(resolver: forward, reverse: reverse, detailStore: store, fetchDetail: { _ in await calls.increment(); return detail }, source: { nil })
        _ = await provider.detailDiscovery(for: manga, showAdultContent: true, admits: { _ in true })
        _ = await provider.recommendations(for: manga)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testNativeCandidatesKeepOrderAndRetainUnresolvedTitles() async {
        let detail = fixtureDetail(related: [(10, "Pre", "prequel"), (11, "Side", "side_story"), (10, "Again", "sequel")], recommendations: [(20, "Heavy", 9), (21, "Light", 2)])
        let result = await project(detail: detail, parent: fixtureManga(id: "parent", malId: 1), resolved: [20: fixtureManga(id: "20", malId: 20)])
        XCTAssertEqual(result.related.map(\.malId), [10, 11])
        XCTAssertEqual(result.related.map { if case .related(_, let label) = $0.reason { return label }; return "" }, ["Prequel", "Side story"])
        XCTAssertEqual(result.similar.map(\.malId), [20, 21])
        XCTAssertNil(result.similar[1].resolvedListing)
    }

    func testMissingMALIdentityHidesBothRails() async {
        let forwardCalls = HubCallCounter()
        let reverseCalls = HubCallCounter()
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let resolver = MALEntityResolver(store: EntityResolutionStore(defaults: makeTestDefaults(#function)), search: { _ in await forwardCalls.increment(); return [] })
        let reverse = MALReverseResolver(store: EntityResolutionStore(defaults: makeTestDefaults("reverse-\(#function)")), search: { _ in await reverseCalls.increment(); return [] }, fetchByIds: { _ in [] }, fetchTitles: { _ in [] }, source: { nil })
        let provider = MoreLikeThisProvider(resolver: resolver, reverse: reverse, detailStore: store, fetchDetail: { _ in XCTFail("no fetch"); return fixtureDetail() }, source: { nil })
        let discovery = await provider.detailDiscovery(for: fixtureManga(id: "none", malId: nil), showAdultContent: true, admits: { _ in true })
        let callCount = await reverseCalls.value
        XCTAssertNil(discovery)
        XCTAssertEqual(callCount, 0)
    }

    func testSwitchOffHidesUnresolvedCards() async {
        let result = await project(detail: fixtureDetail(), parent: fixtureManga(id: "p", malId: 1), resolved: [:], showAdult: false)
        XCTAssertTrue(result.related.isEmpty && result.similar.isEmpty)
    }

    func testSwitchOffKeepsOnlyAdmittedResolvedCards() async {
        let detail = fixtureDetail(recommendations: [(20, "Good", 3), (21, "Bad", 2)])
        let result = await project(detail: detail, parent: fixtureManga(id: "p", malId: 1), resolved: [20: fixtureManga(id: "good", malId: 20), 21: fixtureManga(id: "bad", malId: 21)], showAdult: false) { $0.id == "good" }
        XCTAssertEqual(result.similar.map(\.malId), [20])
    }

    func testSwitchOnShowsUnresolvedCardsUnderSourceAdmission() async {
        let result = await project(detail: fixtureDetail(), parent: fixtureManga(id: "p", malId: 1), resolved: [:], showAdult: true)
        XCTAssertFalse(result.similar.isEmpty)
    }

    func testHomeRailReceivesResolvedListingsOnly() async {
        let detail = fixtureDetail(recommendations: [(20, "Good", 3), (21, "Missing", 2)])
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let target = fixtureManga(id: "good", malId: nil)
        let resolutions = EntityResolutionStore(defaults: makeTestDefaults(#function))
        let provider = MoreLikeThisProvider(resolver: MALEntityResolver(store: resolutions), reverse: MALReverseResolver(store: resolutions, search: { _ in [target] }, fetchByIds: { _ in [] }, fetchTitles: { _ in [] }, source: { nil }), detailStore: store, fetchDetail: { _ in detail }, source: { nil })
        let values = await provider.recommendations(for: fixtureManga(id: "p", malId: 1))
        XCTAssertEqual(values.map(\.id), ["good"])
    }

    func testRelationsUseSemanticOrderAndStableTieBreak() {
        let detail = fixtureDetail(related: [(1, "Sequel", "sequel"), (2, "Prequel", "prequel"), (3, "Prequel 2", "prequel")])
        let result = MALDiscoveryProjection.project(detail: detail, parentMALID: 999, parentListingID: "p", resolutions: [:], showAdultContent: true, admits: { _ in true }, recommendationLimit: 8)
        XCTAssertEqual(result.related.map(\.malId), [2, 3, 1])
    }

    func testUnknownRelationIsLabeledAndSortedLast() {
        let detail = fixtureDetail(related: [(1, "Unknown", "fan_fiction"), (2, "Other", "other")])
        let result = MALDiscoveryProjection.project(detail: detail, parentMALID: 999, parentListingID: "p", resolutions: [:], showAdultContent: true, admits: { _ in true }, recommendationLimit: 8)
        XCTAssertEqual(result.related.map(\.malId), [2, 1])
        if case .related(_, let label) = result.related[1].reason { XCTAssertEqual(label, "Fan fiction") }
    }

    func testOneReverseResolveCallCoversBothRails() async {
        let count = HubCallCounter()
        let resolutions = EntityResolutionStore(defaults: makeTestDefaults(#function))
        let reverse = MALReverseResolver(store: resolutions, search: { _ in await count.increment(); return [] }, fetchByIds: { _ in [] }, fetchTitles: { _ in [] }, source: { nil })
        let provider = MoreLikeThisProvider(resolver: MALEntityResolver(store: resolutions), reverse: reverse, detailStore: MALDetailStore(directory: makeTestDirectory(#function)), fetchDetail: { _ in fixtureDetail(related: [(2, "R", "prequel")], recommendations: [(3, "S", 1)]) }, source: { nil })
        _ = await provider.detailDiscovery(for: fixtureManga(id: "p", malId: 1), showAdultContent: true, admits: { _ in true })
        let callCount = await count.value
        XCTAssertEqual(callCount, 2)
    }

    private func project(detail: MyAnimeListMangaDetail, parent: Manga, resolved: [Int: Manga], showAdult: Bool = true, admits: @escaping (Manga) -> Bool = { _ in true }) async -> MALDetailDiscovery {
        MALDiscoveryProjection.project(detail: detail, parentMALID: parent.malId ?? -1, parentListingID: parent.id, resolutions: resolved, showAdultContent: showAdult, admits: admits, recommendationLimit: 8)
    }
}

private func fixtureManga(id: String, malId: Int?) -> Manga { Manga(id: id, sourceId: "source", title: id, description: "", status: "unknown", year: nil, coverURL: nil, malId: malId) }
private func fixtureDetail(related: [(Int, String, String)] = [(2, "Related", "prequel")], recommendations: [(Int, String, Int)] = [(3, "Recommendation", 4)]) -> MyAnimeListMangaDetail {
    MyAnimeListMangaDetail(id: 1, title: "Parent", synopsis: nil, mainPicture: nil, genres: nil, relatedManga: related.map { .init(node: .init(id: $0.0, title: $0.1, mainPicture: nil, alternativeTitles: nil, mediaType: nil), relationType: $0.2, relationTypeFormatted: $0.2) }, recommendations: recommendations.map { .init(node: .init(id: $0.0, title: $0.1, mainPicture: nil, alternativeTitles: nil, mediaType: nil), numRecommendations: $0.2) })
}

private actor HubCallCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}

// swiftlint:enable line_length
