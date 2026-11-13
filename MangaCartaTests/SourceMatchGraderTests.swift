import XCTest
@testable import MangaCarta

final class SourceMatchGraderTests: XCTestCase {
    private func manga(_ mal: Int?, title: String = "Title") -> Manga {
        Manga(id: UUID().uuidString, sourceId: "b", title: title, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: mal)
    }

    func testSameMalIdIsSameEntry() {
        let result = SourceMatchGrader.grade(referenceMALID: 7, spellings: ["Title"], candidate: manga(7))
        XCTAssertEqual(result, .sameEntry)
    }
    func testDifferentMalIdIsDifferentEntry() {
        let result = SourceMatchGrader.grade(referenceMALID: 7, spellings: ["Title"], candidate: manga(8))
        XCTAssertEqual(result, .differentEntry)
    }
    func testThresholdTitleIsLikely() {
        let matcher = MALTitleMatcher(acceptanceThreshold: 1)
        let result = SourceMatchGrader.grade(referenceMALID: nil, spellings: ["The Great Title"],
            candidate: manga(nil, title: "The Great Title"), matcher: matcher)
        XCTAssertEqual(result, .likely)
    }
    func testOtherwiseUngraded() {
        let result = SourceMatchGrader.grade(referenceMALID: nil, spellings: ["One"],
            candidate: manga(nil, title: "Completely Different"))
        XCTAssertEqual(result, .ungraded)
    }
}
