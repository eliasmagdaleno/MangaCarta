import Foundation

// swiftlint:disable:next blanket_disable_command
// swiftlint:disable line_length large_tuple
import XCTest
@testable import MangaCarta

final class AnalyticsEligibilityTests: XCTestCase {
    func testAdultClassesAreIneligibleRegardlessOfSwitch() {
        let defaults = makeTestDefaults("analytics-eligibility")
        let clean = TestSource()
        let adult = TestSource(declaresAdultTitles: true)
        let nsfw = TestSource(isNSFW: true)
        let vocabulary = TagVocabulary(fetchedAt: Date(), entries: [TagVocabularyEntry(name: "Adult Tag", category: nil, isGeneralSpoiler: false, isAdult: true)])
        let base = manga(rating: "safe")
        let cases: [(Manga, MangaSource?, Work?, TagVocabulary?)] = [
            (manga(rating: "erotica"), clean, nil, vocabulary),
            (manga(rating: "pornographic"), clean, nil, vocabulary),
            (manga(rating: nil), adult, nil, vocabulary),
            (base, nsfw, nil, vocabulary),
            (base, clean, work(tags: [QueryableTag(name: "Adult Tag")]), vocabulary),
            (base, clean, work(genres: [QueryableTag(name: "Hentai")]), vocabulary),
            (base, clean, work(tags: [QueryableTag(name: "Unknown")]), nil),
            (base, nil, nil, vocabulary)
        ]
        for enabled in [false, true] {
            defaults.set(enabled, forKey: AdultContentSetting.key)
            for (manga, source, work, vocabulary) in cases {
                XCTAssertFalse(AnalyticsEligibility.admits(manga: manga, source: source, work: work, vocabulary: vocabulary))
            }
        }
        XCTAssertTrue(AnalyticsEligibility.admits(manga: base, source: clean, work: nil, vocabulary: vocabulary))
    }

    func testWorkWithAnyLocalListingIsIneligible() {
        let remote = manga()
        let localKey = ListingKey(sourceId: LocalSource.sourceID, mangaId: "local-id")
        let work = Work(id: WorkID(), displayTitle: remote.title, knownTitles: [remote.title], externalIds: ExternalIDs(mal: 1, anilist: nil), listings: [ListingKey(remote), localKey])
        XCTAssertFalse(AnalyticsEligibility.admits(manga: remote, source: TestSource(), work: work, vocabulary: TagVocabulary(fetchedAt: Date(), entries: [])))
        let cleanWork = Work(id: WorkID(), displayTitle: remote.title, knownTitles: [remote.title], externalIds: ExternalIDs(mal: 1, anilist: nil), listings: [ListingKey(remote)])
        XCTAssertTrue(AnalyticsEligibility.admits(manga: remote, source: TestSource(), work: cleanWork, vocabulary: TagVocabulary(fetchedAt: Date(), entries: [])))
    }

    func testWorkWithoutCatalogueIDIsDropped() {
        let value = manga(malId: nil)
        XCTAssertNil(AnalyticsEligibility.catalogueIDs(work: nil, manga: value))
        XCTAssertEqual(AnalyticsEligibility.catalogueIDs(work: work(ids: ExternalIDs(mal: 21, anilist: nil)), manga: value), CatalogueIDs(mal: 21, anilist: nil))
        XCTAssertEqual(AnalyticsEligibility.catalogueIDs(work: work(ids: ExternalIDs(mal: nil, anilist: 30013)), manga: value), CatalogueIDs(mal: nil, anilist: 30013))
        XCTAssertEqual(AnalyticsEligibility.catalogueIDs(work: nil, manga: manga(malId: 99)), CatalogueIDs(mal: 99, anilist: nil))
    }

    private func manga(rating: String? = "safe", malId: Int? = 1) -> Manga {
        Manga(id: UUID().uuidString, sourceId: "remote", title: "Title", description: "", status: "", year: nil, coverURL: nil, malId: malId, altTitles: nil, contentRating: rating)
    }

    private func work(ids: ExternalIDs = ExternalIDs(mal: 1, anilist: nil), genres: [QueryableTag] = [], tags: [QueryableTag] = []) -> Work {
        Work(id: WorkID(), displayTitle: "Title", knownTitles: ["Title"], externalIds: ids, listings: [], snapshot: MetadataSnapshot(provider: .mal, fetchedAt: Date(), genres: genres, tags: tags.map { RankedTag(name: $0.name, rank: nil) }, publicationStatus: .finished, chapterTotal: 1))
    }
}

private struct TestSource: MangaSource {
    let id = "remote"
    let name = "Remote"
    let isNSFW: Bool
    let declaresAdultTitles: Bool
    init(isNSFW: Bool = false, declaresAdultTitles: Bool = false) { self.isNSFW = isNSFW; self.declaresAdultTitles = declaresAdultTitles }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { MangaDetail(description: "", authors: [], tags: [], contentRating: nil) }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
