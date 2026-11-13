import Foundation
import XCTest
@testable import MangaCarta

@MainActor
final class AnalyticsRecorderTests: XCTestCase {
    func testEachHookAppendsOnceWhenCollecting() {
        let f = fixture()
        f.consent.accept()
        f.library.configureWorkSaved { f.recorder.workSaved(manga: $0, workID: $1) }
        f.library.configureWorkLeftLibrary { f.recorder.workUnsaved(workID: $0) }
        f.library.toggle(f.manga)
        f.library.toggle(f.manga)
        let chapter = Chapter(id: "chapter", number: "12", title: nil)
        f.history.record(manga: f.manga, chapter: chapter, position: ReadingPosition(page: 0), pageCount: 1)
        f.recorder.recommendationFeedback(.notInterested, manga: f.manga)
        f.recorder.recommendationFeedback(.moreLikeThis, manga: f.manga)
        f.recorder.forYouOpened(manga: f.manga, rank: 0, reason: .explore)
        let other = fixtureManga(id: "other", malId: 30)
        _ = f.works.mint(from: other)
        f.recorder.mltOpened(from: f.manga, to: other, toMALID: 30)
        f.recorder.forYouShown(count: 2)
        f.recorder.appActive()
        f.recorder.readerOpened(.rightToLeft)
        f.recorder.searchUsed()
        f.recorder.localImportFinished(fileCount: 2)
        f.recorder.sourceInstalled(.none)
        f.recorder.settingChanged(.notifications, .on(true))

        let names = f.recorder.events.map { $0.event.name }
        for name in ["analytics_enabled", "work_saved", "work_unsaved", "chapter_completed",
                     "rec_not_interested", "rec_more_like_this", "for_you_opened", "mlt_opened",
                     "for_you_shown", "app_active", "reader_opened", "search_used",
                     "local_import_finished", "source_installed", "setting_changed"] {
            XCTAssertEqual(names.filter { $0 == name }.count, 1, name)
        }
    }

    func testEachSavePathRecordsOnce() {
        let f = fixture()
        f.consent.accept()
        f.library.configureWorkSaved { f.recorder.workSaved(manga: $0, workID: $1) }
        f.library.toggle(f.manga)
        let second = fixtureManga(id: "second", malId: 2)
        f.library.toggleCollection(for: second, collectionId: LibraryCollection.readingID)
        let third = fixtureManga(id: "third", malId: 3)
        f.library.setCollections(for: third, collectionIds: [LibraryCollection.readingID])
        let secondListing = fixtureManga(id: "second-listing", malId: 1)
        f.library.toggle(secondListing)
        XCTAssertEqual(f.recorder.events.filter { $0.event.name == "work_saved" }.count, 3)
    }

    func testOpensRecordForTitlesWithoutAWork() {
        let f = fixture()
        f.consent.accept()
        let from = fixtureManga(id: "unminted-from", malId: 21)
        let to = fixtureManga(id: "unminted-to", malId: 30)

        f.recorder.forYouOpened(manga: from, rank: 2, reason: .explore)
        f.recorder.mltOpened(from: from, to: to, toMALID: 30)

        XCTAssertNil(f.works.workId(for: ListingKey(from)))
        XCTAssertNil(f.works.workId(for: ListingKey(to)))
        let events = f.recorder.events.dropFirst()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.compactMap { event -> CatalogueIDs? in
            if case let .forYouOpened(ids, _, _) = event.event { return ids }
            return nil
        }, [CatalogueIDs(mal: 21, anilist: nil)])
        XCTAssertEqual(events.compactMap { event -> (CatalogueIDs, CatalogueIDs)? in
            if case let .mltOpened(from, to) = event.event { return (from, to) }
            return nil
        }.first?.0, CatalogueIDs(mal: 21, anilist: nil))
        XCTAssertEqual(events.compactMap { event -> (CatalogueIDs, CatalogueIDs)? in
            if case let .mltOpened(from, to) = event.event { return (from, to) }
            return nil
        }.first?.1, CatalogueIDs(mal: 30, anilist: nil))

        let noID = fixtureManga(id: "unminted-no-id", malId: nil)
        f.recorder.forYouOpened(manga: noID, rank: 1, reason: .other)
        XCTAssertEqual(f.recorder.events.count, 3)
    }

    func testRelatedOpenIsNotRecorded() {
        let f = fixture()
        f.consent.accept()
        f.recorder.searchUsed()
        XCTAssertFalse(f.recorder.events.contains { $0.event.name == "related_opened" })
    }

    func testNothingRecordedWhenNotCollecting() {
        let f = fixture()
        f.recorder.searchUsed()
        XCTAssertTrue(f.recorder.events.isEmpty)
        f.consent.decline()
        f.recorder.searchUsed()
        XCTAssertTrue(f.recorder.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("analytics/install.json").path))
    }

    func testMarkReadRecordsNothing() {
        let f = fixture()
        f.consent.accept()
        let chapter = Chapter(id: "mark", number: "1", title: nil)
        f.history.markRead(manga: f.manga, chapter: chapter)
        f.history.markRead(manga: f.manga, chapters: [chapter])
        XCTAssertEqual(f.recorder.events.map { $0.event.name }, ["analytics_enabled"])
    }

    func testUnsaveRequiresLedgerEntry() {
        let f = fixture()
        let workID = f.works.mint(from: f.manga)
        f.consent.accept()
        f.recorder.workUnsaved(workID: workID)
        XCTAssertEqual(f.recorder.events.map { $0.event.name }, ["analytics_enabled"])
        f.recorder.workSaved(manga: f.manga, workID: workID)
        XCTAssertTrue(f.recorder.events.contains { $0.event.name == "work_saved" })
        let winner = f.works.mint(from: fixtureManga(id: "winner", malId: 99))
        XCTAssertTrue(f.works.merge(workID, into: winner))
        f.recorder.workUnsaved(workID: workID)
        XCTAssertTrue(f.recorder.events.contains { $0.event.name == "work_unsaved" })
    }

    func testOptOutErasesLocalState() {
        let f = fixture()
        f.consent.accept()
        f.recorder.searchUsed()
        let first = f.recorder.installID
        f.consent.decline()
        XCTAssertNil(f.recorder.installID)
        XCTAssertTrue(f.recorder.events.isEmpty)
        f.consent.accept()
        XCTAssertNotEqual(first, f.recorder.installID)
        f.recorder.resetAnalyticsID()
        XCTAssertNil(f.recorder.installID)
        XCTAssertEqual(f.consent.consent, .granted)
    }

    /// Both sides of a More Like This open pass eligibility: an adult title on either side drops it.
    func testMoreLikeThisDropsAnIneligibleSide() {
        let f = fixture()
        f.consent.accept()
        let clean = fixtureManga(id: "clean", malId: 30)
        let adult = Manga(id: "adult", sourceId: "analytics-test", title: "Fixture", description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: 31, altTitles: nil,
                          contentRating: "erotica")

        f.recorder.mltOpened(from: adult, to: clean, toMALID: 30)
        f.recorder.mltOpened(from: clean, to: adult, toMALID: 31)
        XCTAssertFalse(f.recorder.events.contains { $0.event.name == "mlt_opened" })

        f.recorder.mltOpened(from: clean, to: f.manga, toMALID: 1)
        XCTAssertEqual(f.recorder.events.filter { $0.event.name == "mlt_opened" }.count, 1,
                       "positive control: two clean sides record")
    }

    private struct Fixture {
        let directory: URL
        let consent: AnalyticsConsentStore
        let recorder: AnalyticsRecorder
        let works: WorkStore
        let library: LibraryStore
        let history: HistoryStore
        let manga: Manga
    }

    private func fixture() -> Fixture {
        let directory = makeTestDirectory("analytics-recorder")
        let defaults = makeTestDefaults("analytics-recorder")
        let works = WorkStore(directory: directory)
        let source = TestAnalyticsSource()
        let consent = AnalyticsConsentStore(defaults: defaults)
        let buffer = AnalyticsEventBuffer(directory: directory.appendingPathComponent("analytics"))
        let recorder = AnalyticsRecorder(consent: consent, buffer: buffer, works: works,
                                         source: { source.id == $0 ? source : nil }, defaults: defaults,
                                         appVersion: "test")
        let library = LibraryStore(defaults: defaults, works: works)
        let history = HistoryStore(defaults: defaults, works: works, saveInterval: 0,
                                   chapterCompleted: recorder.chapterCompleted)
        let manga = fixtureManga(id: "manga", malId: 1)
        _ = works.mint(from: manga)
        return Fixture(directory: directory, consent: consent, recorder: recorder,
                       works: works, library: library, history: history, manga: manga)
    }

    private func fixtureManga(id: String, malId: Int?) -> Manga {
        Manga(id: id, sourceId: "analytics-test", title: "Fixture", description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: malId, altTitles: nil, contentRating: "safe")
    }
}

private struct TestAnalyticsSource: MangaSource {
    let id = "analytics-test"
    let name = "Analytics Test"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { MangaDetail(description: "", authors: [], tags: [], contentRating: nil) }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
