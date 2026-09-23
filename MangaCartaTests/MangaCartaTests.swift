//
//  MangaCartaTests.swift
//  MangaCartaTests
//
//  Created by Elias Magdaleno on 5/31/24.
//

import XCTest
import UIKit
@testable import MangaCarta

// This legacy integration suite intentionally keeps shared helpers and state in one XCTestCase.
// Splitting it solely for lint would require project-file churn without changing test coverage.
// swiftlint:disable:next type_body_length
final class MangaCartaTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

    // MARK: - HistoryStore

    @MainActor
    private func makeHistoryStore() -> HistoryStore {
        let suite = UserDefaults(suiteName: "test.history.\(UUID().uuidString)")!
        return HistoryStore(defaults: suite)
    }

    private func sampleManga(_ id: String = "m1", sourceId: String = "mangadex") -> Manga {
        Manga(id: id, sourceId: sourceId, title: "Title \(id)", description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
    }

    /// A bare entry for exercising `isComplete`, whose only inputs are `page` and `pageCount`.
    private func sampleEntry(page: Int, pageCount: Int) -> ReadingEntry {
        ReadingEntry(id: UUID(), mangaId: "m", mangaTitle: "T", coverURL: nil, chapterId: "c",
                     chapterNumber: "1", page: page, pageCount: pageCount, updatedAt: Date())
    }

    @MainActor func testRecordPrependsNewEntry() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga(), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 2), pageCount: 10)
        store.record(manga: sampleManga(), chapter: Chapter(id: "c2", number: "2", title: nil),
                     position: ReadingPosition(page: 0), pageCount: 8)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.chapterId, "c2") // most-recent-first
    }

    @MainActor func testRecordSameChapterUpdatesInPlace() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga(), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 2), pageCount: 10)
        store.record(manga: sampleManga(), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 5), pageCount: 10)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.page, 5)
    }

    @MainActor func testRecordNonConsecutiveChapterCreatesNewEntry() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga(), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 1), pageCount: 10)
        store.record(manga: sampleManga(), chapter: Chapter(id: "c2", number: "2", title: nil),
                     position: ReadingPosition(page: 1), pageCount: 10)
        store.record(manga: sampleManga(), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 3), pageCount: 10) // reopened later
        XCTAssertEqual(store.entries.count, 3)          // new session, not an in-place update
        XCTAssertEqual(store.entries.first?.chapterId, "c1")
        XCTAssertEqual(store.entries.first?.page, 3)
    }

    @MainActor func testLatestEntryForManga() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga("a"), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 1), pageCount: 10)
        store.record(manga: sampleManga("b"), chapter: Chapter(id: "c2", number: "1", title: nil),
                     position: ReadingPosition(page: 1), pageCount: 10)
        XCTAssertEqual(store.latestEntry(forManga: "a")?.chapterId, "c1")
        XCTAssertNil(store.latestEntry(forManga: "zzz"))
    }

    @MainActor func testDeleteAndClear() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga(), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 1), pageCount: 10)
        let entry = store.entries[0]
        store.delete(entry)
        XCTAssertTrue(store.entries.isEmpty)
        store.record(manga: sampleManga(), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 1), pageCount: 10)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor func testReadingEntryRecordsSourceId() {
        let store = makeHistoryStore()
        let manga = sampleManga("m", sourceId: "weebcentral")
        store.record(manga: manga, chapter: Chapter(id: "c1", number: "1", title: nil), position: ReadingPosition(page: 0), pageCount: 5)
        XCTAssertEqual(store.entries.first?.sourceId, "weebcentral")
    }

    /// ADR-0018: MangaDex hands back `links.mal` on the request the app already makes,
    /// and history is where that id used to be dropped.
    @MainActor func testReadingEntryRecordsMalIdFromListing() {
        let store = makeHistoryStore()
        let manga = Manga(id: "orv", sourceId: "mangadex", title: "Omniscient Reader",
                          description: "", status: "ongoing", year: nil, coverURL: nil,
                          malId: 132214)
        store.record(manga: manga, chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 0), pageCount: 5)
        XCTAssertEqual(store.entries.first?.malId, 132214)
    }

    /// A source with no external id of its own is unchanged — the field is absent, not zero.
    @MainActor func testReadingEntryRecordsNoMalIdWhenSourcePublishesNone() {
        let store = makeHistoryStore()
        store.record(manga: sampleManga("m", sourceId: "weebcentral"),
                     chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 0), pageCount: 5)
        XCTAssertNil(store.entries.first?.malId)
    }

    func testReadingEntryDecodesLegacyJSONAsNil() throws {
        // JSON saved before sourceId existed.
        let legacy = (
            #"{"id":"00000000-0000-0000-0000-000000000000","mangaId":"m","mangaTitle":"T","coverURL":null,"#
                + #""chapterId":"c","chapterNumber":"1","page":0,"pageCount":5,"updatedAt":0}"#
        ).data(using: .utf8)!
        let entry = try JSONDecoder().decode(ReadingEntry.self, from: legacy)
        XCTAssertNil(entry.sourceId)
        // ADR-0018: and before malId existed. Every entry already on disk is one of these.
        XCTAssertNil(entry.malId)
    }

    // MARK: - Chapter ordering & resume

    private func ch(_ n: String, _ id: String? = nil) -> Chapter {
        Chapter(id: id ?? "id\(n)", number: n, title: nil)
    }

    func testNumericChapterValue() {
        XCTAssertEqual(numericChapterValue("10.5"), 10.5)
        XCTAssertNil(numericChapterValue("?"))
    }

    func testSortChaptersNumeric() {
        let input = [ch("2"), ch("10"), ch("1"), ch("10.5"), ch("?")]
        let asc = sortChapters(input, descending: false).map(\.number)
        XCTAssertEqual(asc, ["1", "2", "10", "10.5", "?"])   // unparseable sorts last
        let desc = sortChapters(input, descending: true).map(\.number)
        XCTAssertEqual(desc, ["10.5", "10", "2", "1", "?"])  // unparseable still last
    }

    func testNextChapter() {
        let asc = [ch("1"), ch("2"), ch("3")]
        XCTAssertEqual(nextChapter(after: "2", in: asc)?.number, "3")
        XCTAssertNil(nextChapter(after: "3", in: asc))
    }

    func testResumeActionNoHistory() {
        let action = resumeAction(entry: nil, chapters: [ch("2"), ch("1")])
        XCTAssertEqual(action, .start(ch("1")))
    }

    func testResumeActionMidChapter() {
        let entry = ReadingEntry(id: UUID(), mangaId: "m", mangaTitle: "t", coverURL: nil,
                                 chapterId: "id2", chapterNumber: "2", page: 3, pageCount: 10, updatedAt: Date())
        XCTAssertEqual(resumeAction(entry: entry, chapters: [ch("1"), ch("2"), ch("3")]),
                       .cont(ch("2"), position: ReadingPosition(page: 3)))
    }

    func testResumeActionFinishedJumpsToNext() {
        let entry = ReadingEntry(id: UUID(), mangaId: "m", mangaTitle: "t", coverURL: nil,
                                 chapterId: "id2", chapterNumber: "2", page: 9, pageCount: 10, updatedAt: Date())
        XCTAssertEqual(resumeAction(entry: entry, chapters: [ch("1"), ch("2"), ch("3")]),
                       .next(ch("3")))
    }

    func testResumeActionFinishedLatestRereads() {
        let entry = ReadingEntry(id: UUID(), mangaId: "m", mangaTitle: "t", coverURL: nil,
                                 chapterId: "id3", chapterNumber: "3", page: 9, pageCount: 10, updatedAt: Date())
        XCTAssertEqual(resumeAction(entry: entry, chapters: [ch("1"), ch("2"), ch("3")]),
                       .reread(ch("3")))
    }

    // MARK: - Library updates

    func testUnreadCountNilChapterNumbersIsZero() {
        let item = LibraryItem(id: "m1", title: "T", coverURL: nil, chapterNumbers: nil)
        XCTAssertEqual(item.unreadCount(readNumbers: []), 0)
    }

    func testUnreadCountWithNoneReadCountsAll() {
        let item = LibraryItem(id: "m1", title: "T", coverURL: nil, chapterNumbers: ["1", "2", "3"])
        XCTAssertEqual(item.unreadCount(readNumbers: []), 3)
    }

    func testUnreadCountExcludesReadNumbers() {
        let item = LibraryItem(id: "m1", title: "T", coverURL: nil, chapterNumbers: ["1", "2", "3"])
        XCTAssertEqual(item.unreadCount(readNumbers: ["2"]), 2)
    }

    func testUnreadCountAllReadIsZero() {
        let item = LibraryItem(id: "m1", title: "T", coverURL: nil, chapterNumbers: ["1", "2"])
        XCTAssertEqual(item.unreadCount(readNumbers: ["1", "2"]), 0)
    }

    @MainActor func testReadChapterNumbersForManga() throws {
        let store = makeHistoryStore()
        // Both read to the end — this test is about manga scoping, so keep the read rule
        // itself out of it (`testReadChapterNumbersExcludesUnfinishedChapters` covers that).
        store.record(manga: sampleManga("m"), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 4), pageCount: 5)
        store.record(manga: sampleManga("m"), chapter: Chapter(id: "c2", number: "2", title: nil),
                     position: ReadingPosition(page: 4), pageCount: 5)
        XCTAssertEqual(store.readChapterNumbers(forManga: "m"), ["1", "2"])
        XCTAssertTrue(store.readChapterNumbers(forManga: "other").isEmpty)
    }

    // MARK: - Read / unread marks

    /// Inverted 2026-08-20. This used to assert that *opening* a chapter made it read.
    /// That is what made the Bookmarks unread badge undercount: abandoning chapter 5 on
    /// page 1 stopped it counting as unread. "Read" now means read to the end.
    @MainActor func testOpenedButUnfinishedChapterIsNotRead() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga("m"), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 0), pageCount: 5)
        XCTAssertFalse(store.isRead(chapterId: "c1"))      // opened, not finished
        XCTAssertFalse(store.isRead(chapterId: "c2"))      // never opened at all
    }

    @MainActor func testChapterReadToTheEndIsRead() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga("m"), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 4), pageCount: 5)
        XCTAssertTrue(store.isRead(chapterId: "c1"))
    }

    // MARK: - ReadingEntry.isComplete

    func testIsCompleteOnLastPage() {
        XCTAssertTrue(sampleEntry(page: 4, pageCount: 5).isComplete)
    }

    func testIsIncompleteOnePageShort() {
        XCTAssertFalse(sampleEntry(page: 3, pageCount: 5).isComplete)
    }

    /// An entry recorded before any page loaded has `pageCount` 0, and `page >= -1` would
    /// otherwise call that finished.
    func testIsIncompleteWhenNoPagesLoaded() {
        XCTAssertFalse(sampleEntry(page: 0, pageCount: 0).isComplete)
    }

    /// The badge reads this set, so an abandoned chapter has to stay out of it.
    @MainActor func testReadChapterNumbersExcludesUnfinishedChapters() throws {
        let store = makeHistoryStore()
        store.record(manga: sampleManga("m"), chapter: Chapter(id: "c1", number: "1", title: nil),
                     position: ReadingPosition(page: 4), pageCount: 5)
        store.record(manga: sampleManga("m"), chapter: Chapter(id: "c2", number: "2", title: nil),
                     position: ReadingPosition(page: 1), pageCount: 5)
        XCTAssertEqual(store.readChapterNumbers(forManga: "m"), ["1"])
    }

    /// A manual mark outranks completion — that is the whole point of marking.
    @MainActor func testManualMarkMakesAnUnfinishedChapterRead() throws {
        let store = makeHistoryStore()
        let chapter = Chapter(id: "c1", number: "1", title: nil)
        store.record(manga: sampleManga("m"), chapter: chapter, position: ReadingPosition(page: 0), pageCount: 5)
        XCTAssertFalse(store.isRead(chapterId: "c1"))
        store.markRead(manga: sampleManga("m"), chapter: chapter)
        XCTAssertTrue(store.isRead(chapterId: "c1"))
    }

    @MainActor func testMarkReadWithoutOpening() throws {
        let store = makeHistoryStore()
        let chapter = Chapter(id: "c1", number: "3", title: nil)
        XCTAssertFalse(store.isRead(chapterId: "c1"))
        store.markRead(manga: sampleManga("m"), chapter: chapter)
        XCTAssertTrue(store.isRead(chapterId: "c1"))
        // Manual mark contributes to the shared read-numbers set (badge reconciliation).
        XCTAssertEqual(store.readChapterNumbers(forManga: "m"), ["3"])
        // ...but never pollutes the chronological reading log.
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor func testMarkReadIsIdempotent() throws {
        let store = makeHistoryStore()
        let chapter = Chapter(id: "c1", number: "1", title: nil)
        store.markRead(manga: sampleManga("m"), chapter: chapter)
        store.markRead(manga: sampleManga("m"), chapter: chapter)
        XCTAssertEqual(store.readMarks.count, 1)
    }

    @MainActor func testMarkUnreadClearsBothMarkAndHistory() throws {
        let store = makeHistoryStore()
        let chapter = Chapter(id: "c1", number: "1", title: nil)
        store.record(manga: sampleManga("m"), chapter: chapter, position: ReadingPosition(page: 2), pageCount: 5) // opened
        store.markRead(manga: sampleManga("m"), chapter: chapter)                       // and marked
        XCTAssertTrue(store.isRead(chapterId: "c1"))

        store.markUnread(manga: sampleManga("m"), chapter: chapter)
        XCTAssertFalse(store.isRead(chapterId: "c1"))                 // no longer read
        XCTAssertTrue(store.entries.isEmpty)                          // history entry removed
        XCTAssertTrue(store.readChapterNumbers(forManga: "m").isEmpty)
    }

    @MainActor func testToggleReadRoundTrips() throws {
        let store = makeHistoryStore()
        let chapter = Chapter(id: "c1", number: "1", title: nil)
        store.toggleRead(manga: sampleManga("m"), chapter: chapter)
        XCTAssertTrue(store.isRead(chapterId: "c1"))
        store.toggleRead(manga: sampleManga("m"), chapter: chapter)
        XCTAssertFalse(store.isRead(chapterId: "c1"))
    }

    @MainActor func testMarkReadBatchMarksAllGivenChapters() throws {
        let store = makeHistoryStore()
        let chapters = [Chapter(id: "c1", number: "1", title: nil), Chapter(id: "c2", number: "2", title: nil)]
        store.markRead(manga: sampleManga("m"), chapters: chapters)
        XCTAssertTrue(store.isRead(chapterId: "c1"))
        XCTAssertTrue(store.isRead(chapterId: "c2"))
        XCTAssertEqual(store.readChapterNumbers(forManga: "m"), ["1", "2"])
    }

    @MainActor func testMarkReadBatchIsIdempotent() throws {
        let store = makeHistoryStore()
        let chapter = Chapter(id: "c1", number: "1", title: nil)
        store.markRead(manga: sampleManga("m"), chapters: [chapter])
        store.markRead(manga: sampleManga("m"), chapters: [chapter])
        XCTAssertEqual(store.readMarks.count, 1)
    }

    @MainActor func testMarkReadBatchIsIdempotentWithinSingleCallDuplicates() throws {
        let store = makeHistoryStore()
        let chapter = Chapter(id: "c1", number: "1", title: nil)
        store.markRead(manga: sampleManga("m"), chapters: [chapter, chapter])
        XCTAssertEqual(store.readMarks.count, 1)
    }

    @MainActor func testMarkUnreadBatchClearsOnlyGivenChapters() throws {
        let store = makeHistoryStore()
        let manga = sampleManga("m")
        let c1 = Chapter(id: "c1", number: "1", title: nil)
        let c2 = Chapter(id: "c2", number: "2", title: nil)
        let c3 = Chapter(id: "c3", number: "3", title: nil)
        store.record(manga: manga, chapter: c1, position: ReadingPosition(page: 2), pageCount: 5)  // opened
        store.markRead(manga: manga, chapter: c2)                       // manually marked
        store.markRead(manga: manga, chapter: c3)                       // manually marked, untouched below

        store.markUnread(manga: manga, chapters: [c1, c2])
        XCTAssertFalse(store.isRead(chapterId: "c1"))
        XCTAssertFalse(store.isRead(chapterId: "c2"))
        XCTAssertTrue(store.isRead(chapterId: "c3"))                    // not in the batch, stays read
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.readChapterNumbers(forManga: "m"), ["3"])
    }

    @MainActor func testReadMarksPersistAcrossReload() throws {
        let suite = UserDefaults(suiteName: "test.history.\(UUID().uuidString)")!
        let store = HistoryStore(defaults: suite)
        store.markRead(manga: sampleManga("m"), chapter: Chapter(id: "c1", number: "7", title: nil))

        let reloaded = HistoryStore(defaults: suite)
        XCTAssertTrue(reloaded.isRead(chapterId: "c1"))
        XCTAssertEqual(reloaded.readChapterNumbers(forManga: "m"), ["7"])
    }

    func testLibraryItemDecodesLegacyJSON() throws {
        // JSON saved before chapterNumbers existed (pre-migration installs).
        let legacy = #"{"id":"m1","title":"Old","coverURL":null}"#.data(using: .utf8)!
        let item = try JSONDecoder().decode(LibraryItem.self, from: legacy)
        XCTAssertEqual(item.id, "m1")
        XCTAssertNil(item.chapterNumbers)
        XCTAssertEqual(item.unreadCount(readNumbers: []), 0)
    }

    @MainActor func testLibraryToggleRecordsSourceId() {
        let suite = UserDefaults(suiteName: "test.library.\(UUID().uuidString)")!
        let store = LibraryStore(defaults: suite)
        let manga = sampleManga("m", sourceId: "weebcentral")
        store.toggle(manga)
        XCTAssertEqual(store.items.first?.sourceId, "weebcentral")
    }

    func testLibraryItemRoundTripsSourceId() throws {
        let item = LibraryItem(id: "m", title: "T", coverURL: nil, sourceId: "weebcentral")
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LibraryItem.self, from: data)
        XCTAssertEqual(decoded.sourceId, "weebcentral")
    }

    @MainActor func testLibraryDefaultCollectionsInitialized() {
        let suite = UserDefaults(suiteName: "test.lib.\(UUID().uuidString)")!
        let store = LibraryStore(defaults: suite)
        XCTAssertEqual(store.collections.count, 4)
        XCTAssertEqual(store.collections.map(\.id), ["reading", "on_hold", "planned", "dropped"])
    }

    func testLibraryItemMigrationDefaultsToReadingCollection() throws {
        // Simulates legacy LibraryItem JSON without collectionIds field
        let json = """
        {"id": "m1", "title": "Test Manga", "coverURL": null}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(LibraryItem.self, from: json)
        XCTAssertEqual(item.collectionIds, Set([LibraryCollection.readingID]))
    }

    @MainActor func testLibraryToggleCollectionAndMultiAssignment() {
        let suite = UserDefaults(suiteName: "test.lib.\(UUID().uuidString)")!
        let store = LibraryStore(defaults: suite)
        let manga = sampleManga("m1", sourceId: "mangadex")

        // Toggle collection adds to reading first by default
        store.toggle(manga)
        XCTAssertTrue(store.isManga("m1", in: LibraryCollection.readingID))

        // Add to on_hold collection as well (multi-assignment)
        store.toggleCollection(for: manga, collectionId: LibraryCollection.onHoldID)
        XCTAssertTrue(store.isManga("m1", in: LibraryCollection.readingID))
        XCTAssertTrue(store.isManga("m1", in: LibraryCollection.onHoldID))
        XCTAssertEqual(store.items(in: LibraryCollection.onHoldID).count, 1)

        // Toggling reading collection removes it from reading but leaves on_hold intact
        store.toggleCollection(for: manga, collectionId: LibraryCollection.readingID)
        XCTAssertFalse(store.isManga("m1", in: LibraryCollection.readingID))
        XCTAssertTrue(store.isManga("m1", in: LibraryCollection.onHoldID))
        XCTAssertTrue(store.contains("m1"))

        // Removing from on_hold leaves 0 collections, so item is removed from library
        store.toggleCollection(for: manga, collectionId: LibraryCollection.onHoldID)
        XCTAssertFalse(store.contains("m1"))
    }

    @MainActor func testLibraryCustomCollectionCRUD() {
        let suite = UserDefaults(suiteName: "test.lib.\(UUID().uuidString)")!
        let store = LibraryStore(defaults: suite)

        // Add custom collection
        store.addCustomCollection(name: "Favorites")
        XCTAssertEqual(store.collections.count, 5)
        guard let custom = store.collections.last else {
            XCTFail("Custom collection not found")
            return
        }
        XCTAssertEqual(custom.name, "Favorites")
        XCTAssertFalse(custom.isSystem)

        // Rename custom collection
        store.renameCustomCollection(id: custom.id, newName: "Top Favorites")
        XCTAssertEqual(store.collections.first(where: { $0.id == custom.id })?.name, "Top Favorites")

        // Disable collection
        store.setCollectionEnabled(id: custom.id, isEnabled: false)
        XCTAssertFalse(store.enabledCollections.contains(where: { $0.id == custom.id }))

        // Delete custom collection cleans up item assignments
        let manga = sampleManga("m2", sourceId: "mangadex")
        store.setCollections(for: manga, collectionIds: [custom.id])
        XCTAssertTrue(store.contains("m2"))

        store.deleteCustomCollection(id: custom.id)
        XCTAssertNil(store.collections.first(where: { $0.id == custom.id }))
        XCTAssertFalse(store.contains("m2"))
    }

    /// Records which manga ids it was asked to refresh, so a test can prove routing.
    private actor RefreshRoutingSource: MangaSource {
        let id: String
        let name: String
        private var asked: [String] = []

        init(id: String) {
            self.id = id
            self.name = id
        }

        func askedIds() -> [String] { asked }

        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }
        func chapters(mangaId: String) async throws -> [Chapter] {
            asked.append(mangaId)
            return [Chapter(id: "\(self.id)-c1", number: "1", title: nil)]
        }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }

    /// `refresh()` must ask each saved item's own source, not the active browse source —
    /// otherwise a WeebCentral slug gets sent to MangaDex whenever MangaDex is active.
    @MainActor func testRefreshAsksEachItemsOwnSource() async {
        let mangadex = RefreshRoutingSource(id: MangaDexSource.sourceID)
        let weebcentral = RefreshRoutingSource(id: "weebcentral")
        let registry = SourceRegistry(sources: [mangadex, weebcentral])
        registry.activeSourceID = MangaDexSource.sourceID

        let suite = UserDefaults(suiteName: "test.lib.\(UUID().uuidString)")!
        let store = LibraryStore(defaults: suite, registry: registry)
        store.toggle(sampleManga("md-1", sourceId: MangaDexSource.sourceID))
        store.toggle(sampleManga("wc-1", sourceId: "weebcentral"))

        await store.refresh()

        let mdAsked = await mangadex.askedIds()
        let wcAsked = await weebcentral.askedIds()
        XCTAssertEqual(mdAsked, ["md-1"])
        XCTAssertEqual(wcAsked, ["wc-1"], "The WeebCentral item must not be refreshed against MangaDex")
    }

    // MARK: - Source abstraction

    /// Minimal in-memory `MangaSource` proving the protocol is mockable / bridge-friendly.
    private struct MockSource: MangaSource {
        let id: String
        let name: String
        var publishesExternalIds = false
        var detail: MangaDetail = MangaDetail(description: "d", authors: ["A"], tags: [], contentRating: "safe")
        var stubChapters: [Chapter] = [Chapter(id: "c1", number: "1", title: nil)]
        var stubManga: [Manga] = []

        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { stubManga }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { stubManga }
        func newTitles(limit: Int, offset: Int) async throws -> [Manga] { stubManga }
        func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail { detail }
        func chapters(mangaId: String) async throws -> [Chapter] { stubChapters }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }

    /// A source that omits the optional feed capabilities to exercise the default impls.
    private struct MinimalSource: MangaSource {
        let id = "minimal"
        let name = "Minimal"
        var homeFeedCapabilities: Set<SourceOperation> { [.popular] }
        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }
        func chapters(mangaId: String) async throws -> [Chapter] { [] }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }

    @MainActor func testRegistryResolvesActiveAndByID() {
        let a = MockSource(id: "a", name: "A")
        let b = MockSource(id: "b", name: "B")
        let registry = SourceRegistry(sources: [a, b])

        XCTAssertEqual(registry.active?.id, "a")               // first source is active by default
        XCTAssertEqual(registry.source(id: "b")?.id, "b")     // lookup by id
        XCTAssertNil(registry.source(id: "nope"))             // unknown id → nil

        registry.activeSourceID = "b"
        XCTAssertEqual(registry.active?.id, "b")               // switching active source works
    }

    @MainActor func testRegistryActiveFallsBackWhenActiveIDMissing() {
        let registry = SourceRegistry(sources: [MockSource(id: "only", name: "Only")])
        registry.activeSourceID = "ghost"                     // point at a non-existent source
        XCTAssertEqual(registry.active?.id, "only")            // still resolves to the first source
    }

    @MainActor func testExternalIdCapabilityDispatchesThroughExistential() {
        let source: any MangaSource = MockSource(id: "bridge", name: "Bridge",
                                                  publishesExternalIds: true)
        XCTAssertTrue(source.publishesExternalIds)
    }

    @MainActor func testRegistryExternalIdSourcePrefersActiveThenRegisteredFallback() {
        let ordinary = MockSource(id: "ordinary", name: "Ordinary")
        let bridge = MockSource(id: "bridge", name: "Bridge", publishesExternalIds: true)
        let anotherBridge = MockSource(id: "bridge-2", name: "Bridge 2", publishesExternalIds: true)
        let registry = SourceRegistry(sources: [ordinary, bridge, anotherBridge])

        XCTAssertEqual(registry.externalIdSource?.id, "bridge")
        registry.activeSourceID = "bridge-2"
        XCTAssertEqual(registry.externalIdSource?.id, "bridge-2")
        registry.activeSourceID = "ordinary"
        XCTAssertEqual(registry.externalIdSource?.id, "bridge")
        let none = SourceRegistry(sources: [ordinary])
        XCTAssertNil(none.externalIdSource)
    }

    @MainActor func testRegistrySourceForMangaUsesSourceId() {
        let a = MockSource(id: "a", name: "A")
        let b = MockSource(id: "b", name: "B")
        let registry = SourceRegistry(sources: [a, b])
        let manga = Manga(id: "x", sourceId: "b", title: "T", description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
    XCTAssertEqual(registry.source(for: manga)?.id, "b")   // resolves to the manga's own source
    }

    @MainActor func testDetailViewModelLoadsThroughInjectedSource() async {
        let source = MockSource(
            id: "mock", name: "Mock",
            detail: MangaDetail(description: "desc", authors: ["Author"],
                                tags: [Tag(id: "t1", name: "Action", group: "genre")],
                                contentRating: "safe"),
            stubChapters: [Chapter(id: "c1", number: "1", title: "One"),
                           Chapter(id: "c2", number: "2", title: nil)]
        )
        let manga = sampleManga("m", sourceId: "mock")
        let vm = MangaDetailViewModel(manga: manga, source: source)

        await vm.loadAsync()

        XCTAssertEqual(vm.description, "desc")
        XCTAssertEqual(vm.authors, ["Author"])
        XCTAssertEqual(vm.tags, ["Action"])
        XCTAssertEqual(vm.detailTags, [Tag(id: "t1", name: "Action", group: "genre")])
        XCTAssertEqual(vm.contentRating, "safe")
        XCTAssertEqual(vm.chapters.map(\.id), ["c1", "c2"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testUnsupportedFeedCapabilityThrows() async {
        let source = MinimalSource()
        do {
            _ = try await source.newTitles(limit: 10, offset: 0)
            XCTFail("newTitles should be unsupported on MinimalSource")
        } catch let SourceError.unsupported(capability) {
            XCTAssertEqual(capability, "newTitles")
        } catch {
            XCTFail("Expected SourceError.unsupported, got \(error)")
        }
    }

    func testMangaDexSourceIsNotNSFWByDefault() {
        XCTAssertFalse(MangaDexSource().isNSFW)
    }

    func testSourceCanDeclareNSFW() {
        struct AdultMock: MangaSource {
            let id = "adult"; let name = "Adult"
            var isNSFW: Bool { true }
            func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
            func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
            func mangaDetail(id: String) async throws -> MangaDetail {
                MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
            }
            func chapters(mangaId: String) async throws -> [Chapter] { [] }
            func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
        }
        XCTAssertTrue(AdultMock().isNSFW)
    }

    @MainActor func testVisibleSourcesRespectAdultToggle() {
        struct AdultMock: MangaSource {
            let id = "adult"; let name = "Adult"
            var isNSFW: Bool { true }
            func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
            func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
            func mangaDetail(id: String) async throws -> MangaDetail {
                MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
            }
            func chapters(mangaId: String) async throws -> [Chapter] { [] }
            func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
        }
        let registry = SourceRegistry(sources: [MangaDexSource(), AdultMock()])

        XCTAssertEqual(registry.visibleSources(includeAdult: false).map(\.id), ["mangadex"])
        XCTAssertEqual(registry.visibleSources(includeAdult: true).map(\.id), ["mangadex", "adult"])
    }

    func testMangaDexDecodeStampsSourceId() throws {
        // A /manga list entry decoded exactly as the API layer does it must carry the
        // MangaDex source id so downstream source resolution works.
        let json = #"""
        {
          "data": [{
            "id": "abc",
            "attributes": {
              "title": {"en": "Berserk"},
              "description": {"en": "d"},
              "status": "ongoing",
              "year": 1989
            },
            "relationships": []
          }]
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let res = try decoder.decode(MangaListResponse.self, from: json)
        let manga = res.data[0].attributes.toManga(id: res.data[0].id, relationships: res.data[0].relationships)

        XCTAssertEqual(manga.id, "abc")
        XCTAssertEqual(manga.sourceId, "mangadex")
        XCTAssertEqual(manga.sourceId, MangaDexSource.sourceID)
    }

    func testMangaAttributesToMangaExtractsMalIdFromLinks() throws {
        let json = """
        {
          "title": {"en": "Berserk"},
          "links": {"mal": "2", "al": "30002"}
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let attrs = try decoder.decode(MangaAttributes.self, from: json)
        let manga = attrs.toManga(id: "abc", relationships: nil)
        XCTAssertEqual(manga.malId, 2)
    }

    func testMangaAttributesToMangaMalIdNilWhenAbsentOrNonNumeric() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let noLinks = #"{ "title": {"en": "X"} }"#.data(using: .utf8)!
        let a = try decoder.decode(MangaAttributes.self, from: noLinks)
        XCTAssertNil(a.toManga(id: "1", relationships: nil).malId)

        // MangaDex occasionally stores a non-numeric mal link — must not crash, must be nil.
        let badLink = #"{ "title": {"en": "X"}, "links": {"mal": "not-a-number"} }"#.data(using: .utf8)!
        let b = try decoder.decode(MangaAttributes.self, from: badLink)
        XCTAssertNil(b.toManga(id: "1", relationships: nil).malId)
    }

    // MARK: - Alt titles (ADR-0016 Decision 1)

    /// The shape is taken from a live `GET /manga?title=Tower of God` response: a list of
    /// **single-key** locale maps, with the same locale free to repeat. Decoding it as one
    /// merged dictionary would silently keep one value per locale and throw the rest away —
    /// which is most of the matcher fuel this field exists to supply.
    func testMangaAttributesFlattensAltTitleLocaleMaps() throws {
        let json = """
        {
          "title": {"en": "Sinui Tap"},
          "altTitles": [
            {"ko": "신의 탑"},
            {"en": "Tower of God"},
            {"en": "Sin-ui Tab"},
            {"tr": "Tanrının Kulesi"}
          ],
          "links": {"mal": "122663"}
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manga = try decoder.decode(MangaAttributes.self, from: json)
            .toManga(id: "abc", relationships: nil)

        XCTAssertEqual(manga.altTitles?.count, 4, "both `en` alternates must survive")
        XCTAssertEqual(manga.altTitles, ["신의 탑", "Tower of God", "Sin-ui Tab", "Tanrının Kulesi"],
                       "order is the API's; locale keys are unsorted, so values are the only stable thing")
        XCTAssertEqual(manga.malId, 122663)
    }

    func testMangaAttributesAltTitlesDropBlanksDuplicatesAndTheDisplayTitle() throws {
        let json = """
        {
          "title": {"en": "Berserk"},
          "altTitles": [
            {"en": "Berserk"},
            {"ja": "  ベルセルク  "},
            {"ja": "ベルセルク"},
            {"en": "   "}
          ]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manga = try decoder.decode(MangaAttributes.self, from: json)
            .toManga(id: "abc", relationships: nil)

        // The display title is excluded (it already lives in `title`), the blank is dropped,
        // and the trimmed duplicate collapses into the first spelling.
        XCTAssertEqual(manga.altTitles, ["ベルセルク"])
    }

    func testMangaAttributesAltTitlesNilWhenAbsentOrEmpty() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let absent = #"{ "title": {"en": "X"} }"#.data(using: .utf8)!
        XCTAssertNil(try decoder.decode(MangaAttributes.self, from: absent)
            .toManga(id: "1", relationships: nil).altTitles)

        // Present but contributing nothing collapses to nil rather than `[]` — nil and empty
        // mean the same thing to every consumer, so only one of them should ever be stored.
        let empty = #"{ "title": {"en": "X"}, "altTitles": [{"en": "X"}, {"ja": ""}] }"#.data(using: .utf8)!
        XCTAssertNil(try decoder.decode(MangaAttributes.self, from: empty)
            .toManga(id: "1", relationships: nil).altTitles)
    }

    /// The compatibility claim ADR-0016 Decision 1 rests on. ADR-0011's ranked-pool cache
    /// persists `Manga` whole and treats an undecodable entry as a miss, so a required field
    /// would silently invalidate every cache file written before today and re-fetch the pool.
    /// This is that exact payload: a `Manga` encoded before `altTitles` existed.
    func testMangaDecodesFromCacheEntryWrittenBeforeAltTitlesExisted() throws {
        let legacy = """
        {
          "id": "abc",
          "sourceId": "mangadex",
          "title": "Berserk",
          "description": "",
          "status": "ongoing",
          "malId": 2
        }
        """.data(using: .utf8)!

        let manga = try JSONDecoder().decode(Manga.self, from: legacy)
        XCTAssertEqual(manga.title, "Berserk")
        XCTAssertEqual(manga.malId, 2)
        XCTAssertNil(manga.altTitles)
    }

    // MARK: - Image cache

    /// Thread-safe call counter for the injected fetcher.
    private final class SyncCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func bump() { lock.lock(); _count += 1; lock.unlock() }
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgcache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private func tinyPNG(_ color: UIColor = .red) -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return r.pngData { ctx in color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }

    @MainActor func testLoadImageFetchesOnceThenServesFromMemory() async {
        let png = tinyPNG()
        let counter = SyncCallCounter()
        let cache = ImageCache(directory: makeTempDir(), fetcher: { _ in counter.bump(); return png })
        let url = URL(string: "https://example.com/p1.png")!

        let first = await cache.loadImage(for: url)        // network
        XCTAssertNotNil(first)
        XCTAssertEqual(counter.count, 1)
        let second = await cache.loadImage(for: url)       // memory hit
        XCTAssertNotNil(second)
        XCTAssertEqual(counter.count, 1)
    }

    @MainActor func testDiskPersistsAcrossInstancesWithoutRefetch() async {
        let dir = makeTempDir()
        let png = tinyPNG()
        let url = URL(string: "https://example.com/p2.png")!

        let c1 = SyncCallCounter()
        let cache1 = ImageCache(directory: dir, fetcher: { _ in c1.bump(); return png })
        _ = await cache1.loadImage(for: url)               // network → disk
        XCTAssertEqual(c1.count, 1)

        let c2 = SyncCallCounter()
        let cache2 = ImageCache(directory: dir, fetcher: { _ in c2.bump(); return png }) // fresh memory, same disk
        let hit = await cache2.loadImage(for: url)         // disk hit
        XCTAssertNotNil(hit)
        XCTAssertEqual(c2.count, 0)                        // no network
    }

    func testKeyIsStableAndURLSpecific() {
        let u1 = URL(string: "https://example.com/a.png")!
        let u2 = URL(string: "https://example.com/b.png")!
        XCTAssertEqual(ImageCache.key(for: u1), ImageCache.key(for: u1))
        XCTAssertNotEqual(ImageCache.key(for: u1), ImageCache.key(for: u2))
        XCTAssertEqual(ImageCache.key(for: u1).count, 64)  // sha256 hex length
    }

    func testDiskTrimEnforcesCap() async {
        let disk = ImageDiskCache(directory: makeTempDir(), maxBytes: 1000)
        await disk.store(Data(count: 400), for: "a")
        await disk.store(Data(count: 400), for: "b")
        await disk.store(Data(count: 400), for: "c")       // 1200 > cap
        var total = await disk.totalBytes()
        XCTAssertEqual(total, 1200)
        await disk.trim()
        total = await disk.totalBytes()
        XCTAssertLessThanOrEqual(total, 800)               // trimmed to <= 80% of cap
    }

    func testDiskClearRemovesFiles() async {
        let disk = ImageDiskCache(directory: makeTempDir(), maxBytes: 1000)
        await disk.store(Data(count: 100), for: "x")
        var present = await disk.has("x")
        XCTAssertTrue(present)
        await disk.clear()
        present = await disk.has("x")
        XCTAssertFalse(present)
    }

    @MainActor func testClearEmptiesMemory() async {
        let png = tinyPNG()
        let cache = ImageCache(directory: makeTempDir(), fetcher: { _ in png })
        let url = URL(string: "https://example.com/p3.png")!
        _ = await cache.loadImage(for: url)
        XCTAssertNotNil(cache.image(for: url))
        cache.clear()
        XCTAssertNil(cache.image(for: url))
    }

    @MainActor func testPrefetchWarmsAllURLsAndDedupes() async {
        let png = tinyPNG()
        let counter = SyncCallCounter()
        let cache = ImageCache(directory: makeTempDir(), fetcher: { _ in counter.bump(); return png })
        let urls = (0..<8).map { URL(string: "https://example.com/pf\($0).png")! }

        await cache.prefetchAwaitable(urls)
        for u in urls { XCTAssertNotNil(cache.image(for: u)) }
        XCTAssertEqual(counter.count, 8)

        await cache.prefetchAwaitable(urls)                // all cached now
        XCTAssertEqual(counter.count, 8)                   // no new fetches
    }

    // MARK: - Image rate-limit backoff (Phase 3)

    /// Serial call counter for injected fetchers.
    private actor CallCounter {
        private(set) var count = 0
        func next() -> Int { defer { count += 1 }; return count }
    }

    private func onePixelPNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.pngData { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func tempCacheDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imgcache-\(UUID().uuidString)")
    }

    func testImageBackoffDelayDoublesPerAttempt() {
        XCTAssertEqual(ImageCache.imageBackoffDelay(attempt: 0, base: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ImageCache.imageBackoffDelay(attempt: 1, base: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ImageCache.imageBackoffDelay(attempt: 2, base: 0.5), 2.0, accuracy: 0.0001)
    }

    func testImageCacheRetriesAfterRateLimitThenSucceeds() async {
        let png = onePixelPNGData()
        let counter = CallCounter()
        let cache = ImageCache(directory: tempCacheDir(), retryBaseDelay: 0, maxImageRetries: 2,
                               fetcher: { _ in
            let n = await counter.next()
            if n == 0 { throw ImageFetchError.rateLimited }
            return png
        })
        let img = await cache.loadImage(for: URL(string: "https://i.example/1.jpg")!)
        XCTAssertNotNil(img)
        let calls = await counter.count
        XCTAssertEqual(calls, 2)   // first attempt rate-limited, retry succeeded
    }

    func testImageCacheGivesUpAfterMaxRetries() async {
        let cache = ImageCache(directory: tempCacheDir(), retryBaseDelay: 0, maxImageRetries: 2,
                               fetcher: { _ in throw ImageFetchError.rateLimited })
        let img = await cache.loadImage(for: URL(string: "https://i.example/2.jpg")!)
        XCTAssertNil(img)
    }

    // MARK: - Per-source prefetch hint (Phase 3)

    private actor FetchedURLs {
        private(set) var urls: [URL] = []
        func add(_ u: URL) { urls.append(u) }
        var count: Int { urls.count }
    }

    func testDefaultImagePrefetchConcurrencyIsFive() {
        XCTAssertEqual(MangaDexSource().imagePrefetchConcurrency, 5)
    }

    func testPrefetchWithConcurrencyCapStillLoadsEveryURL() async {
        let png = onePixelPNGData()
        let fetched = FetchedURLs()
        let cache = ImageCache(directory: tempCacheDir(), fetcher: { url in
            await fetched.add(url); return png
        })
        let urls = (1...6).map { URL(string: "https://i.example/\($0).jpg")! }
        await cache.prefetchAwaitable(urls, maxConcurrent: 2)
        let count = await fetched.count
        XCTAssertEqual(count, 6)
    }

    // MARK: - Source-layer contract (Phase 2)

    func testSourceErrorWebViewCasesHaveDescriptions() {
        XCTAssertEqual(SourceError.cloudflareUnsolved.errorDescription,
                       "Cloudflare verification wasn't completed.")
        XCTAssertEqual(SourceError.navigationFailed("timeout").errorDescription,
                       "Couldn't load the page: timeout")
        XCTAssertEqual(SourceError.extractionFailed("bad JSON").errorDescription,
                       "Couldn't read the page: bad JSON")
    }

    /// Reference box so a value-type source can record what it was called with.
    private final class OffsetBox: @unchecked Sendable { var seen: [Int] = [] }

    /// A source that omits `latestUpdates` still reports it as unsupported through the
    /// offset-bearing signature.
    func testMinimalSourceLatestUpdatesStillUnsupportedWithOffset() async {
        do {
            _ = try await MinimalSource().latestUpdates(limitTitles: 10, language: "en", offset: 24)
            XCTFail("expected .unsupported")
        } catch let error as SourceError {
            guard case .unsupported(let capability) = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
            XCTAssertEqual(capability, "latestUpdates")
        } catch {
            XCTFail("expected SourceError, got \(error)")
        }
    }

    /// The two-arg convenience must forward offset 0, so existing Home/rail callers keep
    /// getting the top of the feed.
    func testLatestUpdatesConvenienceForwardsZeroOffset() async throws {
        struct OffsetRecordingSource: MangaSource {
            let id = "offrec"
            let name = "OffRec"
            let box: OffsetBox
            func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
            func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
            func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] {
                box.seen.append(offset)
                return []
            }
            func mangaDetail(id: String) async throws -> MangaDetail {
                MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
            }
            func chapters(mangaId: String) async throws -> [Chapter] { [] }
            func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
        }

        let box = OffsetBox()
        let source: any MangaSource = OffsetRecordingSource(box: box)
        _ = try await source.latestUpdates(limitTitles: 20, language: "en")
        _ = try await source.latestUpdates(limitTitles: 20, language: "en", offset: 48)
        XCTAssertEqual(box.seen, [0, 48])
    }

    // MARK: - Tag decode widening (recommendation engine)

    func testMangaDetailDecodesTagIdNameAndGroup() throws {
        let json = #"""
        {"data":{"id":"m1","type":"manga","attributes":{
            "title":{"en":"T"},"description":{"en":"d"},
            "tags":[{"id":"tag-uuid-1","type":"tag","attributes":{"name":{"en":"Action"},"group":"genre"}}],
            "content_rating":"safe"},
          "relationships":[]}}
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(MangaDetailResponse.self, from: json).toDomain()
        XCTAssertEqual(detail.tags, [Tag(id: "tag-uuid-1", name: "Action", group: "genre")])
    }

    // MARK: - Default source registration (Phase 2)

    @MainActor func testDefaultRegistryContainsAllBuiltInSources() {
        let registry = SourceRegistry()
        XCTAssertEqual(registry.sources.map(\.id), ["mangadex"])
        XCTAssertNil(registry.source(id: "weebcentral"))
    }

    @MainActor func testDisablingAdultToggleReSourcesAwayFromActiveAdultSource() {
        struct AdultMock: MangaSource {
            let id = "adult"; let name = "Adult"
            var isNSFW: Bool { true }
            func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
            func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
            func mangaDetail(id: String) async throws -> MangaDetail {
                MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
            }
            func chapters(mangaId: String) async throws -> [Chapter] { [] }
            func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
        }
        let registry = SourceRegistry(sources: [MangaDexSource(), AdultMock()])
        registry.activeSourceID = "adult"
        registry.enforceAdultGating(includeAdult: false)
        XCTAssertEqual(registry.activeSourceID, "mangadex")   // fell back to the non-adult source
        registry.activeSourceID = "adult"
        registry.enforceAdultGating(includeAdult: true)
        XCTAssertEqual(registry.activeSourceID, "adult")      // no change while adult shown
    }

    // MARK: - Home source switching (Phase 2 addendum)

    @MainActor func testHomeViewModelInjectedSourceWins() {
        let vm = HomeViewModel(source: MockSource(id: "mock", name: "Mock"))
        XCTAssertEqual(vm.source?.id, "mock")
    }

    @MainActor func testHomeSkipsUndeclaredFeeds() async throws {
        let vm = HomeViewModel(source: MinimalSource())

        vm.loadHome()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await waitUntil("home load to finish") { !vm.isLoading }

        XCTAssertNil(vm.errorMessage)
    }

    /// A source whose FIRST popular() call suspends until the test lets it proceed;
    /// every later call returns `fresh` immediately. Two first-call behaviors:
    /// - `.parkUntilReleased` parks on a continuation that deliberately ignores task
    ///   cancellation, so a superseded load runs to completion *late* — exercising the
    ///   "stale task must never write" guard.
    /// - `.sleepCancellably` suspends in `Task.sleep`, which throws `CancellationError`
    ///   the moment the load is superseded — exercising the "cancellation is not a
    ///   user-facing error" path.
    private actor SupersededSource: MangaSource {
        // The behavior is private test scaffolding for its enclosing source actor.
        enum FirstCallBehavior { // swiftlint:disable:this nesting
            case parkUntilReleased, sleepCancellably
        }

        nonisolated let id = "superseded"
        nonisolated let name = "Superseded"
        private let firstCall: FirstCallBehavior
        private let stale: [Manga]
        private let fresh: [Manga]
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var popularCalls = 0

        init(firstCall: FirstCallBehavior, stale: [Manga], fresh: [Manga]) {
            self.firstCall = firstCall
            self.stale = stale
            self.fresh = fresh
        }

        var isParked: Bool { gate != nil }
        func releaseGate() { gate?.resume(); gate = nil }

        func popular(limit: Int, offset: Int) async throws -> [Manga] {
            popularCalls += 1
            guard popularCalls == 1 else { return fresh }
            switch firstCall {
            case .parkUntilReleased:
                await withCheckedContinuation { gate = $0 } // cancellation-blind on purpose
            case .sleepCancellably:
                try await Task.sleep(nanoseconds: 3_600_000_000_000) // cancelled long before 1h
            }
            return stale
        }

        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func newTitles(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }
        func chapters(mangaId: String) async throws -> [Chapter] { [] }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }

    /// Polls an async condition until it holds or a 5s deadline expires.
    @MainActor private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(what)")
    }

    @MainActor func testSupersededHomeLoadNeitherClobbersRailsNorSurfacesCancellation() async throws {
        let stale = [sampleManga("stale", sourceId: "superseded")]
        let fresh = [sampleManga("fresh", sourceId: "superseded")]

        // Phase A: the superseded load's fetch ignores cancellation and completes LATE —
        // it must not overwrite the rails the superseding load already populated.
        let sourceA = SupersededSource(firstCall: .parkUntilReleased, stale: stale, fresh: fresh)
        let vmA = HomeViewModel(source: sourceA)

        vmA.loadHome()                                    // load #1 parks inside popular()
        try await waitUntil("first load to park") { await sourceA.isParked }
        vmA.loadHome()                                    // load #2 supersedes #1, finishes fast
        try await waitUntil("fresh rails to land") { vmA.popular.map(\.id) == ["fresh"] }

        await sourceA.releaseGate()                       // late-complete the superseded load
        try await Task.sleep(nanoseconds: 200_000_000)    // give it time to (wrongly) write

        XCTAssertEqual(vmA.popular.map(\.id), ["fresh"])  // stale data must not clobber
        XCTAssertNil(vmA.errorMessage)
        XCTAssertFalse(vmA.isLoading)

        // Phase B: the superseded load's fetch IS cancellation-aware — the resulting
        // CancellationError must not surface as a user-facing errorMessage.
        let sourceB = SupersededSource(firstCall: .sleepCancellably, stale: stale, fresh: fresh)
        let vmB = HomeViewModel(source: sourceB)

        vmB.loadHome()                                    // load #1 suspends in Task.sleep
        try await waitUntil("first load to start") { await sourceB.popularCalls == 1 }
        vmB.loadHome()                                    // cancels #1 → sleep throws CancellationError
        try await waitUntil("fresh rails to land") { vmB.popular.map(\.id) == ["fresh"] }
        try await Task.sleep(nanoseconds: 200_000_000)    // let the cancelled load unwind

        XCTAssertNil(vmB.errorMessage)                    // cancellation is not an error
        XCTAssertEqual(vmB.popular.map(\.id), ["fresh"])
        XCTAssertFalse(vmB.isLoading)
    }

    // MARK: - Source web URLs (Phase 2 addendum)

    func testMangaDexWebURL() async throws {
        let url = try await MangaDexSource().webURL(forManga: "abc-123")
        XCTAssertEqual(url?.absoluteString,
                       "https://mangadex.org/title/abc-123")
    }

    func testWebURLDefaultsToNil() async throws {
        let url = try await MockSource(id: "x", name: "X").webURL(forManga: "y")
        XCTAssertNil(url)
    }

    // MARK: - Chapter date-added (MangaDex)

    func testChapterParseISO8601() {
        XCTAssertNotNil(Chapter.parseISO8601("2024-01-15T12:00:00+00:00"))
        XCTAssertNotNil(Chapter.parseISO8601("2024-01-15T12:00:00.123+00:00"))  // fractional seconds
        XCTAssertNotNil(Chapter.parseISO8601("2024-01-15T12:00:00Z"))
        XCTAssertNil(Chapter.parseISO8601(nil))
        XCTAssertNil(Chapter.parseISO8601(""))
        XCTAssertNil(Chapter.parseISO8601("not a date"))
    }

    func testChapterDateDefaultsToNil() {
        XCTAssertNil(Chapter(id: "c1", number: "1", title: nil).date)   // existing call shape → nil
    }

    func testMangaDexToChapterUsesPublishAt() throws {
        let json = #"{"chapter":"12","title":"T","translatedLanguage":"en","#
            + #""publishAt":"2024-01-15T12:00:00+00:00","readableAt":"2024-01-16T12:00:00+00:00"}"#
        let attrs = try JSONDecoder().decode(ChapterAttributes.self, from: Data(json.utf8))
        XCTAssertEqual(attrs.toChapter(id: "c1").date, Chapter.parseISO8601("2024-01-15T12:00:00+00:00"))
    }

    func testMangaDexToChapterFallsBackToReadableAt() throws {
        let json = #"{"chapter":"12","title":null,"translatedLanguage":"en","publishAt":null,"readableAt":"2024-01-16T12:00:00+00:00"}"#
        let attrs = try JSONDecoder().decode(ChapterAttributes.self, from: Data(json.utf8))
        XCTAssertEqual(attrs.toChapter(id: "c1").date, Chapter.parseISO8601("2024-01-16T12:00:00+00:00"))
    }

    func testMangaDexToChapterNilWhenNoTimestamps() throws {
        let json = #"{"chapter":"12","title":null,"translatedLanguage":"en","publishAt":null,"readableAt":null}"#
        let attrs = try JSONDecoder().decode(ChapterAttributes.self, from: Data(json.utf8))
        XCTAssertNil(attrs.toChapter(id: "c1").date)
    }

    // MARK: - PagedMangaLoader (search / genre pagination)

    /// A `MangaSource` that records its search calls and returns programmable pages —
    /// exercises `SearchViewModel`'s debounce / re-run wiring without a network.
    @MainActor
    private final class RecordingSource: MangaSource {
        nonisolated let id: String
        nonisolated let name: String
        private(set) var searchCalls: [(title: String, limit: Int, offset: Int)] = []
        private let pageProvider: (_ limit: Int, _ offset: Int) -> [Manga]

        init(id: String = "rec", name: String = "Rec",
             pageProvider: @escaping (_ limit: Int, _ offset: Int) -> [Manga]) {
            self.id = id
            self.name = name
            self.pageProvider = pageProvider
        }

        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
            searchCalls.append((title, limit, offset))
            return pageProvider(limit, offset)
        }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }
        func chapters(mangaId: String) async throws -> [Chapter] { [] }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }

    private enum LoaderTestError: Error { case boom }

    @MainActor func testLoaderFirstPageSetsHasMoreWhenFull() async throws {
        let loader = PagedMangaLoader(pageSize: 24)
        loader.load { limit, _ in (0..<limit).map { self.sampleManga("m\($0)") } }
        try await waitUntil("first page") { !loader.isLoading && loader.items.count == 24 }
        XCTAssertTrue(loader.hasMore)
    }

    /// A SHORT page must NOT end the feed. Latest-updates pages the chapter feed and
    /// dedupes chapters→manga, so a perfectly healthy page arrives well under `pageSize`.
    @MainActor func testLoaderPartialPageKeepsHasMore() async throws {
        let loader = PagedMangaLoader(pageSize: 24)
        loader.load { _, _ in (0..<10).map { self.sampleManga("m\($0)") } }
        try await waitUntil("partial page") { !loader.isLoading && loader.items.count == 10 }
        XCTAssertTrue(loader.hasMore)
    }

    /// Only a genuinely empty page ends the feed.
    @MainActor func testLoaderEmptyPageEndsFeed() async throws {
        let loader = PagedMangaLoader(pageSize: 24)
        loader.load { _, _ in [] }
        try await waitUntil("empty page") { !loader.isLoading }
        XCTAssertFalse(loader.hasMore)
        XCTAssertTrue(loader.items.isEmpty)
    }

    /// A page of nothing but already-seen ids means the source is cycling — also the end.
    @MainActor func testLoaderAllDuplicatePageEndsFeed() async throws {
        let loader = PagedMangaLoader(pageSize: 4)
        loader.load { limit, _ in (0..<limit).map { self.sampleManga("dup\($0)") } }
        try await waitUntil("page 1") { loader.items.count == 4 }
        loader.loadMoreIfNeeded(current: loader.items.last!)
        try await waitUntil("page 2 settled") { !loader.isLoadingMore }
        XCTAssertEqual(loader.items.count, 4)   // nothing new appended
        XCTAssertFalse(loader.hasMore)
    }

    @MainActor func testLoaderAdvancesOffsetByPageSizeRegardlessOfReturnedCount() async throws {
        let loader = PagedMangaLoader(pageSize: 24)
        var offsets: [Int] = []
        // Full pages keep hasMore true; unique ids per page so nothing is deduped away.
        loader.load { limit, offset in
            offsets.append(offset)
            return (0..<limit).map { self.sampleManga("m\(offset + $0)") }
        }
        try await waitUntil("page 1") { !loader.isLoading && loader.items.count == 24 }
        loader.loadMoreIfNeeded(current: loader.items.last!)
        try await waitUntil("page 2") { loader.items.count == 48 }
        loader.loadMoreIfNeeded(current: loader.items.last!)
        try await waitUntil("page 3") { loader.items.count == 72 }
        XCTAssertEqual(offsets, [0, 24, 48])   // constant step — the offset→page conversion contract
    }

    @MainActor func testLoaderDeduplicatesRepeatedIDsAcrossPages() async throws {
        let loader = PagedMangaLoader(pageSize: 24)
        // Page 2 overlaps page 1 by ids 12...23; only 12 of its entries are new.
        loader.load { limit, offset in
            let start = offset == 0 ? 0 : 12
            return (0..<limit).map { self.sampleManga("m\(start + $0)") }
        }
        try await waitUntil("page 1") { loader.items.count == 24 }
        loader.loadMoreIfNeeded(current: loader.items.last!)
        try await waitUntil("page 2 appended") { loader.items.count == 36 }
        XCTAssertEqual(Set(loader.items.map(\.id)).count, 36)   // no duplicate ids
    }

    @MainActor func testLoaderNewLoadSupersedesInFlightAndSwallowsCancellation() async throws {
        let loader = PagedMangaLoader(pageSize: 2)
        // First load parks in a long sleep; superseding it must cancel it cleanly.
        loader.load { _, _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return [self.sampleManga("stale")]
        }
        loader.load { _, _ in [self.sampleManga("fresh1"), self.sampleManga("fresh2")] }
        try await waitUntil("fresh landed") { loader.items.map(\.id) == ["fresh1", "fresh2"] }
        try await Task.sleep(nanoseconds: 150_000_000)   // give the cancelled load time to (wrongly) write
        XCTAssertEqual(loader.items.map(\.id), ["fresh1", "fresh2"])
        XCTAssertNil(loader.errorMessage)                // cancellation is not surfaced as an error
    }

    @MainActor func testLoaderErrorSetsThenClearsMessage() async throws {
        let loader = PagedMangaLoader(pageSize: 5)
        loader.load { _, _ in throw LoaderTestError.boom }
        try await waitUntil("error set") { loader.errorMessage != nil }
        XCTAssertTrue(loader.items.isEmpty)
        loader.load { _, _ in [self.sampleManga("ok")] }
        try await waitUntil("error cleared") { loader.errorMessage == nil && loader.items.map(\.id) == ["ok"] }
    }

    /// A transient failure on page one used to be terminal: `hasMore` stayed false and
    /// `CategoryGridView.loadedOnce` blocked any re-trigger, so one 429 killed the feed
    /// for the life of the view. `retry()` must recover it.
    @MainActor func testLoaderRetryRecoversFromFailedFirstPage() async throws {
        let loader = PagedMangaLoader(pageSize: 4)
        var shouldFail = true
        loader.load { limit, _ in
            if shouldFail { throw LoaderTestError.boom }
            return (0..<limit).map { self.sampleManga("m\($0)") }
        }
        try await waitUntil("first page failed") { loader.errorMessage != nil }
        XCTAssertTrue(loader.items.isEmpty)

        shouldFail = false
        loader.retry()
        try await waitUntil("retry succeeded") { loader.items.count == 4 }
        XCTAssertNil(loader.errorMessage)
        XCTAssertTrue(loader.hasMore)
    }

    /// `retry()` resumes the same feed at the current offset — it must not restart it or
    /// discard pages already loaded.
    @MainActor func testLoaderRetryResumesAtOffsetWithoutDiscardingItems() async throws {
        let loader = PagedMangaLoader(pageSize: 4)
        var offsets: [Int] = []
        var failNextPage = false
        loader.load { limit, offset in
            offsets.append(offset)
            if failNextPage { throw LoaderTestError.boom }
            return (0..<limit).map { self.sampleManga("m\(offset + $0)") }
        }
        try await waitUntil("page 1") { loader.items.count == 4 }

        failNextPage = true
        loader.loadMoreIfNeeded(current: loader.items.last!)
        try await waitUntil("page 2 failed") { loader.errorMessage != nil }
        XCTAssertEqual(loader.items.count, 4)   // page one survives the failure

        failNextPage = false
        loader.retry()
        try await waitUntil("page 2 recovered") { loader.items.count == 8 }
        XCTAssertEqual(offsets, [0, 4, 4])      // retried the SAME offset, didn't restart at 0
    }

    @MainActor func testLoaderRetryIsANoopWhileAFetchIsInFlight() async throws {
        let loader = PagedMangaLoader(pageSize: 2)
        var calls = 0
        loader.load { _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 200_000_000)
            return [self.sampleManga("a"), self.sampleManga("b")]
        }
        loader.retry()                                   // in flight — must be ignored
        try await waitUntil("page landed") { loader.items.count == 2 }
        XCTAssertEqual(calls, 1)
    }

    // MARK: - SearchViewModel

    @MainActor func testSearchDebouncesRapidQueriesToSingleFetch() async throws {
        let source = RecordingSource(pageProvider: { _, _ in [self.sampleManga("r")] })
        let vm = SearchViewModel(source: source, debounce: .milliseconds(50), pageSize: 24)
        vm.queryChanged("a")
        vm.queryChanged("ab")
        vm.queryChanged("abc")
        try await waitUntil("one search") { source.searchCalls.count == 1 }
        try await Task.sleep(nanoseconds: 120_000_000)   // no late extra calls
        XCTAssertEqual(source.searchCalls.count, 1)
        XCTAssertEqual(source.searchCalls.first?.title, "abc")
        XCTAssertTrue(vm.hasSearched)
    }

    @MainActor func testSearchBlankQueryClearsWithoutFetching() async throws {
        let source = RecordingSource(pageProvider: { _, _ in [self.sampleManga("x")] })
        let vm = SearchViewModel(source: source, debounce: .milliseconds(20))
        vm.queryChanged("   ")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(source.searchCalls.count, 0)
        XCTAssertFalse(vm.hasSearched)
        XCTAssertTrue(vm.loader.items.isEmpty)
    }

    @MainActor func testSelectSourceRerunsPendingQuery() async throws {
        let source = RecordingSource(pageProvider: { _, _ in [self.sampleManga("r")] })
        let vm = SearchViewModel(source: source, debounce: .milliseconds(20))
        vm.queryChanged("hero")
        try await waitUntil("first search") { source.searchCalls.count == 1 }
        vm.selectSource(id: "someid")
        try await waitUntil("re-run") { source.searchCalls.count == 2 }
        XCTAssertEqual(vm.selectedSourceID, "someid")
        XCTAssertEqual(source.searchCalls.last?.title, "hero")
    }

    @MainActor func testRetryRerunsLastQuery() async throws {
        let source = RecordingSource(pageProvider: { _, _ in [self.sampleManga("r")] })
        let vm = SearchViewModel(source: source, debounce: .milliseconds(20))
        vm.queryChanged("hero")
        try await waitUntil("first search") { source.searchCalls.count == 1 }
        vm.retry()
        try await waitUntil("retry re-runs") { source.searchCalls.count == 2 }
        XCTAssertEqual(source.searchCalls.last?.title, "hero")
    }

    @MainActor func testRetryIsNoopWithoutAQuery() async throws {
        let source = RecordingSource(pageProvider: { _, _ in [] })
        let vm = SearchViewModel(source: source, debounce: .milliseconds(20))
        vm.retry()   // nothing searched yet
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(source.searchCalls.count, 0)
    }

    // MARK: - Tag browse capability (Feature B)

    func testTagBrowseDefaultsToUnsupported() async {
        let source = MinimalSource()
        XCTAssertFalse(source.supportsTagBrowse)
        do {
            _ = try await source.mangaByTag(tag: "romance", limit: 10, offset: 0)
            XCTFail("mangaByTag should be unsupported on MinimalSource")
        } catch let SourceError.unsupported(capability) {
            XCTAssertEqual(capability, "mangaByTag")
        } catch {
            XCTFail("Expected SourceError.unsupported, got \(error)")
        }
    }

    func testMangaDexSupportsTagBrowse() {
        XCTAssertTrue(MangaDexSource().supportsTagBrowse)
    }

    func testMangaDexTagCatalogResolvesNameCaseInsensitively() async throws {
        let entities = [
            MDTagEntity(id: "uuid-romance", attributes: MDTagAttributes(name: ["en": "Romance"], group: nil)),
            MDTagEntity(id: "uuid-comedy", attributes: MDTagAttributes(name: ["en": "Comedy"], group: nil))
        ]
        let catalog = MangaDexTagCatalog(fetchAll: { entities })
        let romanceLower = try await catalog.id(forName: "romance")
        let romanceUpper = try await catalog.id(forName: "ROMANCE")
        let unknown = try await catalog.id(forName: "Isekai")
        XCTAssertEqual(romanceLower, "uuid-romance")
        XCTAssertEqual(romanceUpper, "uuid-romance")   // case-insensitive
        XCTAssertNil(unknown)                          // unknown name → nil → empty result upstream
    }

    // MARK: - TasteProfileStore

    @MainActor private func makeTasteStore() -> TasteProfileStore {
        let suite = UserDefaults(suiteName: "test.taste.\(UUID().uuidString)")!
        return TasteProfileStore(defaults: suite)
    }

    /// Writes the pre-slice-3 `taste.tagCache` payload straight into a suite — the
    /// only way to produce it now that nothing in the app writes that key.
    @MainActor private func seedLegacyTagCache(_ suite: UserDefaults, _ cache: [String: [Tag]]) {
        if let data = try? JSONEncoder().encode(cache) {
            suite.set(data, forKey: "taste.tagCache")
        }
    }

    @MainActor func testTasteStorePersistsFeedback() throws {
        let suite = UserDefaults(suiteName: "test.taste.\(UUID().uuidString)")!
        let store = TasteProfileStore(defaults: suite)
        store.markNotInterested(mangaId: "m2")
        store.markMoreLikeThis(mangaId: "m3")

        let reloaded = TasteProfileStore(defaults: suite)   // fresh instance, same suite
        XCTAssertTrue(reloaded.notInterested.contains("m2"))
        XCTAssertEqual(reloaded.moreLikeThis, ["m3"])
    }

    /// The legacy cache is read-only: it loads, and saving feedback must not rewrite
    /// it. If a `save()` ever re-encoded that key, the data this change retires would
    /// keep resurrecting itself and the one-release deletion window would never close.
    @MainActor func testLegacyTagCacheLoadsButIsNeverWrittenBack() throws {
        let suite = UserDefaults(suiteName: "test.taste.\(UUID().uuidString)")!
        let tags = [Tag(id: "t1", name: "Action", group: "genre")]
        seedLegacyTagCache(suite, ["m1": tags])

        let store = TasteProfileStore(defaults: suite)
        XCTAssertEqual(store.legacyTagCache["m1"], tags)

        suite.removeObject(forKey: "taste.tagCache")
        store.markNotInterested(mangaId: "m2")     // triggers save()
        XCTAssertNil(suite.data(forKey: "taste.tagCache"))
    }

    @MainActor func testTasteStoreDecodesAbsentKeysAsEmpty() {
        let store = TasteProfileStore(defaults: UserDefaults(suiteName: "test.taste.\(UUID().uuidString)")!)
        XCTAssertTrue(store.legacyTagCache.isEmpty)
        XCTAssertTrue(store.notInterested.isEmpty)
        XCTAssertTrue(store.moreLikeThis.isEmpty)
    }

    // MARK: - TasteProfile

    // Keeping the fixture's independent fields explicit makes call sites describe each scenario.
    // swiftlint:disable:next function_parameter_count
    private func entry(_ mangaId: String, chapter: String, page: Int, pageCount: Int,
                       daysAgo: Double, now: Date) -> ReadingEntry {
        ReadingEntry(id: UUID(), mangaId: mangaId, mangaTitle: mangaId, coverURL: nil,
                     chapterId: "\(mangaId)-\(chapter)", chapterNumber: chapter,
                     page: page, pageCount: pageCount,
                     updatedAt: now.addingTimeInterval(-daysAgo * 86_400), sourceId: "mangadex")
    }

    /// Bridges these per-Listing fixtures to the Work-aggregated `build`: one Work per
    /// manga id, which is what the store produces for Listings that were never linked.
    private func signals(history: [ReadingEntry],
                         tagCache: [String: [Tag]]) -> [TasteProfile.WorkSignal] {
        var byManga: [String: [ReadingEntry]] = [:]
        var order: [String] = []
        for e in history {
            if byManga[e.mangaId] == nil { order.append(e.mangaId) }
            byManga[e.mangaId, default: []].append(e)
        }
        return order.map { id in
            TasteProfile.WorkSignal(
                workId: WorkID(),
                entries: byManga[id] ?? [],
                tags: (tagCache[id] ?? []).map { QueryableTag(name: $0.name, group: $0.group) })
        }
    }

    func testProfileWeightsGenreAboveFormatForEqualEngagement() {
        let now = Date()
        let tagCache = ["m1": [Tag(id: "g", name: "Action", group: "genre"),
                               Tag(id: "f", name: "Oneshot", group: "format")]]
        let history = [entry("m1", chapter: "1", page: 9, pageCount: 10, daysAgo: 0, now: now)]
        let p = TasteProfile.build(signals: signals(history: history, tagCache: tagCache),
                                   savedIds: [], moreLikeThis: [], now: now)
        // Keyed by normalized tag name now — a Work's snapshot has no tag id.
        XCTAssertEqual(p.orderedTagKeys.first, "action")          // genre outranks format
        XCTAssertGreaterThan(p.weights["action"]!, p.weights["oneshot"]!)
        XCTAssertEqual(p.weights.values.max()!, 1.0, accuracy: 1e-9)   // normalized to max 1
    }

    func testProfileRecencyDecayHalvesAtThirtyDays() {
        let now = Date()
        let tagCache = ["recent": [Tag(id: "a", name: "A", group: "genre")],
                        "old": [Tag(id: "b", name: "B", group: "genre")]]
        let history = [
            entry("recent", chapter: "1", page: 0, pageCount: 10, daysAgo: 0, now: now),
            entry("old", chapter: "1", page: 0, pageCount: 10, daysAgo: 30, now: now),
        ]
        let p = TasteProfile.build(signals: signals(history: history, tagCache: tagCache),
                                   savedIds: [], moreLikeThis: [], now: now)
        // Same engagement, but "old" is one 30-day half-life back → half the weight.
        XCTAssertEqual(p.weights["b"]! / p.weights["a"]!, 0.5, accuracy: 0.02)
    }

    func testProfileSavedAndFinishedMangaOutranksBareRead() {
        let now = Date()
        // Two manga, distinct genre tags, read the same recency/chapter count. One is
        // finished + saved; the other is a bare unfinished read. The boosted one must win.
        let tagCache = ["boost": [Tag(id: "b", name: "B", group: "genre")],
                        "bare": [Tag(id: "p", name: "P", group: "genre")]]
        let history = [
            entry("boost", chapter: "1", page: 9, pageCount: 10, daysAgo: 0, now: now),   // finished
            entry("bare", chapter: "1", page: 3, pageCount: 10, daysAgo: 0, now: now),   // unfinished
        ]
        let p = TasteProfile.build(signals: signals(history: history, tagCache: tagCache),
                                   savedIds: ["boost"], moreLikeThis: [], now: now)
        XCTAssertEqual(p.orderedTagKeys.first, "b")
        XCTAssertGreaterThan(p.weights["b"]!, p.weights["p"]!)
    }

    func testProfileMoreLikeThisDoublesContribution() {
        let now = Date()
        let tagCache = ["seed": [Tag(id: "s", name: "S", group: "genre")],
                        "plain": [Tag(id: "n", name: "N", group: "genre")]]
        let history = [
            entry("seed", chapter: "1", page: 3, pageCount: 10, daysAgo: 0, now: now),
            entry("plain", chapter: "1", page: 3, pageCount: 10, daysAgo: 0, now: now),
        ]
        let p = TasteProfile.build(signals: signals(history: history, tagCache: tagCache),
                                   savedIds: [], moreLikeThis: ["seed"], now: now)
        // Identical engagement; seed's ×2 boost makes it the top tag at exactly 2× "plain".
        XCTAssertEqual(p.orderedTagKeys.first, "s")
        XCTAssertEqual(p.weights["n"]! / p.weights["s"]!, 0.5, accuracy: 1e-9)
    }

    func testProfileEmptyWhenNoTaggedHistory() {
        let p = TasteProfile.build(signals: [], savedIds: [], moreLikeThis: [], now: Date())
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.taggedMangaCount, 0)
    }

    func testProfileFinishedBonusRanksAboveUnfinishedAcrossManga() {
        let now = Date()
        let tagCache = ["fin": [Tag(id: "f", name: "F", group: "genre")],
                        "unf": [Tag(id: "u", name: "U", group: "genre")]]
        let history = [
            entry("fin", chapter: "1", page: 9, pageCount: 10, daysAgo: 0, now: now),   // finished
            entry("unf", chapter: "1", page: 2, pageCount: 10, daysAgo: 0, now: now),   // abandoned
        ]
        let p = TasteProfile.build(signals: signals(history: history, tagCache: tagCache),
                                   savedIds: [], moreLikeThis: [], now: now)
        XCTAssertEqual(p.orderedTagKeys.first, "f")
        XCTAssertGreaterThan(p.weights["f"]!, p.weights["u"]!)
    }

    // MARK: - TasteProfile.seeds

    private func seedEntry(_ id: String, title: String, updated: Date) -> ReadingEntry {
        ReadingEntry(id: UUID(), mangaId: id, mangaTitle: title, coverURL: nil,
                     chapterId: "\(id)-c1", chapterNumber: "1", page: 9, pageCount: 10,
                     updatedAt: updated, sourceId: "mangadex")
    }

    func testTasteProfileSeedsRankedByWeightAndCapped() {
        let now = Date()
        let tag = [Tag(id: "t1", name: "Action", group: "genre")]
        // Three tagged, read manga; "b" is saved (weight boost), "c" is more-like-this (×2).
        let history = [seedEntry("a", title: "A", updated: now),
                       seedEntry("b", title: "B", updated: now),
                       seedEntry("c", title: "C", updated: now)]
        let profile = TasteProfile.build(
            signals: signals(history: history, tagCache: ["a": tag, "b": tag, "c": tag]),
            savedIds: ["b"],
            moreLikeThis: ["c"], now: now,
            libraryItems: [Manga(id: "b", sourceId: "mangadex", title: "B", description: "",
                                 status: "unknown", year: nil, coverURL: nil, malId: 42)],
            seedLimit: 2)
        // c (×2) and b (+saved) outrank a; capped at 2; c first.
        XCTAssertEqual(profile.seeds.map(\.manga.id), ["c", "b"])
        // Saved seed uses the library Manga → carries malId.
        XCTAssertEqual(profile.seeds.first(where: { $0.manga.id == "b" })?.manga.malId, 42)
        // Read-only seed falls back to history-derived Manga (title from mangaTitle).
        XCTAssertEqual(profile.seeds.first(where: { $0.manga.id == "c" })?.manga.title, "C")
    }

    // MARK: - TagCandidateProvider

    /// A source whose mangaByTag returns canned lists keyed by tag name.
    private struct CannedTagSource: MangaSource {
        let id = "mangadex"
        let name = "MangaDex"
        let lists: [String: [Manga]]
        let failTags: Set<String>

        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaByTag(tag: String, limit: Int, offset: Int) async throws -> [Manga] {
            if failTags.contains(tag) { throw LoaderTestError.boom }
            return lists[tag] ?? []
        }
        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }
        func chapters(mangaId: String) async throws -> [Chapter] { [] }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }

    private func profile(_ pairs: [(id: String, name: String, weight: Double)]) -> TasteProfile {
        var weights: [String: Double] = [:]; var names: [String: String] = [:]
        for p in pairs { weights[p.id] = p.weight; names[p.id] = p.name }
        let ordered = weights.sorted { $0.value > $1.value }.map(\.key)
        return TasteProfile(weights: weights, tagName: names, orderedTagKeys: ordered, taggedMangaCount: 5, seeds: [])
    }

    func testCandidateInTwoTagFeedsOutscoresOne() async throws {
        let both = sampleManga("both"); let one = sampleManga("one")
        let source = CannedTagSource(
            lists: ["Action": [both], "Romance": [both, one]], failTags: [])
        let prof = profile([("a", "Action", 1.0), ("r", "Romance", 0.8)])
        let out = try await TagCandidateProvider(source: source)
            .candidates(for: prof, excluding: [], limit: 10)
        XCTAssertEqual(out.first?.manga.id, "both")               // summed across two feeds
        XCTAssertEqual(out.map(\.manga.id).sorted(), ["both", "one"])
    }

    func testCandidateExcludesGivenIds() async throws {
        let source = CannedTagSource(lists: ["Action": [sampleManga("keep"), sampleManga("drop")]], failTags: [])
        let prof = profile([("a", "Action", 1.0)])
        let out = try await TagCandidateProvider(source: source)
            .candidates(for: prof, excluding: ["drop"], limit: 10)
        XCTAssertEqual(out.map(\.manga.id), ["keep"])
    }

    func testCandidateReasonIsHighestWeightProvenanceTag() async throws {
        let m = sampleManga("m")
        let source = CannedTagSource(lists: ["Action": [m], "Romance": [m]], failTags: [])
        let prof = profile([("a", "Action", 1.0), ("r", "Romance", 0.5)])
        let out = try await TagCandidateProvider(source: source)
            .candidates(for: prof, excluding: [], limit: 10)
        XCTAssertEqual(out.first?.reason, "More Action")
    }

    func testCandidateSkipsFailingTagFeed() async throws {
        let source = CannedTagSource(lists: ["Romance": [sampleManga("r1")]], failTags: ["Action"])
        let prof = profile([("a", "Action", 1.0), ("r", "Romance", 0.8)])
        let out = try await TagCandidateProvider(source: source)
            .candidates(for: prof, excluding: [], limit: 10)
        XCTAssertEqual(out.map(\.manga.id), ["r1"])               // Action threw, Romance survived
    }

    // MARK: - RecommendationEngine

    @MainActor private func makeWorkStore() -> WorkStore {
        WorkStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EngineTests-\(UUID().uuidString)"))
    }

    /// Gives a Work the provisional tags a detail-screen visit would have staged.
    /// `noteListingTags` never mints, so the tags sit pending until the engine's
    /// `resolveSignals` mints from history and consumes them — the real path.
    @MainActor private func tagRead(_ works: WorkStore, _ history: HistoryStore,
                                    _ id: String, _ tags: [Tag]) {
        works.noteListingTags(tags, for: sampleManga(id))
        history.record(manga: sampleManga(id), chapter: ch("1"), position: ReadingPosition(page: 9), pageCount: 10)
    }

    @MainActor private func makeEngine(history: HistoryStore, tasteStore: TasteProfileStore,
                                       provider: CandidateProvider,
                                       workStore: WorkStore? = nil,
                                       library: LibraryStore? = nil,
                                       mangaDexSource: MangaSource = CannedTagSource(lists: [:], failTags: []),
                                       now: Date = Date(), seed: UInt64 = 1,
                                       pushPriority: @escaping RecommendationEngine.PriorityPush = { _ in },
                                       tagBlocked: @escaping RecommendationEngine.TagBlocked = { _ in false })
        -> RecommendationEngine {
        let lib = library ?? LibraryStore(defaults: UserDefaults(suiteName: "test.lib.\(UUID().uuidString)")!)
        let works = workStore ?? WorkStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EngineTests-\(UUID().uuidString)"))
        return RecommendationEngine(history: history, library: lib, profileStore: tasteStore,
                                    workStore: works,
                                    mangaDexSource: mangaDexSource,
                                    makeProvider: { _ in provider }, now: { now }, seed: seed,
                                    pushPriority: pushPriority, tagBlocked: tagBlocked)
    }

    /// A provider returning a fixed ranked pool, ignoring the profile.
    private struct FixedPoolProvider: CandidateProvider {
        let pool: [ScoredManga]
        func candidates(for profile: TasteProfile, excluding: Set<String>, limit: Int) async throws -> [ScoredManga] {
            Array(pool.filter { !excluding.contains($0.manga.id) }.prefix(limit))
        }
    }

    private func scored(_ id: String) -> ScoredManga {
        ScoredManga(manga: sampleManga(id), score: 1, reason: "More Action")
    }

    /// ADR-0018's whole point: the id MangaDex published survives history and reaches the
    /// Work, so `MALEntityResolver` short-circuits instead of fuzzy-searching for an id
    /// the API already handed us.
    @MainActor func testResolveSignalsCarriesMalIdIntoMintedWork() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        let manga = Manga(id: "orv", sourceId: "mangadex", title: "Omniscient Reader",
                          description: "", status: "ongoing", year: nil, coverURL: nil,
                          malId: 132214)
        history.record(manga: manga, chapter: ch("1"), position: ReadingPosition(page: 9),
                       pageCount: 10)

        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: []), workStore: works)
        await engine.refresh()

        let id = try XCTUnwrap(works.workId(externalId: ExternalIDs(mal: 132214, anilist: nil)),
                               "the minted Work should carry the id the listing published")
        XCTAssertEqual(works.work(id)?.externalIds.mal, 132214)
    }

    @MainActor func testEngineColdStartHidesRailBelowThreshold() async throws {
        let history = makeHistoryStore()
        let taste = makeTasteStore()
        let works = makeWorkStore()
        // Only 2 tagged read manga — below the 3 threshold.
        tagRead(works, history, "m1", [Tag(id: "a", name: "A", group: "genre")])
        tagRead(works, history, "m2", [Tag(id: "b", name: "B", group: "genre")])

        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("x")]),
                                workStore: works)
        await engine.refresh()
        XCTAssertTrue(engine.recommendations.isEmpty)
    }

    @MainActor func testEngineProducesRecommendationsAboveThreshold() async throws {
        let history = makeHistoryStore()
        let taste = makeTasteStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("rec1"), scored("rec2")]),
                                workStore: works)
        await engine.refresh()
        XCTAssertEqual(Set(engine.recommendations.map(\.manga.id)), ["rec1", "rec2"])
    }

    @MainActor func testEngineExcludesReadAndNotInterested() async throws {
        let history = makeHistoryStore()
        let taste = makeTasteStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        taste.markNotInterested(mangaId: "rec2")
        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("rec1"), scored("rec2"), scored("m1")]),
                                workStore: works)
        await engine.refresh()
        // rec2 = not interested, m1 = already read → both excluded.
        XCTAssertEqual(engine.recommendations.map(\.manga.id), ["rec1"])
    }

    // MARK: - Rail state (ADR-0015)

    /// Reads `id` without ever giving it tags — the untaggable case the notice exists for.
    @MainActor private func untaggedRead(_ history: HistoryStore, _ id: String) {
        history.record(manga: sampleManga(id), chapter: ch("1"),
                       position: ReadingPosition(page: 9), pageCount: 10)
    }

    @MainActor func testRailStateStartsBuilding() {
        let engine = makeEngine(history: makeHistoryStore(), tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: []))
        XCTAssertEqual(engine.railState, .building)
    }

    @MainActor func testRailStateReadyWhenGateOpens() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works)
        await engine.refresh()
        XCTAssertEqual(engine.railState, .ready(tagged: 3, of: 3))
    }

    /// Found on the simulator 2026-08-10, on a device with no `history.entries` at all:
    /// the app told a reader who had read nothing that the manga in their history
    /// couldn't be matched to a catalog. ADR-0015 exists *because* a permanent dead end
    /// was indistinguishable from cold start; amendment 3's ceiling test made them
    /// identical again, in the dead end's favour.
    @MainActor func testEmptyHistoryIsColdStartNotADeadEnd() async throws {
        let engine = makeEngine(history: makeHistoryStore(), tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                tagBlocked: { _ in true })
        await engine.refresh()
        XCTAssertEqual(engine.railState, .needMoreReading(tagged: 0, needed: 3),
                       "nothing read is not a dead end")
    }

    /// The same defect one step in: one untaggable title read is still too little
    /// reading to conclude anything about the library. `noTaggableSignal` claims
    /// "enough reading, nothing identifiable" — the first half has to hold.
    @MainActor func testOneBlockedReadTitleIsStillColdStart() async throws {
        let history = makeHistoryStore()
        untaggedRead(history, "m1")
        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                tagBlocked: { _ in true })
        await engine.refresh()
        XCTAssertEqual(engine.railState, .needMoreReading(tagged: 0, needed: 3))
    }

    // MARK: - The rail's basis count (ADR-0015, amended 2026-08-10)

    /// The whole point of the payload: the gate opened on 3 tagged Works, but two more
    /// read titles contributed nothing, so the rail is built from three fifths of the
    /// reader's actual history. Hazard 3 of ADR-0015, made visible.
    @MainActor func testReadyReportsTaggedOutOfReadTitles() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        for i in 1...2 { untaggedRead(history, "u\(i)") }

        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works)
        await engine.refresh()
        XCTAssertEqual(engine.railState, .ready(tagged: 3, of: 5))
    }

    /// The denominator is *read* titles, not the library. A saved-but-unread title can
    /// never enter the numerator (`taggedCount` increments only under `!entries.isEmpty`),
    /// so counting it in `of:` would report the reader's backlog as a recommender failure.
    @MainActor func testSavedButUnreadTitlesAreNotPartOfTheBasis() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        let lib = LibraryStore(defaults: UserDefaults(suiteName: "test.lib.\(UUID().uuidString)")!)
        lib.toggle(sampleManga("saved-never-read"))

        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works, library: lib)
        await engine.refresh()
        XCTAssertEqual(engine.railState, .ready(tagged: 3, of: 3),
                       "a saved title moves neither number")
    }

    /// ADR-0001: the count is over Works, not Listings. The same series read on two
    /// sources is one title the rail is based on, because it contributes one taste
    /// signal — the honest description of what the recommender actually used.
    @MainActor func testBasisCountsWorksNotListings() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        // Two Listings publishing the same MAL id — as a detail-screen visit to each
        // would have minted them — collapse to one Work via the external-id dedupe path.
        let onMangaDex = Manga(id: "dex-solo", sourceId: "mangadex", title: "Solo Leveling",
                               description: "", status: "ongoing", year: nil, coverURL: nil, malId: 121496)
        let onWeebCentral = Manga(id: "wc-solo", sourceId: "weebcentral", title: "Solo Leveling",
                                  description: "", status: "ongoing", year: nil, coverURL: nil, malId: 121496)
        XCTAssertEqual(works.mint(from: onMangaDex), works.mint(from: onWeebCentral),
                       "precondition: the two listings are one Work")
        history.record(manga: onMangaDex, chapter: ch("1"), position: ReadingPosition(page: 9), pageCount: 10)
        history.record(manga: onWeebCentral, chapter: ch("2"), position: ReadingPosition(page: 9), pageCount: 10)

        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works)
        await engine.refresh()
        XCTAssertEqual(engine.railState, .ready(tagged: 3, of: 4),
                       "two listings of one series count once")
    }

    /// Untagged Works the drain has not answered for yet are still in play, so the
    /// ceiling has not been reached and the rail stays silent rather than explaining.
    @MainActor func testRailStateNeedMoreReadingWhileUntaggedWorksAreStillInPlay() async throws {
        let history = makeHistoryStore()
        for i in 1...3 { untaggedRead(history, "m\(i)") }
        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                tagBlocked: { _ in false })
        await engine.refresh()
        XCTAssertEqual(engine.railState, .needMoreReading(tagged: 0, needed: 3))
        XCTAssertTrue(engine.recommendations.isEmpty)
    }

    @MainActor func testRailStateNoTaggableSignalWhenEveryUntaggedWorkIsBlocked() async throws {
        let history = makeHistoryStore()
        for i in 1...3 { untaggedRead(history, "m\(i)") }
        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                tagBlocked: { _ in true })
        await engine.refresh()
        XCTAssertEqual(engine.railState, .noTaggableSignal)
    }

    /// The case the ADR's original universal quantifier could not see (amendment 3):
    /// one Work failing transiently is never recorded, so "every untagged Work is
    /// blocked" is false forever — yet 1 tagged + 1 in play cannot reach 3.
    @MainActor func testRailStateNoTaggableSignalWhenArithmeticCannotReachTheGate() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        tagRead(works, history, "tagged1", [Tag(id: "a", name: "Action", group: "genre")])
        for i in 1...5 { untaggedRead(history, "blocked\(i)") }
        untaggedRead(history, "transient")
        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works,
                                tagBlocked: { work in
                                    !work.knownTitles.contains("Title transient")
                                })
        await engine.refresh()
        // 1 tagged + 1 unblocked = 2 < 3: even tagging everything left cannot open it.
        XCTAssertEqual(engine.railState, .noTaggableSignal)
    }

    /// The documented non-fix: with two tagged Works already, one perpetually transient
    /// Work could still open the gate, so silence remains correct.
    @MainActor func testRailStateStaysSilentWhenOneUnblockedWorkCouldStillOpenTheGate() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        for i in 1...2 { tagRead(works, history, "t\(i)", [Tag(id: "a", name: "Action", group: "genre")]) }
        untaggedRead(history, "transient")
        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works, tagBlocked: { _ in false })
        await engine.refresh()
        XCTAssertEqual(engine.railState, .needMoreReading(tagged: 2, needed: 3))
    }

    /// Amendment 1: the closure is handed the whole `Work`, so the caller cannot pair
    /// the wrong `knownTitles` count with the wrong id.
    ///
    /// Reads three titles rather than one because amendment 8's reading precondition
    /// short-circuits `refusalReason` before the closure is consulted at all. The claim
    /// under test is the closure's *signature*, so it needs a library that actually
    /// reaches it — not a weaker assertion.
    @MainActor func testTagBlockedReceivesTheWholeWork() async throws {
        let history = makeHistoryStore()
        for i in 1...3 { untaggedRead(history, "m\(i)") }
        var seen: [Work] = []
        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: []),
                                tagBlocked: { work in seen.append(work); return false })
        await engine.refresh()
        XCTAssertEqual(seen.count, 3)
        // A Set, because signals arrive newest-read-first and this test is about what the
        // closure is handed, not the order it is handed things in.
        XCTAssertEqual(Set(seen.flatMap(\.knownTitles)), ["Title m1", "Title m2", "Title m3"])
    }

    /// The per-title question the detail screen asks (ADR-0005's visibility requirement).
    /// It is the *same* predicate the rail state is built from, deliberately: a second way
    /// to ask would let the detail screen and the rail disagree about one Work.
    @MainActor func testIsUnmatchableAnswersForOneWork() async throws {
        let history = makeHistoryStore()
        let works = makeWorkStore()
        untaggedRead(history, "refused")
        untaggedRead(history, "pending")

        let engine = makeEngine(history: history, tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: []),
                                workStore: works,
                                tagBlocked: { $0.knownTitles.contains("Title refused") })
        // Minting happens on the real path — the engine resolving signals out of history.
        await engine.refresh()

        let byTitle = Dictionary(uniqueKeysWithValues: works.allWorkIds()
            .compactMap { works.work($0) }
            .map { ($0.displayTitle, $0) })
        let refused = try XCTUnwrap(byTitle["Title refused"])
        let pending = try XCTUnwrap(byTitle["Title pending"])

        XCTAssertTrue(engine.isUnmatchable(refused))
        // Untagged but never answered for: the notice must stay off, or it would claim a
        // refusal the drain has not made.
        XCTAssertFalse(engine.isUnmatchable(pending))
    }

    // MARK: - Engagement weight push (ADR-0010)

    /// The recommender pushes; the queue never pulls. Pulling would mean the queue
    /// building a profile of its own, and `TasteProfile.build` mints Works as a side
    /// effect — a background loop would then mint from browsing (ADR-0009).
    @MainActor func testBuildingAProfilePushesItsWorkWeights() async throws {
        let history = makeHistoryStore()
        let taste = makeTasteStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        var pushed: [[WorkID: Double]] = []

        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works,
                                pushPriority: { pushed.append($0) })
        await engine.refresh()

        let weights = try XCTUnwrap(pushed.last)
        let expected = try (1...3).map {
            try XCTUnwrap(works.workId(for: ListingKey(sourceId: "mangadex", mangaId: "m\($0)")))
        }
        XCTAssertEqual(Set(weights.keys), Set(expected))
        XCTAssertTrue(weights.values.allSatisfy { $0 > 0 })
    }

    /// The push is below the cold-start gate on purpose. Pushing an empty map from a
    /// profile that was rejected would overwrite a good ordering the queue is already
    /// draining against, and hand it a blank one (ADR-0010).
    @MainActor func testAColdStartProfilePushesNothing() async throws {
        let history = makeHistoryStore()
        let taste = makeTasteStore()
        let works = makeWorkStore()
        tagRead(works, history, "m1", [Tag(id: "a", name: "A", group: "genre")])
        tagRead(works, history, "m2", [Tag(id: "b", name: "B", group: "genre")])
        var pushed: [[WorkID: Double]] = []

        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("x")]),
                                workStore: works,
                                pushPriority: { pushed.append($0) })
        await engine.refresh()

        XCTAssertTrue(pushed.isEmpty, "a rejected profile is not an ordering")
    }

    /// Pins that the push lives in `profileAndExclusions`, not in `rebuild`: "See all"
    /// builds the same profile without touching the rail, and that is just as good a
    /// signal about what the user cares about.
    @MainActor func testTheSeeAllGridPushesToo() async throws {
        let history = makeHistoryStore()
        let taste = makeTasteStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        var pushed: [[WorkID: Double]] = []

        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("rec1")]),
                                workStore: works,
                                pushPriority: { pushed.append($0) })
        _ = await engine.rankedRecommendations()

        XCTAssertEqual(pushed.count, 1)
        XCTAssertEqual(pushed.first?.count, 3)
    }

    @MainActor func testComposeIsDeterministicForASeed() {
        let history = makeHistoryStore(); let taste = makeTasteStore()
        let pool = (0..<40).map { scored("p\($0)") }
        let a = makeEngine(history: history, tasteStore: taste, provider: FixedPoolProvider(pool: []), seed: 42)
        let b = makeEngine(history: history, tasteStore: taste, provider: FixedPoolProvider(pool: []), seed: 42)
        XCTAssertEqual(a.compose(pool: pool).map(\.manga.id), b.compose(pool: pool).map(\.manga.id))
    }

    @MainActor func testComposeKeepsAllWhenPoolSmall() {
        let history = makeHistoryStore(); let taste = makeTasteStore()
        let pool = (0..<5).map { scored("p\($0)") }
        let engine = makeEngine(history: history, tasteStore: taste, provider: FixedPoolProvider(pool: []))
        XCTAssertEqual(engine.compose(pool: pool).count, 5)
    }

    @MainActor func testMarkNotInterestedRemovesFromRailAndPersists() async throws {
        let history = makeHistoryStore(); let taste = makeTasteStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("rec1"), scored("rec2")]),
                                workStore: works)
        await engine.refresh()
        engine.markNotInterested(sampleManga("rec1"))
        XCTAssertFalse(engine.recommendations.contains { $0.manga.id == "rec1" })
        XCTAssertTrue(taste.notInterested.contains("rec1"))
    }

    /// The migration that makes retiring the tag cache safe: a user upgrading across
    /// this change has tags only in the legacy UserDefaults key, and `resolveSignals`
    /// must copy them onto Works or their profile comes back empty on first launch.
    /// **This is the last thing reading `legacyTagCache`** — when it goes, so does it.
    @MainActor func testLegacyTagCacheSeedsWorksSoTheProfileSurvivesUpgrade() async throws {
        let history = makeHistoryStore()
        let suite = UserDefaults(suiteName: "test.taste.\(UUID().uuidString)")!
        let action = [Tag(id: "a", name: "Action", group: "genre")]
        seedLegacyTagCache(suite, ["m1": action, "m2": action, "m3": action])
        let taste = TasteProfileStore(defaults: suite)

        // History only — no Works, no provisional snapshots. Exactly a pre-slice-3 user.
        for i in 1...3 {
            history.record(manga: sampleManga("m\(i)"), chapter: ch("1"), position: ReadingPosition(page: 9), pageCount: 10)
        }
        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("rec1")]))
        await engine.refresh()
        XCTAssertEqual(engine.recommendations.map(\.manga.id), ["rec1"])
    }

    @MainActor func testRankedRecommendationsEmptyOnColdStart() async {
        let engine = makeEngine(history: makeHistoryStore(), tasteStore: makeTasteStore(),
                                provider: FixedPoolProvider(pool: [scored("x")]))
        let out = await engine.rankedRecommendations(limit: 50)
        XCTAssertTrue(out.isEmpty)
    }

    @MainActor func testRankedRecommendationsReturnsRankedMangaWithoutShuffle() async {
        let history = makeHistoryStore(); let taste = makeTasteStore()
        let works = makeWorkStore()
        for i in 1...3 {
            tagRead(works, history, "m\(i)", [Tag(id: "a", name: "Action", group: "genre")])
        }
        let engine = makeEngine(history: history, tasteStore: taste,
                                provider: FixedPoolProvider(pool: [scored("r1"), scored("r2"), scored("m1")]),
                                workStore: works)
        let out = await engine.rankedRecommendations(limit: 50)
        // Straight ranking order, read manga (m1) excluded, no exploration reshuffle.
        XCTAssertEqual(out.map(\.id), ["r1", "r2"])
    }

    // MARK: - MyAnimeListAPI DTOs

    func testMyAnimeListSearchResponseDecodesAndUnwrapsNode() throws {
        let json = """
        {
          "data": [
            {
              "node": {
                "id": 2,
                "title": "Berserk",
                "main_picture": {
                  "medium": "https://example.com/berserk_m.jpg",
                  "large": "https://example.com/berserk_l.jpg"
                }
              }
            },
            {
              "node": { "id": 401, "title": "Berserk: The Prototype" }
            }
          ]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MyAnimeListSearchResponse.self, from: json)
        XCTAssertEqual(response.data.map(\.node.id), [2, 401])
        XCTAssertEqual(response.data[0].node.title, "Berserk")
        XCTAssertEqual(response.data[0].node.mainPicture?.medium,
                       "https://example.com/berserk_m.jpg")
        XCTAssertNil(response.data[1].node.mainPicture)
    }

    func testMyAnimeListMangaDetailDecodesRelatedAndRecommendations() throws {
        let json = """
        {
          "id": 2,
          "title": "Berserk",
          "synopsis": "Guts, a former mercenary...",
          "main_picture": {
            "medium": "https://example.com/berserk_m.jpg",
            "large": "https://example.com/berserk_l.jpg"
          },
          "genres": [
            {"id": 1, "name": "Action"},
            {"id": 8, "name": "Drama"}
          ],
          "related_manga": [
            {
              "node": {"id": 401, "title": "Berserk: The Prototype"},
              "relation_type": "prequel",
              "relation_type_formatted": "Prequel"
            }
          ],
          "recommendations": [
            {
              "node": {"id": 656, "title": "Vagabond"},
              "num_recommendations": 42
            }
          ]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(MyAnimeListMangaDetail.self, from: json)
        XCTAssertEqual(detail.title, "Berserk")
        XCTAssertEqual(detail.genres?.map(\.name), ["Action", "Drama"])
        XCTAssertEqual(detail.relatedManga?.first?.node.title, "Berserk: The Prototype")
        XCTAssertEqual(detail.relatedManga?.first?.relationTypeFormatted, "Prequel")
        XCTAssertEqual(detail.recommendations?.first?.node.title, "Vagabond")
        XCTAssertEqual(detail.recommendations?.first?.numRecommendations, 42)
    }

    func testMyAnimeListMangaDetailDecodesWithoutOptionalRelations() throws {
        let json = """
        {
          "id": 977,
          "title": "One-Off Oneshot",
          "synopsis": null,
          "main_picture": null,
          "genres": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(MyAnimeListMangaDetail.self, from: json)
        XCTAssertEqual(detail.id, 977)
        XCTAssertEqual(detail.title, "One-Off Oneshot")
        XCTAssertNil(detail.synopsis)
        XCTAssertNil(detail.genres)
        XCTAssertNil(detail.relatedManga)
        XCTAssertNil(detail.recommendations)
    }

    func testMyAnimeListMangaDecodesAlternativeTitlesAndAllTitles() throws {
        let json = """
        {
          "id": 25,
          "title": "Shingeki no Kyojin",
          "alternative_titles": {
            "synonyms": ["AoT"],
            "en": "Attack on Titan",
            "ja": "進撃の巨人"
          }
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manga = try decoder.decode(MyAnimeListManga.self, from: json)

        XCTAssertEqual(manga.alternativeTitles?.en, "Attack on Titan")
        XCTAssertEqual(manga.alternativeTitles?.ja, "進撃の巨人")
        XCTAssertEqual(manga.alternativeTitles?.synonyms, ["AoT"])
        // allTitles: main first, then en, ja, synonyms — no empties, deduped.
        XCTAssertEqual(manga.allTitles,
                       ["Shingeki no Kyojin", "Attack on Titan", "進撃の巨人", "AoT"])
    }

    func testMyAnimeListMangaAllTitlesWithoutAlternatives() throws {
        let json = #"{ "id": 1, "title": "Solo Leveling" }"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manga = try decoder.decode(MyAnimeListManga.self, from: json)
        XCTAssertNil(manga.alternativeTitles)
        XCTAssertEqual(manga.allTitles, ["Solo Leveling"])
    }

    /// MAL rejects a `q` longer than 64 characters with HTTP 400. Verified live against
    /// the real API 2026-07-28: 64 characters returns 200, 65 returns 400. Untruncated
    /// queries are what stalled the upgrade queue on long doujinshi titles.
    func testSearchQueryIsTruncatedToMALsSixtyFourCharacterLimit() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(MyAnimeListAPI.searchQuery(for: long).count, 64)
        XCTAssertEqual(MyAnimeListAPI.searchQuery(for: "Berserk"), "Berserk",
                       "anything within the limit is passed through untouched")
    }

    /// The limit counts characters, not UTF-8 bytes — also verified live: 64 multibyte
    /// characters (192 bytes) returns 200. Truncating on bytes would needlessly cut
    /// Japanese titles to a third of the usable length.
    func testSearchQueryTruncationCountsCharactersNotBytes() {
        let japanese = String(repeating: "ベ", count: 100)
        let truncated = MyAnimeListAPI.searchQuery(for: japanese)
        XCTAssertEqual(truncated.count, 64)
        XCTAssertEqual(truncated.utf8.count, 192)
    }

    func testMyAnimeListErrorDescriptions() {
        XCTAssertEqual(MyAnimeListError.missingClientID.errorDescription,
                       "Missing MyAnimeList API client ID. Set MAL_CLIENT_ID in Secrets.xcconfig.")
        XCTAssertEqual(MyAnimeListError.httpStatus(404).errorDescription,
                       "MyAnimeList request failed with HTTP status 404.")
    }

    // MARK: - MALTitleMatcher

    func testMALNormalizeStripsCaseDiacriticsPunctuationAndNoise() {
        XCTAssertEqual(MALTitleMatcher.normalize("Attack on Titan (Manga)"), "attack on titan")
        XCTAssertEqual(MALTitleMatcher.normalize("Ōkami!!  Shōnen"), "okami shonen")
        XCTAssertEqual(MALTitleMatcher.normalize("  Berserk  "), "berserk")
    }

    func testMALSimilarityExactAfterNormalizationIsOne() {
        XCTAssertEqual(MALTitleMatcher.similarity("attack on titan", "attack on titan"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MALTitleMatcher.similarity("", "berserk"), 0.0, accuracy: 0.0001)
    }

    func testMALDecideMatchesViaAlternativeTitle() {
        // Source uses the English title; MAL's main title is the romaji one — the match
        // must come from the alternate title in the candidate's title set.
        let matcher = MALTitleMatcher()
        let candidates = [
            MALCandidate(malId: 25, titles: ["Shingeki no Kyojin", "Attack on Titan"]),
            MALCandidate(malId: 99, titles: ["Some Unrelated Manga"]),
        ]
        XCTAssertEqual(matcher.decide(sourceTitle: "Attack on Titan", candidates: candidates),
                       .matched(malId: 25))
    }

    func testMALDecideRejectsBelowThreshold() {
        let matcher = MALTitleMatcher()
        let candidates = [MALCandidate(malId: 1, titles: ["Completely Different Story"])]
        XCTAssertEqual(matcher.decide(sourceTitle: "Berserk", candidates: candidates), .noMatch)
    }

    func testMALDecideAmbiguityGuardRejectsNearTiedCandidates() {
        // Two distinct MAL entries share the exact title — genuinely ambiguous, reject.
        let matcher = MALTitleMatcher()
        let candidates = [
            MALCandidate(malId: 1, titles: ["Hero"]),
            MALCandidate(malId: 2, titles: ["Hero"]),
        ]
        XCTAssertEqual(matcher.decide(sourceTitle: "Hero", candidates: candidates), .noMatch)
    }

    func testMALDecideAcceptsClearWinnerOverWeakRunnerUp() {
        let matcher = MALTitleMatcher()
        let candidates = [
            MALCandidate(malId: 1, titles: ["Vinland Saga"]),
            MALCandidate(malId: 2, titles: ["Totally Other Thing"]),
        ]
        XCTAssertEqual(matcher.decide(sourceTitle: "Vinland Saga", candidates: candidates),
                       .matched(malId: 1))
    }

    func testMALDecideEmptyInputsAreNoMatch() {
        let matcher = MALTitleMatcher()
        XCTAssertEqual(matcher.decide(sourceTitle: "", candidates: [MALCandidate(malId: 1, titles: ["X"])]), .noMatch)
        XCTAssertEqual(matcher.decide(sourceTitle: "X", candidates: []), .noMatch)
    }

    func testMALBestMatchIsGenericOverStringId() {
        let matcher = MALTitleMatcher()
        let candidates: [(id: String, titles: [String])] = [
            (id: "md-1", titles: ["Shingeki no Kyojin", "Attack on Titan"]),
            (id: "md-2", titles: ["Some Unrelated Manga"]),
        ]
        XCTAssertEqual(matcher.bestMatch(sourceTitle: "Attack on Titan", candidates: candidates), "md-1")
    }

    func testMALBestMatchRejectsAmbiguousAndBelowThreshold() {
        let matcher = MALTitleMatcher()
        // Two identical titles → ambiguity guard → nil.
        XCTAssertNil(matcher.bestMatch(sourceTitle: "Hero", candidates: [
            (id: 1, titles: ["Hero"]),
            (id: 2, titles: ["Hero"]),
        ]))
        // Nothing clears the acceptance threshold → nil.
        XCTAssertNil(matcher.bestMatch(sourceTitle: "Berserk", candidates: [
            (id: 1, titles: ["Completely Different Story"]),
        ]))
        // Empty candidates / empty source → nil.
        XCTAssertNil(matcher.bestMatch(sourceTitle: "Berserk", candidates: [(id: Int, titles: [String])]()))
        XCTAssertNil(matcher.bestMatch(sourceTitle: "", candidates: [(id: 1, titles: ["Berserk"])]))
    }

    /// Resolution runs at the **Work** level, so the source side is the Work's whole
    /// `knownTitles` set and each candidate scores over the title cross-product
    /// (ADR-0008). This is the recall ADR-0007 built `knownTitles` for and never
    /// collected: one Listing's spelling misses, a second Listing's finds it.
    func testMALBestMatchScoresOverTheWholeSourceTitleSet() {
        let matcher = MALTitleMatcher()
        let candidates: [(id: Int, titles: [String])] = [(id: 25, titles: ["Solo Leveling"])]

        XCTAssertNil(matcher.bestMatch(sourceTitle: "Only I Level Up", candidates: candidates),
                     "the scraped source's spelling alone does not reach the threshold")
        XCTAssertEqual(matcher.bestMatch(sourceTitles: ["Only I Level Up", "Solo Leveling"],
                                         candidates: candidates), 25)
    }

    /// The property the cross-product exists to preserve, and the reason ADR-0008
    /// rejected "run the single-title matcher per title and take the best": each source
    /// title here matches a *different* candidate exactly, so N independent passes would
    /// each report a confident winner and the max would pick one arbitrarily. One ranked
    /// list sees two 1.0 scores and refuses. Precision over recall.
    func testMALCrossProductMatchingStillRejectsAmbiguity() {
        let matcher = MALTitleMatcher()
        let candidates: [(id: Int, titles: [String])] = [
            (id: 1, titles: ["Solo Leveling"]),
            (id: 2, titles: ["Only I Level Up"]),
        ]
        XCTAssertNil(matcher.bestMatch(sourceTitles: ["Solo Leveling", "Only I Level Up"],
                                       candidates: candidates))
    }

    /// `knownTitles` accumulates from whatever Listings supply, so blanks are a real
    /// input rather than a hypothetical. They must drop out instead of scoring 0 and
    /// dragging a candidate down.
    func testMALPluralBestMatchDropsBlankSourceTitles() {
        let matcher = MALTitleMatcher()
        let candidates: [(id: Int, titles: [String])] = [(id: 1, titles: ["Berserk"])]

        XCTAssertEqual(matcher.bestMatch(sourceTitles: ["", "   ", "Berserk"],
                                         candidates: candidates), 1)
        XCTAssertNil(matcher.bestMatch(sourceTitles: [], candidates: candidates))
        XCTAssertNil(matcher.bestMatch(sourceTitles: ["", "  "], candidates: candidates))
    }

    // MARK: - EntityResolutionStore

    @MainActor func testEntityResolutionRecordsAndReadsBack() {
        let defaults = UserDefaults(suiteName: "test.entityres.\(UUID().uuidString)")!
        let store = EntityResolutionStore(defaults: defaults)
        store.record(sourceId: "weebcentral", mangaId: "abc", .resolved(malId: 42))
        XCTAssertEqual(store.resolution(sourceId: "weebcentral", mangaId: "abc"), .resolved(malId: 42))
        XCTAssertNil(store.resolution(sourceId: "weebcentral", mangaId: "other"))
    }

    @MainActor func testEntityResolutionKeysAreSourceQualified() {
        let defaults = UserDefaults(suiteName: "test.entityres.\(UUID().uuidString)")!
        let store = EntityResolutionStore(defaults: defaults)
        store.record(sourceId: "weebcentral", mangaId: "x", .resolved(malId: 1))
        store.record(sourceId: "mangadex", mangaId: "x", .resolved(malId: 2))
        XCTAssertEqual(store.resolution(sourceId: "weebcentral", mangaId: "x"), .resolved(malId: 1))
        XCTAssertEqual(store.resolution(sourceId: "mangadex", mangaId: "x"), .resolved(malId: 2))
    }

    func testMALResolutionFreshness() {
        XCTAssertTrue(MALResolution.resolved(malId: 1).isFresh())            // hits never expire
        let now = Date()
        let justMissed = MALResolution.unresolved(checkedAt: now)
        XCTAssertTrue(justMissed.isFresh(now: now))
        let old = MALResolution.unresolved(checkedAt: now.addingTimeInterval(-EntityResolutionStore.missTTL - 1))
        XCTAssertFalse(old.isFresh(now: now))                               // past TTL → stale
    }

    @MainActor func testEntityResolutionPersistsAcrossInstances() {
        let suite = "test.entityres.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        EntityResolutionStore(defaults: defaults).record(sourceId: "s", mangaId: "m", .resolved(malId: 7))
        let reloaded = EntityResolutionStore(defaults: defaults)
        XCTAssertEqual(reloaded.resolution(sourceId: "s", mangaId: "m"), .resolved(malId: 7))
    }

    // MARK: - EntityResolutionStore reverse cache

    @MainActor func testReverseCacheRoundTripsAndKeysByMalId() {
        let defaults = UserDefaults(suiteName: "test.reverse.\(UUID().uuidString)")!
        let store = EntityResolutionStore(defaults: defaults)
        store.recordReverse(malId: 42, .resolved(mangaDexId: "md-abc"))
        XCTAssertEqual(store.reverseResolution(malId: 42), .resolved(mangaDexId: "md-abc"))
        XCTAssertNil(store.reverseResolution(malId: 99))
    }

    @MainActor func testReverseCacheDoesNotCollideWithForwardCache() {
        let defaults = UserDefaults(suiteName: "test.reverse.\(UUID().uuidString)")!
        let store = EntityResolutionStore(defaults: defaults)
        // Forward map keyed "{sourceId}:{mangaId}"; reverse keyed String(malId). Same
        // numeric value must not bleed across the two maps.
        store.record(sourceId: "mangadex", mangaId: "7", .resolved(malId: 7))
        store.recordReverse(malId: 7, .resolved(mangaDexId: "md-7"))
        XCTAssertEqual(store.resolution(sourceId: "mangadex", mangaId: "7"), .resolved(malId: 7))
        XCTAssertEqual(store.reverseResolution(malId: 7), .resolved(mangaDexId: "md-7"))
    }

    func testReverseResolutionIsFreshHonorsMissTTL() {
        let now = Date()
        let fresh = ReverseResolution.unresolved(checkedAt: now.addingTimeInterval(-EntityResolutionStore.missTTL + 1))
        let stale = ReverseResolution.unresolved(checkedAt: now.addingTimeInterval(-EntityResolutionStore.missTTL - 1))
        XCTAssertTrue(fresh.isFresh(now: now))
        XCTAssertFalse(stale.isFresh(now: now))
        XCTAssertTrue(ReverseResolution.resolved(mangaDexId: "x").isFresh(now: now))
    }

    @MainActor func testReverseCachePersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "test.reverse.\(UUID().uuidString)")!
        EntityResolutionStore(defaults: defaults).recordReverse(malId: 11, .resolved(mangaDexId: "md-11"))
        let reloaded = EntityResolutionStore(defaults: defaults)
        XCTAssertEqual(reloaded.reverseResolution(malId: 11), .resolved(mangaDexId: "md-11"))
    }

    // MARK: - MALEntityResolver

    @MainActor func testResolverFastPathReturnsMangaMalIdWithoutTouchingStore() async {
        let defaults = UserDefaults(suiteName: "test.resolver.\(UUID().uuidString)")!
        let store = EntityResolutionStore(defaults: defaults)
        let resolver = MALEntityResolver(store: store)
        let manga = Manga(id: "m", sourceId: "mangadex", title: "Berserk",
                          description: "", status: "ongoing", year: nil, coverURL: nil, malId: 2)
        let id = await resolver.malId(for: manga)
        XCTAssertEqual(id, 2)
        XCTAssertTrue(store.cache.isEmpty, "fast path must not write to the cache")
    }

    @MainActor func testResolverReturnsCachedResolvedHit() async {
        let defaults = UserDefaults(suiteName: "test.resolver.\(UUID().uuidString)")!
        let store = EntityResolutionStore(defaults: defaults)
        store.record(sourceId: "weebcentral", mangaId: "x", .resolved(malId: 55))
        let resolver = MALEntityResolver(store: store)
        let manga = Manga(id: "x", sourceId: "weebcentral", title: "Whatever",
                          description: "", status: "unknown", year: nil, coverURL: nil, malId: nil)
        let id = await resolver.malId(for: manga)
        XCTAssertEqual(id, 55)   // returned from cache; no network
    }

    @MainActor func testResolverReturnsNilForFreshCachedMiss() async {
        let defaults = UserDefaults(suiteName: "test.resolver.\(UUID().uuidString)")!
        let store = EntityResolutionStore(defaults: defaults)
        store.record(sourceId: "weebcentral", mangaId: "x", .unresolved(checkedAt: Date()))
        let resolver = MALEntityResolver(store: store)
        let manga = Manga(id: "x", sourceId: "weebcentral", title: "Whatever",
                          description: "", status: "unknown", year: nil, coverURL: nil, malId: nil)
        let id = await resolver.malId(for: manga)
        XCTAssertNil(id)   // fresh miss short-circuits before any network call
    }

    // MARK: - MALEntityResolver, Work-level (ADR-0008/0009)

    private func work(_ titles: [String],
                      mal: Int? = nil,
                      listings: [ListingKey] = []) -> Work {
        Work(id: WorkID(), displayTitle: titles.first ?? "",
             knownTitles: titles, externalIds: ExternalIDs(mal: mal, anilist: nil),
             listings: listings, snapshot: nil)
    }

    /// The payoff ADR-0007 built `knownTitles` for: only the *second* Listing's spelling
    /// retrieves anything from MAL, and the Work resolves anyway. A per-Listing resolver
    /// asked about the scraped title alone gets nothing.
    @MainActor func testWorkResolutionMatchesUsingASecondListingsTitle() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, search: { title in
            title == "Solo Leveling" ? [MALCandidate(malId: 121, titles: ["Solo Leveling"])] : []
        }, bridgeSearch: MALEntityResolver.noBridge)

        let id = try await resolver.resolve(work(["Only I Level Up", "Solo Leveling"])).malId

        XCTAssertEqual(id, 121)
        XCTAssertTrue(store.cache.isEmpty,
                      "a Work-level answer has no single Listing to key on (ADR-0008)")
    }

    /// The two failures are different records in the queue's attempt memory — nothing at
    /// all for a transient failure, `.unmatched` for a real miss — so they cannot both be
    /// `nil`. An outage must not be remembered as "MAL doesn't have this".
    @MainActor func testWorkResolutionThrowsWhenEverySearchFailed() async {
        struct Boom: Error {}
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, search: { _ in throw Boom() },
                                         bridgeSearch: MALEntityResolver.noBridge)

        do {
            _ = try await resolver.resolve(work(["Berserk"]))
            XCTFail("a transient failure must not be reported as a miss")
        } catch {}
    }

    /// Partial failure: a match stands on its own. The search that failed could only have
    /// added candidates, and extra candidates are evidence *against* via the ambiguity
    /// guard — never for. Throwing away a confident match here would buy nothing.
    @MainActor func testWorkResolutionKeepsAMatchFoundDespiteAFailedSearch() async throws {
        struct Boom: Error {}
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, search: { title in
            if title == "Only I Level Up" { throw Boom() }
            return [MALCandidate(malId: 121, titles: ["Solo Leveling"])]
        }, bridgeSearch: MALEntityResolver.noBridge)

        let id = try await resolver.resolve(work(["Only I Level Up", "Solo Leveling"])).malId

        XCTAssertEqual(id, 121)
    }

    /// The genuine miss: MAL answered, nothing cleared the threshold. This is the one the
    /// queue records as `.unmatched(knownTitlesCount)`.
    @MainActor func testWorkResolutionReturnsNilWhenSearchesSucceedButNothingMatches() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, search: { _ in
            [MALCandidate(malId: 9, titles: ["Completely Different Story"])]
        }, bridgeSearch: MALEntityResolver.noBridge)

        let id = try await resolver.resolve(work(["Berserk"])).malId

        XCTAssertNil(id)
    }

    /// ADR-0008 rejected `EntityResolutionStore` as the *home* of Work-level answers, not
    /// as a source of them: a hit recorded by a detail-page open is a valid answer for any
    /// Work containing that Listing, and costs no request.
    @MainActor func testWorkResolutionReusesAListingLevelHitWithoutSearching() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        store.record(sourceId: "weebcentral", mangaId: "x", .resolved(malId: 55))
        let resolver = MALEntityResolver(store: store, search: { _ in
            XCTFail("a cached Listing hit must answer without touching MAL")
            return []
        }, bridgeSearch: MALEntityResolver.noBridge)

        let id = try await resolver.resolve(
            work(["Whatever"],
                 listings: [ListingKey(sourceId: "weebcentral", mangaId: "x")])).malId

        XCTAssertEqual(id, 55)
    }

    /// The fan-out is capped, so a heavily-merged Work cannot issue one search per title
    /// forever. Asserted behaviourally: with a limit of one, the *second* title — the only
    /// one MAL would answer — is never searched, so the Work does not resolve.
    @MainActor func testWorkResolutionSearchesAtMostTheTitleLimit() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, titleSearchLimit: 1, search: { title in
            title == "Solo Leveling" ? [MALCandidate(malId: 121, titles: ["Solo Leveling"])] : []
        }, bridgeSearch: MALEntityResolver.noBridge)

        let id = try await resolver.resolve(work(["Only I Level Up", "Solo Leveling"])).malId

        XCTAssertNil(id)
    }

    // MARK: - Excluding novels from MAL candidates (ADR-0017)

    private func malNode(_ id: Int, _ title: String, mediaType: String?) throws -> MyAnimeListManga {
        let json = """
        { "id": \(id), "title": "\(title)",
          \(mediaType.map { "\"media_type\": \"\($0)\"," } ?? "")
          "alternative_titles": { "en": "\(title)", "ja": null, "synonyms": [] } }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MyAnimeListManga.self, from: json)
    }

    /// The real collision, from the live API on 2026-08-10: MAL carries the *Solo Leveling*
    /// manhwa and the *Solo Leveling* novel under the same title, so the matcher sees two
    /// candidates at 1.000 and the ambiguity guard refuses. Dropping the novel leaves one.
    func testExcludingNovelsRemovesTheProseTwinOfAnAdaptation() throws {
        let candidates = [try malNode(121_496, "Solo Leveling", mediaType: "manhwa"),
                          try malNode(119_184, "Solo Leveling", mediaType: "novel")]

        let kept = MyAnimeListAPI.excludingNovels(candidates)

        XCTAssertEqual(kept.map(\.id), [121_496])
    }

    func testExcludingNovelsDropsLightNovelsAndKeepsEveryComicForm() throws {
        let candidates = [try malNode(1, "A", mediaType: "manga"),
                          try malNode(2, "B", mediaType: "manhwa"),
                          try malNode(3, "C", mediaType: "manhua"),
                          try malNode(4, "D", mediaType: "one_shot"),
                          try malNode(5, "E", mediaType: "doujinshi"),
                          try malNode(6, "F", mediaType: "novel"),
                          try malNode(7, "G", mediaType: "light_novel")]

        XCTAssertEqual(MyAnimeListAPI.excludingNovels(candidates).map(\.id), [1, 2, 3, 4, 5])
    }

    /// ADR-0017 Decision 3. An absent or unfamiliar `media_type` is **kept**: the filter
    /// removes a known-bad candidate, it does not demand proof that a candidate is good.
    /// Dropping the unknown would make a correct candidate vanish invisibly, which is a
    /// worse failure than the refusal it would be trying to prevent.
    func testExcludingNovelsKeepsCandidatesWithAnAbsentOrUnknownMediaType() throws {
        let candidates = [try malNode(1, "A", mediaType: nil),
                          try malNode(2, "B", mediaType: "web_manga_something_new"),
                          try malNode(3, "C", mediaType: "novel")]

        XCTAssertEqual(MyAnimeListAPI.excludingNovels(candidates).map(\.id), [1, 2])
    }

    /// Why the filter exists, stated through the resolver rather than the filter: with the
    /// novel present the Work is refused, and it is refused by the **ambiguity guard**, not
    /// by the threshold. This is the behaviour ADR-0016 misdiagnosed as a spelling-reach
    /// problem and spent an implementation on.
    ///
    /// Note this test injects `search`, so it runs *around* `excludingNovels` — which is the
    /// cost ADR-0017 Decision 2 accepts openly. That is what it is demonstrating.
    @MainActor func testAProseTwinIsWhatRefusesTheWorkNotTheThreshold() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        // `noBridge` on the refusing resolver, because a Work-level miss now falls through
        // to the bridge and the default one is live (ADR-0019). The refusal this test is
        // about is MAL's, and it must not be able to reach the network to demonstrate it.
        let withNovel = MALEntityResolver(store: store, search: { _ in
            [MALCandidate(malId: 121_496, titles: ["Solo Leveling"]),
             MALCandidate(malId: 119_184, titles: ["Solo Leveling"])]   // the novel
        }, bridgeSearch: MALEntityResolver.noBridge)
        let filtered = MALEntityResolver(store: store, search: { _ in
            [MALCandidate(malId: 121_496, titles: ["Solo Leveling"])]
        }, bridgeSearch: MALEntityResolver.noBridge)

        let refused = try await withNovel.resolve(work(["Solo Leveling"])).malId
        let resolved = try await filtered.resolve(work(["Solo Leveling"])).malId

        XCTAssertNil(refused, "two entries at 1.000 — the guard refuses, correctly")
        XCTAssertEqual(resolved, 121_496)
    }

    // MARK: - MALEntityResolver, the MangaDex bridge (ADR-0016)

    private func mdListing(_ id: String, _ title: String,
                           alts: [String] = [], mal: Int? = nil) -> Manga {
        Manga(id: id, sourceId: "mangadex", title: title, description: "", status: "unknown",
              year: nil, coverURL: nil, malId: mal, altTitles: alts.isEmpty ? nil : alts)
    }

    /// The candidate set that made ADR-0016 Decision 3 necessary, taken from a live
    /// `GET /manga?title=Tower of God`. `Sinui Tap` is the right answer; `Tower of God
    /// (Book Version)` is a variant carrying **no** mal link whose alt titles contain the
    /// canonical English title verbatim, so the two tie at exactly 1.000.
    private var towerOfGodCandidates: [Manga] {
        [mdListing("md-sinui", "Sinui Tap",
                   alts: ["신의 탑", "Kami no Tou", "Tower of God", "Sin-ui Tab"], mal: 122663),
         mdListing("md-book", "Tower of God (Book Version)",
                   alts: ["신의 탑", "Tower of God"]),
         mdListing("md-urek", "Urek Mazino",
                   alts: ["Tower of God: Urek Mazino", "우렉 마지노"], mal: 181485)]
    }

    /// **The regression this decision exists for.** The first assertion is the mutation
    /// proof: matched as one undifferentiated pool — the obvious implementation — the
    /// ambiguity guard rejects the most obvious input the bridge will ever receive, because
    /// the variant ties the real series. Partitioning on "does this entry carry an id at
    /// all" leaves a 0.5 margin and the correct answer.
    @MainActor func testBridgeResolvesTowerOfGodThatAnUnpartitionedPoolCannot() async throws {
        let candidates = towerOfGodCandidates

        let unpartitioned = MALTitleMatcher().bestMatch(
            sourceTitles: ["Tower of God"],
            candidates: candidates.map { (id: $0.id, titles: [$0.title] + ($0.altTitles ?? [])) })
        XCTAssertNil(unpartitioned,
                     "two candidates tie at 1.000, so the guard must reject — this is the bug")

        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store,
                                         search: { _ in [] },              // MAL knows nothing
                                         bridgeSearch: { _ in candidates })

        let resolution = try await resolver.resolve(work(["Tower of God"]))

        XCTAssertEqual(resolution.malId, 122663)
        XCTAssertTrue(resolution.harvestedTitles.contains("Kami no Tou"),
                      "the matched entry's spellings come back for the caller to harvest")
    }

    /// The bridge is a fallback, not a second opinion: a title MAL matches must not cost a
    /// MangaDex request.
    @MainActor func testBridgeIsNotConsultedWhenMALAlreadyMatched() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store,
                                         search: { _ in [MALCandidate(malId: 2, titles: ["Berserk"])] },
                                         bridgeSearch: { _ in
            XCTFail("the bridge must only run after MAL has produced no confident match")
            return []
        })

        let resolution = try await resolver.resolve(work(["Berserk"]))
        XCTAssertEqual(resolution.malId, 2)
    }

    /// Ordering is not an optimization (ADR-0016 Decision 3). The id-less variant scores
    /// *better* here — it is an exact match on the source spelling while the id-bearing
    /// entry matches only via an alternate — and it must still lose, because it cannot
    /// answer the question.
    @MainActor func testBridgeMatchesTheIdBearingPoolEvenWhenAVariantScoresHigher() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, search: { _ in [] }, bridgeSearch: { _ in
            [self.mdListing("md-colour", "One Punch-Man (Fan Colored)", alts: ["One Punch Man"]),
             self.mdListing("md-real", "Wanpanman", alts: ["One Punch-Man"], mal: 44347)]
        })

        let resolution = try await resolver.resolve(work(["One Punch Man"]))
        XCTAssertEqual(resolution.malId, 44347)
    }

    /// **ADR-0019's scope gate, Work level.** A Work MangaDex already serves does not get
    /// bridged through MangaDex: `links.mal` was absent from the entry the app already
    /// fetched, and that absence is an answer. Asserted on the request, not the result —
    /// both configurations return nil, so only `bridgeSearch` going uncalled distinguishes
    /// "declined to ask" from "asked and found nothing".
    @MainActor func testAMangaDexWorkIsNotBridgedThroughMangaDex() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        var bridgeCalls = 0
        func countingResolver() -> MALEntityResolver {
            MALEntityResolver(store: store, search: { _ in [] }, bridgeSearch: { _ in
                bridgeCalls += 1
                return [self.mdListing("md-real", "Sinui Tap", alts: ["Tower of God"], mal: 122663)]
            })
        }

        let mangadexWork = work(["Tower of God"],
                                listings: [ListingKey(sourceId: "mangadex", mangaId: "md-1")])
        let scrapedWork = work(["Tower of God"],
                               listings: [ListingKey(sourceId: "weebcentral", mangaId: "wc-1")])

        let refused = try await countingResolver().resolve(mangadexWork)
        XCTAssertNil(refused.malId)
        XCTAssertEqual(bridgeCalls, 0, "MangaDex is not asked about its own Listing")

        let bridged = try await countingResolver().resolve(scrapedWork)
        XCTAssertEqual(bridged.malId, 122663, "the control: a scraped Work does bridge")
        XCTAssertEqual(bridgeCalls, 1)
    }

    /// The same gate on the Listing-level path, which has no Work to reason about and so
    /// keys on `sourceId` directly. A refusal here is still *recorded* — it is a real
    /// answer, not a transient failure, and must occupy its cache slot.
    @MainActor func testAMangaDexListingIsNotBridgedAndItsRefusalIsRecorded() async {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        var bridgeCalls = 0
        let resolver = MALEntityResolver(store: store, search: { _ in
            [MALCandidate(malId: 9, titles: ["Completely Different Story"])]
        }, bridgeSearch: { _ in
            bridgeCalls += 1
            return [self.mdListing("md-real", "Sinui Tap", alts: ["Tower of God"], mal: 122663)]
        })
        let listing = Manga(id: "md-1", sourceId: "mangadex", title: "Tower of God",
                            description: "", status: "unknown", year: nil, coverURL: nil, malId: nil)

        let id = await resolver.malId(for: listing)

        XCTAssertNil(id)
        XCTAssertEqual(bridgeCalls, 0)
        if case .resolved = store.resolution(sourceId: "mangadex", mangaId: "md-1") {
            XCTFail("a declined bridge must not look like a hit")
        }
        XCTAssertNotNil(store.resolution(sourceId: "mangadex", mangaId: "md-1"),
                        "the refusal is an answer and is cached, not left to be re-asked")
    }

    /// **ADR-0019's Round B cut, pinned in both directions.** When MangaDex identifies the
    /// right series but it carries no mal link, the bridge harvests the spellings and stops
    /// — it does **not** re-search MyAnimeList with them, which is what ADR-0016's Decision
    /// 6 did for 38% of the pass's requests and zero recoveries.
    ///
    /// Inverted from `testBridgeRetriesMALWithHarvestedSpellings…`, deliberately, rather
    /// than deleted alongside it: the harvest and the re-search are separable and only one
    /// of them was cut. Restoring the re-search fails the `searched` assertion; pruning the
    /// harvest along with it fails the `harvestedTitles` one. Both failure modes are live —
    /// the pair reads as one feature until you look.
    @MainActor func testBridgeHarvestsSpellingsWithoutReSearchingMAL() async throws {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        var searched: [String] = []
        let resolver = MALEntityResolver(store: store, search: { title in
            searched.append(title)
            // MAL *would* answer to the native spelling — and is never asked, by design.
            return title == "Kanojo mo Kanojo" ? [MALCandidate(malId: 777, titles: ["Kanojo mo Kanojo"])] : []
        }, bridgeSearch: { _ in
            [self.mdListing("md-x", "Girlfriend Girlfriend", alts: ["Kanojo mo Kanojo"])]
        })

        let resolution = try await resolver.resolve(work(["Girlfriend, Girlfriend"]))

        XCTAssertNil(resolution.malId, "no id: the entry has no mal link and MAL is not re-asked")
        XCTAssertEqual(resolution.harvestedTitles, ["Girlfriend Girlfriend", "Kanojo mo Kanojo"],
                       "the harvest survives the Round B cut — it is what reopens the Work")
        XCTAssertEqual(searched, ["Girlfriend, Girlfriend"],
                       "exactly the first round; a harvested spelling must never be searched")
    }

    /// Same rule as the MAL round: a transient bridge failure throws so the queue records
    /// nothing. An outage must not be remembered as "no catalog has this".
    @MainActor func testBridgeThrowsWhenTheMangaDexSearchFailed() async {
        struct Boom: Error {}
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, search: { _ in [] },
                                         bridgeSearch: { _ in throw Boom() })

        do {
            _ = try await resolver.resolve(work(["Berserk"]))
            XCTFail("a transient bridge failure must not be reported as a miss")
        } catch {}
    }

    /// Decision 7: the Listing-level resolver is bridged too, because the 2026-08-08 device
    /// check established the two resolvers are independent and can disagree.
    @MainActor func testListingLevelResolutionBridgesAndCachesTheHit() async {
        let store = EntityResolutionStore(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let resolver = MALEntityResolver(store: store, search: { _ in
            [MALCandidate(malId: 9, titles: ["Completely Different Story"])]
        }, bridgeSearch: { _ in
            [self.mdListing("md-real", "Sinui Tap", alts: ["Tower of God"], mal: 122663)]
        })
        let listing = Manga(id: "wc-1", sourceId: "weebcentral", title: "Tower of God",
                            description: "", status: "unknown", year: nil, coverURL: nil, malId: nil)

        let bridged = await resolver.malId(for: listing)
        XCTAssertEqual(bridged, 122663)
        XCTAssertEqual(store.resolution(sourceId: "weebcentral", mangaId: "wc-1"),
                       .resolved(malId: 122663),
                       "a Listing-level answer has a Listing to key on, unlike a Work-level one")
    }

    // MARK: - MoreLikeThis.pickMatch

    /// Minimal `Manga` for pure MoreLikeThis tests. `Manga`'s memberwise init is internal,
    /// reachable here via `@testable import MangaCarta`.
    private func mlManga(id: String, title: String, malId: Int?) -> Manga {
        Manga(id: id, sourceId: "mangadex", title: title, description: "",
              status: "unknown", year: nil, coverURL: nil, malId: malId)
    }

    func testPickMatchPrefersExactMalIdOverCloserTitle() {
        // A candidate carrying the target malId wins even though a DIFFERENT candidate
        // has an identical title (which fuzzy matching would otherwise prefer).
        let candidates = [
            mlManga(id: "md-decoy", title: "Berserk", malId: 999),
            mlManga(id: "md-real", title: "Beruseruku", malId: 42),
        ]
        let match = MoreLikeThis.pickMatch(targetMalId: 42, malTitle: "Berserk", candidates: candidates)
        XCTAssertEqual(match?.id, "md-real")
    }

    func testPickMatchFallsBackToFuzzyTitleWhenNoCandidateCarriesId() {
        let candidates = [
            mlManga(id: "md-1", title: "Vinland Saga", malId: nil),
            mlManga(id: "md-2", title: "Totally Other Thing", malId: nil),
        ]
        let match = MoreLikeThis.pickMatch(targetMalId: 777, malTitle: "Vinland Saga", candidates: candidates)
        XCTAssertEqual(match?.id, "md-1")
    }

    func testPickMatchReturnsNilWhenAmbiguousOrBelowThreshold() {
        // Ambiguous: two identical titles, neither carries the id.
        let ambiguous = [
            mlManga(id: "md-1", title: "Hero", malId: nil),
            mlManga(id: "md-2", title: "Hero", malId: nil),
        ]
        XCTAssertNil(MoreLikeThis.pickMatch(targetMalId: 5, malTitle: "Hero", candidates: ambiguous))
        // Below threshold: nothing close enough.
        let unrelated = [mlManga(id: "md-1", title: "Completely Different Story", malId: nil)]
        XCTAssertNil(MoreLikeThis.pickMatch(targetMalId: 5, malTitle: "Berserk", candidates: unrelated))
    }

    func testPickMatchReturnsNilForEmptyCandidates() {
        XCTAssertNil(MoreLikeThis.pickMatch(targetMalId: 5, malTitle: "Berserk", candidates: []))
    }

    // MARK: - MoreLikeThisProvider.topRecommendations (pure)

    /// Minimal `Recommendation` builder — the MAL DTO memberwise inits are internal,
    /// reachable via `@testable import MangaCarta`.
    private func mlRec(malId: Int, weight: Int) -> MyAnimeListMangaDetail.Recommendation {
        MyAnimeListMangaDetail.Recommendation(
            node: MyAnimeListManga(id: malId, title: "T\(malId)",
                                   mainPicture: nil, alternativeTitles: nil, mediaType: nil),
            numRecommendations: weight)
    }

    func testTopRecommendationsSortsByWeightDescendingAndCaps() {
        let recs = [mlRec(malId: 1, weight: 3), mlRec(malId: 2, weight: 10), mlRec(malId: 3, weight: 7)]
        let top = MoreLikeThisProvider.topRecommendations(recs, limit: 2)
        XCTAssertEqual(top.map { $0.node.id }, [2, 3])   // 10, 7 — highest weight first, capped at 2
    }

    func testTopRecommendationsHandlesEmptyAndUndercount() {
        XCTAssertTrue(MoreLikeThisProvider.topRecommendations([], limit: 8).isEmpty)
        let recs = [mlRec(malId: 1, weight: 5)]
        XCTAssertEqual(MoreLikeThisProvider.topRecommendations(recs, limit: 8).map { $0.node.id }, [1])
    }

    // MARK: - chapterPreview (detail-page truncation)

    func testChapterPreviewReturnsNewestFirstCapped() {
        let chapters = [
            Chapter(id: "a", number: "1", title: nil),
            Chapter(id: "b", number: "2", title: nil),
            Chapter(id: "c", number: "3", title: nil),
            Chapter(id: "d", number: "4", title: nil),
            Chapter(id: "e", number: "5", title: nil),
            Chapter(id: "f", number: "6", title: nil),
        ]
        let preview = chapterPreview(chapters, limit: 5)
        XCTAssertEqual(preview.map(\.id), ["f", "e", "d", "c", "b"])
        XCTAssertEqual(preview.count, 5)
    }

    func testChapterPreviewShorterThanLimitReturnsAll() {
        let chapters = [
            Chapter(id: "a", number: "1", title: nil),
            Chapter(id: "b", number: "2", title: nil),
        ]
        let preview = chapterPreview(chapters, limit: 5)
        XCTAssertEqual(preview.map(\.id), ["b", "a"])
    }

    // MARK: - MALCandidateProvider

    @MainActor
    private final class StubSimilar: SimilarTitlesProviding {
        let bySeedId: [String: [Manga]]
        init(_ bySeedId: [String: [Manga]]) { self.bySeedId = bySeedId }
        func recommendations(for manga: Manga, limit: Int) async -> [Manga] {
            Array((bySeedId[manga.id] ?? []).prefix(limit))
        }
    }

    private func mdManga(_ id: String, _ title: String) -> Manga {
        Manga(id: id, sourceId: "mangadex", title: title, description: "",
              status: "unknown", year: nil, coverURL: nil, malId: nil)
    }

    func testMALCandidateProviderScoresByPositionAndSeedWeight() async throws {
        // Seed "s1" (weight 2) recommends x,y ; seed "s2" (weight 2) recommends y,z.
        // y is recommended by both — at position 1 (of 2) for s1 and position 0 for s2 —
        // so its score sums across seeds and overtakes x's single position-0 hit;
        // excluding drops "z".
        //
        // NOTE: the task brief's original version of this test used seed "s2" weight 1,
        // which (given "s1": [x, y] puts x at position 0 and y at position 1) yields a
        // real tie of 2.0/2.0 between x and y — not the 2.0/3.0 split its comment and
        // assertions claimed, and not a deterministic winner for `out.first`. Bumped s2's
        // weight to 2 so the arithmetic (verified by hand below) matches the assertions
        // and the ranking is unambiguous; the implementation is otherwise verbatim.
        let profile = TasteProfile(weights: ["t": 1], tagName: ["t": "Action"],
                                   orderedTagKeys: ["t"], taggedMangaCount: 2,
                                   seeds: [SeedManga(manga: mdManga("s1", "S1"), weight: 2),
                                           SeedManga(manga: mdManga("s2", "S2"), weight: 2)])
        let stub = await StubSimilar(["s1": [mdManga("x", "X"), mdManga("y", "Y")],
                                      "s2": [mdManga("y", "Y"), mdManga("z", "Z")]])
        let provider = MALCandidateProvider(similar: stub)
        let out = try await provider.candidates(for: profile, excluding: ["z"], limit: 10)

        let byId = Dictionary(uniqueKeysWithValues: out.map { ($0.manga.id, $0) })
        XCTAssertNil(byId["z"])                                   // excluded
        // y: s1 pos1 (2 * 1/2 = 1) + s2 pos0 (2 * 1/1 = 2) = 3 ; x: s1 pos0 (2 * 1/1) = 2
        // → y ranks first.
        XCTAssertEqual(out.first?.manga.id, "y")
        XCTAssertEqual(byId["y"]?.score ?? 0, 3.0, accuracy: 0.0001)
        XCTAssertEqual(byId["x"]?.score ?? 0, 2.0, accuracy: 0.0001)
        // Reason names the strongest seed that surfaced it.
        XCTAssertEqual(byId["x"]?.reason, "Because you read S1")
    }

    // MARK: - CompositeCandidateProvider

    private struct StubProvider: CandidateProvider {
        let out: [ScoredManga]
        func candidates(for profile: TasteProfile, excluding: Set<String>, limit: Int) async throws -> [ScoredManga] { out }
    }

    func testCompositeBlendsNormalizesAndBoostsAgreement() async throws {
        let profile = TasteProfile(weights: [:], tagName: [:], orderedTagKeys: [],
                                   taggedMangaCount: 0, seeds: [])
        // Tag pool (raw scores 10, 5); MAL pool (raw scores 100, 50). "y" is in both.
        let tag = StubProvider(out: [ScoredManga(manga: mdManga("x", "X"), score: 10, reason: "More Action"),
                                     ScoredManga(manga: mdManga("y", "Y"), score: 5, reason: "More Action")])
        let mal = StubProvider(out: [ScoredManga(manga: mdManga("y", "Y"), score: 100, reason: "Because you read S"),
                                     ScoredManga(manga: mdManga("z", "Z"), score: 50, reason: "Because you read S")])
        let composite = CompositeCandidateProvider(tag: tag, mal: mal)
        let out = try await composite.candidates(for: profile, excluding: [], limit: 10)
        let byId = Dictionary(uniqueKeysWithValues: out.map { ($0.manga.id, $0) })

        // Normalized: x=1.0,y_tag=0.5 (tag) ; y_mal=1.0,z=0.5 (mal).
        // Agreement is the geometric mean of the two normalized scores, so it tracks the WEAKER
        // signal: y agrees at 0.5/1.0, earning 0.25*sqrt(0.5*1.0) = 0.1768 rather than the flat
        // 0.25 the old rule gave for any overlap at all.
        // final: y = 1.0*0.5 + 0.85*1.0 + 0.1768 = 1.5268 ; x = 1.0 ; z = 0.85*0.5 = 0.425
        XCTAssertEqual(byId["y"]?.score ?? 0, 1.5268, accuracy: 0.0001)
        XCTAssertEqual(byId["x"]?.score ?? 0, 1.00, accuracy: 0.0001)
        XCTAssertEqual(byId["z"]?.score ?? 0, 0.425, accuracy: 0.0001)
        XCTAssertEqual(out.first?.manga.id, "y")                    // strong agreement still leads
        XCTAssertEqual(byId["y"]?.reason, "Because you read S")     // MAL reason preferred when MAL contributed
    }

    func testCompositeDegradesToTagOnlyWhenMALEmpty() async throws {
        let profile = TasteProfile(weights: [:], tagName: [:], orderedTagKeys: [],
                                   taggedMangaCount: 0, seeds: [])
        let tag = StubProvider(out: [ScoredManga(manga: mdManga("x", "X"), score: 10, reason: "More Action"),
                                     ScoredManga(manga: mdManga("y", "Y"), score: 5, reason: "More Action")])
        let mal = StubProvider(out: [])
        let out = try await CompositeCandidateProvider(tag: tag, mal: mal)
            .candidates(for: profile, excluding: [], limit: 10)
        XCTAssertEqual(out.map(\.manga.id), ["x", "y"])            // exactly the tag ranking
    }

    func testCompositeDegradesToMALOnlyWhenTagEmpty() async throws {
        let profile = TasteProfile(weights: [:], tagName: [:], orderedTagKeys: [],
                                   taggedMangaCount: 0, seeds: [])
        let tag = StubProvider(out: [])
        let mal = StubProvider(out: [ScoredManga(manga: mdManga("p", "P"), score: 40, reason: "Because you read S"),
                                     ScoredManga(manga: mdManga("q", "Q"), score: 20, reason: "Because you read S")])
        let out = try await CompositeCandidateProvider(tag: tag, mal: mal)
            .candidates(for: profile, excluding: [], limit: 10)
        XCTAssertEqual(out.map(\.manga.id), ["p", "q"])            // exactly the MAL ranking, no agreement bonus
        XCTAssertEqual(out.first?.reason, "Because you read S")
    }

    // MARK: - ReadingEntry.asManga carries the id (ADR-0018 amendment 1)

    /// Resuming from History rebuilds a `Manga` from the entry, and that `Manga` is what
    /// `HistoryStore.record` reads `malId` off. Dropping it here re-creates the exact boundary
    /// loss ADR-0018 was written to close — one layer further out.
    func testHistoryEntryAsMangaCarriesMalId() {
        let entry = ReadingEntry(id: UUID(), mangaId: "m1", mangaTitle: "Wind Breaker",
                                 coverURL: nil, chapterId: "c1", chapterNumber: "1",
                                 page: 0, pageCount: 10, updatedAt: Date(),
                                 sourceId: "mangadex", fraction: 0, malId: 133_081)
        XCTAssertEqual(entry.asManga.malId, 133_081)
    }

    /// The other half: an entry written before the field existed still rebuilds cleanly, and the
    /// Work it mints stays a resolution question rather than acquiring a wrong answer.
    func testHistoryEntryWithoutMalIdRebuildsWithNone() {
        let entry = ReadingEntry(id: UUID(), mangaId: "m2", mangaTitle: "Legacy",
                                 coverURL: nil, chapterId: "c1", chapterNumber: "1",
                                 page: 0, pageCount: 10, updatedAt: Date(),
                                 sourceId: "mangadex", fraction: 0)
        XCTAssertNil(entry.asManga.malId)
    }

    // MARK: - What a history row says (issue #90)

    /// The row draws "CH·5 · page 3/20" — a stamp abbreviation, two middle dots and a
    /// slash, none of which is a word. The label says it in words instead.
    func testHistoryRowLabelSpeaksTheChapterAndPage() {
        let entry = ReadingEntry(id: UUID(), mangaId: "m", mangaTitle: "Blood and Ink",
                                 coverURL: nil, chapterId: "c", chapterNumber: "5",
                                 page: 2, pageCount: 20, updatedAt: Date())
        XCTAssertEqual(entry.accessibilityLabel(relativeTime: "2 hours ago"),
                       "Blood and Ink, Chapter 5, page 3 of 20, 2 hours ago")
    }

    func testHistoryRowLabelCarriesNoTypography() {
        let entry = sampleEntry(page: 2, pageCount: 20)
        let label = entry.accessibilityLabel(relativeTime: "yesterday")
        XCTAssertFalse(label.contains("\u{00B7}"), label)
        XCTAssertFalse(label.contains("/"), label)
        XCTAssertFalse(label.contains("CH"), label)
    }

    /// The row widens the total to the current page when the count is missing or stale —
    /// the same `max` it draws with, so the sentence never reads "page 4 of 0".
    func testHistoryRowLabelNeverSaysAPageBeyondTheTotal() {
        for pageCount in [0, 1, 5, 40] {
            let entry = sampleEntry(page: 3, pageCount: pageCount)
            let label = entry.accessibilityLabel(relativeTime: "now")
            XCTAssertTrue(label.contains("page 4 of \(max(pageCount, 4))"), label)
        }
    }
    // This legacy integration suite remains a single file to avoid project-file-only churn.
} // swiftlint:disable:this file_length
