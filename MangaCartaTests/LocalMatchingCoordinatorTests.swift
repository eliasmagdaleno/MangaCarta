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
