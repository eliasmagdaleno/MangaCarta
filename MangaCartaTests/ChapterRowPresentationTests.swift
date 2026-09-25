//
//  ChapterRowPresentationTests.swift
//  MangaCartaTests
//
//  Issue #90, checklist rows 4.1 / 4.2. `ChapterRow` used to publish no accessibility
//  label at all: its three `Text`s became three focus stops, and read state was carried
//  only by a dim foreground colour — which DESIGN.md's "Focus / State" rule forbids and
//  VoiceOver cannot perceive at all.
//
//  The fix is this pure value, so the thing VoiceOver says is testable without a view.
//  The load-bearing test is `testStateIsAlwaysSpoken`: it walks the whole input space and
//  asserts every row says which of read / unread / in-progress it is, so a fourth state
//  added later cannot reintroduce a silently colour-only row.
//

import XCTest
@testable import MangaCarta

final class ChapterRowPresentationTests: XCTestCase {

    private let chapter = Chapter(id: "c1", number: "12", title: "Blood and Ink",
                                  date: Date(timeIntervalSince1970: 1_754_179_200))

    private func entry(page: Int, pageCount: Int) -> ReadingEntry {
        ReadingEntry(id: UUID(), mangaId: "m1", mangaTitle: "T", coverURL: nil,
                     chapterId: chapter.id, chapterNumber: chapter.number,
                     page: page, pageCount: pageCount, updatedAt: Date())
    }

    // MARK: - The invariant

    /// Read state must be *spoken*, never left to colour. Walked over the whole input
    /// space rather than the three states we happen to have thought of.
    func testStateIsAlwaysSpoken() {
        let entries: [ReadingEntry?] = [nil, entry(page: 0, pageCount: 0),
                                        entry(page: 3, pageCount: 20),
                                        entry(page: 19, pageCount: 20)]
        for isRead in [true, false] {
            for progress in entries {
                let p = ChapterRowPresentation(chapter: chapter, progress: progress, isRead: isRead)
                let spoken = ["Read", "Unread", "In progress"].contains { p.accessibilityLabel.contains($0) }
                XCTAssertTrue(spoken,
                              "state must be spoken (isRead: \(isRead), page: \(progress?.page.description ?? "nil")): " +
                              p.accessibilityLabel)
            }
        }
    }

    // MARK: - Label content

    func testLabelLeadsWithChapterAndTitle() {
        let p = ChapterRowPresentation(chapter: chapter, progress: nil, isRead: false)
        XCTAssertTrue(p.accessibilityLabel.hasPrefix("Chapter 12, Blood and Ink"), p.accessibilityLabel)
    }

    func testGroupCreditJoinsNamesAndIsIncludedInAccessibilityLabel() {
        let chapter = Chapter(id: "c-groups", number: "13", title: nil, groups: ["Alpha", "  Beta "])
        let p = ChapterRowPresentation(chapter: chapter, progress: nil, isRead: false)
        XCTAssertEqual(p.groupCredit, "Alpha, Beta")
        XCTAssertTrue(p.accessibilityLabel.contains("Scanlation group: Alpha, Beta"), p.accessibilityLabel)
    }

    func testMissingOrEmptyGroupCreditIsNotShown() {
        for groups in [nil, [], [""]] as [[String]?] {
            let chapter = Chapter(id: "c-groups", number: "13", title: nil, groups: groups)
            let p = ChapterRowPresentation(chapter: chapter, progress: nil, isRead: false)
            XCTAssertNil(p.groupCredit, "unexpected credit for \(String(describing: groups))")
            XCTAssertFalse(p.accessibilityLabel.contains("Scanlation group"), p.accessibilityLabel)
        }
    }

    /// The stamp reads "CH·12" on screen; the middle dot must not reach VoiceOver.
    func testLabelNeverContainsTheTypographicStamp() {
        let p = ChapterRowPresentation(chapter: chapter, progress: nil, isRead: false)
        XCTAssertFalse(p.accessibilityLabel.contains("·"), p.accessibilityLabel)
        XCTAssertFalse(p.accessibilityLabel.contains("CH"), p.accessibilityLabel)
    }

    func testUntitledChapterFallsBackToItsNumber() {
        let untitled = Chapter(id: "c2", number: "7", title: nil, date: nil)
        let p = ChapterRowPresentation(chapter: untitled, progress: nil, isRead: false)
        XCTAssertEqual(p.accessibilityLabel, "Chapter 7, Unread")
    }

    /// An empty title is the same absence as a nil one — the view already treats it so.
    func testEmptyTitleIsTreatedAsNoTitle() {
        let blank = Chapter(id: "c3", number: "7", title: "", date: nil)
        let p = ChapterRowPresentation(chapter: blank, progress: nil, isRead: false)
        XCTAssertEqual(p.accessibilityLabel, "Chapter 7, Unread")
    }

    func testInProgressSpeaksThePageAndTotal() {
        let p = ChapterRowPresentation(chapter: chapter, progress: entry(page: 3, pageCount: 20),
                                       isRead: false)
        XCTAssertTrue(p.accessibilityLabel.contains("In progress, page 4 of 20"), p.accessibilityLabel)
    }

    func testReadChapterSaysRead() {
        let p = ChapterRowPresentation(chapter: chapter,
                                       progress: entry(page: 19, pageCount: 20), isRead: true)
        XCTAssertTrue(p.accessibilityLabel.contains("Read"), p.accessibilityLabel)
        XCTAssertFalse(p.accessibilityLabel.contains("In progress"), p.accessibilityLabel)
    }

    // MARK: - Agreement with the visuals

    /// The label and the dimming must never disagree: whatever the eye is told, the ear
    /// is told too. This is the pairing the old code broke.
    func testDimmedRowsAreExactlyTheOnesThatSayRead() {
        let entries: [ReadingEntry?] = [nil, entry(page: 0, pageCount: 0),
                                        entry(page: 3, pageCount: 20),
                                        entry(page: 19, pageCount: 20)]
        for isRead in [true, false] {
            for progress in entries {
                let p = ChapterRowPresentation(chapter: chapter, progress: progress, isRead: isRead)
                XCTAssertEqual(p.isDimmed, p.accessibilityLabel.contains("Read")
                               && !p.accessibilityLabel.contains("In progress"),
                               "dimming and speech disagree: \(p.accessibilityLabel)")
            }
        }
    }

    /// A read chapter reopened and left mid-way is in progress, not read — the same rule
    /// `ChapterRow`'s resume marker already followed.
    func testReopenedReadChapterReadsAsInProgress() {
        let p = ChapterRowPresentation(chapter: chapter, progress: entry(page: 3, pageCount: 20),
                                       isRead: true)
        XCTAssertTrue(p.isInProgress)
        XCTAssertFalse(p.isDimmed)
        XCTAssertTrue(p.accessibilityLabel.contains("In progress"), p.accessibilityLabel)
    }

    /// An entry recorded before any page loaded has a count of 0 — neither finished nor
    /// mid-read. It must not claim "page 1 of 0".
    func testZeroPageCountEntryIsNotInProgress() {
        let p = ChapterRowPresentation(chapter: chapter, progress: entry(page: 0, pageCount: 0),
                                       isRead: false)
        XCTAssertFalse(p.isInProgress)
        XCTAssertFalse(p.accessibilityLabel.contains("In progress"), p.accessibilityLabel)
    }

    // MARK: - Selection

    func testSelectionValueIsSpokenOnlyWhileSelecting() {
        let p = ChapterRowPresentation(chapter: chapter, progress: nil, isRead: false)
        XCTAssertNil(p.accessibilityValue(selecting: false, selected: true))
        XCTAssertEqual(p.accessibilityValue(selecting: true, selected: true), "Selected")
        XCTAssertEqual(p.accessibilityValue(selecting: true, selected: false), "Not selected")
    }
}
