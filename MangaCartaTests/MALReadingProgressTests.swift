//
//  MALReadingProgressTests.swift
//  MangaCartaTests
//
//  Pure mapping from source chapter labels to MAL's integer progress.
//

import XCTest
@testable import MangaCarta

final class MALReadingProgressTests: XCTestCase {
    @MainActor
    private func makeWorkStore() -> WorkStore {
        WorkStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MALReadingProgressTests-\(UUID().uuidString)"))
    }

    private func makeDefaults() -> UserDefaults {
        makeTestDefaults("test.mal-progress")
    }

    private func manga() -> Manga {
        Manga(id: "listing-1", sourceId: "mangadex", title: "Example", description: "",
              status: "ongoing", year: nil, coverURL: nil, malId: 42)
    }

    func testWholeNumberChapterMapsToTheSameProgress() {
        XCTAssertEqual(MALChapterProgress.map(chapterNumber: "12"), 12)
    }

    func testEligibleLabelsMapToCompletedWholeChapters() {
        XCTAssertEqual(MALChapterProgress.map(chapterNumber: " 12 "), 12)
        XCTAssertEqual(MALChapterProgress.map(chapterNumber: "12.5"), 12)
    }

    func testIneligibleLabelsDoNotProduceProgress() {
        for label in ["0", "0.5", "-1", "-1.5", "", "Special", "1-2", "1,5",
                      "999999999999999999999999999999999999999"] {
            XCTAssertNil(MALChapterProgress.map(chapterNumber: label), label)
        }
    }

    @MainActor
    func testFinishingAChapterEmitsOneCompletionWithTheMintedWork() throws {
        let works = makeWorkStore()
        var completions: [ChapterCompletion] = []
        let store = HistoryStore(defaults: makeDefaults(), works: works,
                                 chapterCompleted: { completions.append($0) })
        let chapter = Chapter(id: "chapter-12", number: "12.5", title: nil)
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        store.record(manga: manga(), chapter: chapter, position: ReadingPosition(page: 0),
                     pageCount: 5)
        store.record(manga: manga(), chapter: chapter, position: ReadingPosition(page: 4),
                     pageCount: 5, at: completedAt)
        store.record(manga: manga(), chapter: chapter, position: ReadingPosition(page: 4),
                     pageCount: 5, at: completedAt.addingTimeInterval(1))

        let completion = try XCTUnwrap(completions.first)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completion.manga, manga())
        XCTAssertEqual(completion.chapter, chapter)
        XCTAssertEqual(completion.workID,
                       works.workId(for: ListingKey(sourceId: "mangadex", mangaId: "listing-1")))
        XCTAssertEqual(completion.progress, 12)
        XCTAssertEqual(completion.completedAt, completedAt)
    }

    @MainActor
    func testOpeningAChapterMintsItsWorkWithoutEmittingACompletion() {
        let works = makeWorkStore()
        var completions: [ChapterCompletion] = []
        let store = HistoryStore(defaults: makeDefaults(), works: works,
                                 chapterCompleted: { completions.append($0) })

        store.record(manga: manga(), chapter: Chapter(id: "chapter-1", number: "1", title: nil),
                     position: ReadingPosition(page: 0), pageCount: 5)

        XCTAssertNotNil(works.workId(for: ListingKey(manga())))
        XCTAssertFalse(store.isRead(chapterId: "chapter-1"))
        XCTAssertTrue(completions.isEmpty)
    }

    @MainActor
    func testManualReadStateChangesAndHistoryRemovalNeverEmitCompletions() throws {
        let works = makeWorkStore()
        var completions: [ChapterCompletion] = []
        let store = HistoryStore(defaults: makeDefaults(), works: works,
                                 chapterCompleted: { completions.append($0) })
        let first = Chapter(id: "chapter-1", number: "1", title: nil)
        let second = Chapter(id: "chapter-2", number: "2", title: nil)

        store.record(manga: manga(), chapter: first, position: ReadingPosition(page: 0),
                     pageCount: 5)
        store.markRead(manga: manga(), chapter: first)
        store.markUnread(manga: manga(), chapter: first)
        store.toggleRead(manga: manga(), chapter: first)
        store.toggleRead(manga: manga(), chapter: first)
        store.markRead(manga: manga(), chapters: [first, second])
        store.markUnread(manga: manga(), chapters: [first, second])
        store.record(manga: manga(), chapter: second, position: ReadingPosition(page: 0),
                     pageCount: 5)
        store.delete(try XCTUnwrap(store.entries.first))
        store.clear()

        XCTAssertTrue(completions.isEmpty)
    }

    @MainActor
    func testCompletionWithAnUnmappableChapterLabelDoesNotEmit() {
        let works = makeWorkStore()
        var completions: [ChapterCompletion] = []
        let store = HistoryStore(defaults: makeDefaults(), works: works,
                                 chapterCompleted: { completions.append($0) })

        store.record(manga: manga(),
                     chapter: Chapter(id: "chapter-special", number: "Special", title: nil),
                     position: ReadingPosition(page: 4), pageCount: 5)

        XCTAssertTrue(store.isRead(chapterId: "chapter-special"))
        XCTAssertTrue(completions.isEmpty)
    }
}
