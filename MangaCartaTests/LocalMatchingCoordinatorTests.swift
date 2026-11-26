import XCTest
@testable import MangaCarta

final class LocalMatchingCoordinatorTests: XCTestCase {
    func testLocalEvidenceUsesTitlesNotChapterNumbers() {
        let item = LocalItemRecord(itemId: "x", title: "ignored", sourceFilename: "Series_12.cbz",
                                   sha256: "", byteSize: 1, importedAt: Date(), chapters: [],
                                   comicInfo: ComicInfo(series: " Series ", title: "Chapter 12", number: "12",
                                                        volume: "3", summary: nil, writer: nil, genres: [],
                                                        frontCoverPageIndex: nil))
        XCTAssertEqual(LocalTitleEvidence(items: [item]).titles, ["Series", "Chapter 12", "Series 12"])
    }

    func testEvidenceDeduplicatesAndKeepsOrder() {
        let item = LocalItemRecord(itemId: "x", title: "", sourceFilename: "Series.cbz", sha256: "",
                                   byteSize: 1, importedAt: Date(), chapters: [],
                                   comicInfo: ComicInfo(series: "Series", title: "Series", number: "1", volume: "1",
                                                        summary: nil, writer: nil, genres: [], frontCoverPageIndex: nil))
        XCTAssertEqual(LocalTitleEvidence(items: [item]).titles, ["Series"])
    }
}

@MainActor
final class MALEntityResolverTests: XCTestCase {
    private func makeWork(_ titles: [String], mal: Int? = nil) -> Work {
        Work(id: WorkID(), displayTitle: titles.first ?? "", knownTitles: titles,
             externalIds: ExternalIDs(mal: mal, anilist: nil), listings: [])
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
}
