import XCTest
@testable import MangaCarta

@MainActor
final class MALEntityResolverTests: XCTestCase {
    private func makeWork(_ titles: [String], mal: Int? = nil, listings: [ListingKey] = []) -> Work {
        Work(id: WorkID(), displayTitle: titles.first ?? "", knownTitles: titles,
             externalIds: ExternalIDs(mal: mal, anilist: nil), listings: listings)
    }

    func testCandidatesTopEqualsResolvePickWhenGuardClears() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let resolver = MALEntityResolver(store: store, search: { _ in
            [MALCandidate(malId: 20, titles: ["Attack on Titan"]), MALCandidate(malId: 10, titles: ["Completely Different"])]
        }, bridgeSearch: MALEntityResolver.noBridge)
        let work = makeWork(["Attack on Titan"])
        let candidates = try await resolver.candidates(for: work)
        let resolution = try await resolver.resolve(work)
        XCTAssertEqual(candidates.first?.malID, resolution.malId)
    }

    func testAmbiguousCandidatesAreListedButResolveRefuses() async throws {
        let resolver = MALEntityResolver(store: EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                         search: { _ in [MALCandidate(malId: 1, titles: ["Berserk"]),
                                                        MALCandidate(malId: 2, titles: ["Berserk"])] },
                                         bridgeSearch: MALEntityResolver.noBridge)
        let work = makeWork(["Berserk"])
        let candidates = try await resolver.candidates(for: work)
        XCTAssertEqual(candidates.map(\.malID), [1, 2])
        XCTAssertTrue(candidates.allSatisfy(\.isAmbiguous))
        let resolution = try await resolver.resolve(work)
        XCTAssertNil(resolution.malId)
    }

    func testLocalMatchRequiresConfirmationForUniqueExactCandidate() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let resolver = MALEntityResolver(store: store, search: { _ in [MALCandidate(malId: 7, titles: ["Yotsuba!"])] },
                                         bridgeSearch: MALEntityResolver.noBridge)
        let work = makeWork(["Yotsuba!"])
        let candidates = try await resolver.candidates(for: work)
        XCTAssertEqual(candidates.first?.malID, 7)
        XCTAssertTrue(store.cache.isEmpty)
        XCTAssertNil(work.externalIds.mal)
        XCTAssertEqual(work.knownTitles, ["Yotsuba!"])
    }

    func testCandidatesAreOrderedByScoreThenMALIDAndSearchDespiteKnownID() async throws {
        let resolver = MALEntityResolver(store: EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                         search: { _ in [MALCandidate(malId: 9, titles: ["Berserk"]),
                                                        MALCandidate(malId: 3, titles: ["Berserk"])] },
                                         bridgeSearch: MALEntityResolver.noBridge)
        let candidates = try await resolver.candidates(for: makeWork(["Berserk"], mal: 99))
        XCTAssertEqual(candidates.map(\.malID), [3, 9])
    }

    func testCandidatesThrowOnFailedSearch() async {
        enum Failure: Error { case expected }
        let resolver = MALEntityResolver(store: EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                         search: { _ in throw Failure.expected }, bridgeSearch: MALEntityResolver.noBridge)
        do {
            _ = try await resolver.candidates(for: makeWork(["Berserk"]))
            XCTFail("expected search error")
        } catch {
            XCTAssertTrue(error is Failure)
        }
    }

    func testCandidateAtAcceptanceThresholdIsIncluded() async throws {
        let matcher = MALTitleMatcher(acceptanceThreshold: 0.9)
        let resolver = MALEntityResolver(store: EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                         matcher: matcher,
                                         search: { _ in [MALCandidate(malId: 8, titles: ["abcdefghiX"])] },
                                         bridgeSearch: MALEntityResolver.noBridge)
        let candidates = try await resolver.candidates(for: makeWork(["abcdefghij"]))
        XCTAssertEqual(candidates.map(\.malID), [8])
        XCTAssertEqual(candidates.first?.score ?? 0, 0.9, accuracy: 0.000_001)
    }

    func testCandidatesFlagNearMissRunnerUpAsAmbiguous() async throws {
        let source = "abcdefghijklmnopqrstuvwxyz"
        let accepted = "xbcdxfghijklmnopqrstuvwxyz"
        let nearMiss = "xbcdxfghijklmnoXqrstuvwxyz"
        let acceptedScore = MALTitleMatcher.similarity(source, accepted)
        let nearMissScore = MALTitleMatcher.similarity(source, nearMiss)
        XCTAssertEqual(acceptedScore, 24.0 / 26.0, accuracy: 0.000_001)
        XCTAssertEqual(nearMissScore, 23.0 / 26.0, accuracy: 0.000_001)

        let resolver = MALEntityResolver(
            store: EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            search: { _ in [MALCandidate(malId: 1, titles: [accepted]),
                            MALCandidate(malId: 2, titles: [nearMiss])] },
            bridgeSearch: MALEntityResolver.noBridge)
        let work = makeWork([source])
        let resolution = try await resolver.resolve(work)
        let candidates = try await resolver.candidates(for: work)
        XCTAssertNil(resolution.malId)
        XCTAssertEqual(candidates.map(\.malID), [1])
        XCTAssertEqual(candidates.first?.score ?? 0, acceptedScore, accuracy: 0.000_001)
        XCTAssertTrue(candidates.first?.isAmbiguous == true)
    }

    func testBridgeCandidatesExcludeIDLessRowsAndDoNotRunForMangaDexWork() async throws {
        var bridgeCalls = 0
        let idBearing = Manga(id: "with-id", sourceId: "bridge", title: "Cowboy Bebop",
                              description: "", status: "finished", year: nil, coverURL: nil, malId: 42)
        let idLess = Manga(id: "without-id", sourceId: "bridge", title: "Cowboy Bebop",
                           description: "", status: "finished", year: nil, coverURL: nil, malId: nil)
        let resolver = MALEntityResolver(
            store: EntityResolutionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            search: { _ in [] },
            bridgeSearch: { _ in bridgeCalls += 1; return [idLess, idBearing] })
        let candidates = try await resolver.candidates(for: makeWork(["Cowboy Bebop"]))
        XCTAssertEqual(candidates.map(\.malID), [42])
        XCTAssertFalse(candidates[0].isAmbiguous)
        XCTAssertEqual(bridgeCalls, 1)

        bridgeCalls = 0
        let mangaDexWork = makeWork(["Cowboy Bebop"], listings: [
            ListingKey(sourceId: LegacySourceID.unattributed, mangaId: "existing")
        ])
        let mangaDexCandidates = try await resolver.candidates(for: mangaDexWork)
        XCTAssertTrue(mangaDexCandidates.isEmpty)
        XCTAssertEqual(bridgeCalls, 0)
    }
}
