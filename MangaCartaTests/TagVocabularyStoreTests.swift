//
//  TagVocabularyStoreTests.swift
//  MangaCartaTests
//
//  Slice 1 of ADR-0011: the cached AniList tag vocabulary. Category is a property of a
//  *tag name*, globally — never a fact about a Work — so it lives here and is looked up
//  at read time. Each test gets its own temp directory; the real `Caches/` file is never
//  touched.
//

import XCTest
@testable import MangaCarta

final class TagVocabularyStoreTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private static let entries = [
        TagVocabularyEntry(name: "Dungeon", category: "Theme-Fantasy",
                           isGeneralSpoiler: false, isAdult: false),
        TagVocabularyEntry(name: "Full Color", category: "Technical",
                           isGeneralSpoiler: false, isAdult: false),
        TagVocabularyEntry(name: "Male Protagonist", category: "Cast-Main Cast",
                           isGeneralSpoiler: false, isAdult: false),
        TagVocabularyEntry(name: "Time Manipulation", category: "Theme-Sci Fi",
                           isGeneralSpoiler: true, isAdult: false),
        TagVocabularyEntry(name: "Tentacles", category: "Sexual Content",
                           isGeneralSpoiler: false, isAdult: true)
    ]

    private func makeDirectory() -> URL {
        makeTestDirectory("TagVocabularyStoreTests")
            .appendingPathComponent("TagVocabularyStoreTests-\(UUID().uuidString)")
    }

    /// Counts fetches without data races, and can be told to fail.
    private actor Fetcher {
        private(set) var count = 0
        private let result: [TagVocabularyEntry]?
        init(returning result: [TagVocabularyEntry]?) { self.result = result }

        func fetch() async throws -> [TagVocabularyEntry] {
            count += 1
            guard let result else { throw AniListError.httpStatus(502) }
            return result
        }
    }

    // MARK: - The vocabulary value

    /// The three questions seeding asks of a tag name. Excluding `Technical` and
    /// `Cast-Main Cast` is the whole reason this cache exists.
    func testVocabularyAnswersCategoryAndBothFlagsByName() {
        let vocabulary = TagVocabulary(fetchedAt: noon, entries: Self.entries)

        XCTAssertEqual(vocabulary.category(of: "Full Color"), "Technical")
        XCTAssertEqual(vocabulary.category(of: "Male Protagonist"), "Cast-Main Cast")
        XCTAssertTrue(vocabulary.isGeneralSpoiler("Time Manipulation"))
        XCTAssertFalse(vocabulary.isGeneralSpoiler("Dungeon"))
        XCTAssertTrue(vocabulary.isAdult("Tentacles"))
        XCTAssertFalse(vocabulary.isAdult("Dungeon"))
    }

    /// A tag the vocabulary has never heard of — AniList adding one, or a MangaDex name
    /// landing on the ranked axis with `rank == nil`. Its category is unknown, and the
    /// flags default to the permissive answer so an unknown tag is seedable and printable
    /// rather than silently dropped.
    func testAnUnknownTagHasNoCategoryAndIsNotFlagged() {
        let vocabulary = TagVocabulary(fetchedAt: noon, entries: Self.entries)

        XCTAssertNil(vocabulary.category(of: "Cosmic Horror"))
        XCTAssertFalse(vocabulary.isGeneralSpoiler("Cosmic Horror"))
        XCTAssertFalse(vocabulary.isAdult("Cosmic Horror"))
    }

    func testVocabularyIsFreshUntilTheThirtyDayTTL() {
        let vocabulary = TagVocabulary(fetchedAt: noon, entries: Self.entries)

        XCTAssertTrue(vocabulary.isFresh(now: noon.addingTimeInterval(TagVocabulary.ttl - 1)))
        XCTAssertFalse(vocabulary.isFresh(now: noon.addingTimeInterval(TagVocabulary.ttl)))
    }

    // MARK: - The store

    func testFirstCallFetchesAndSubsequentCallsUseTheCache() async throws {
        let fetcher = Fetcher(returning: Self.entries)
        let store = TagVocabularyStore(directory: makeDirectory(),
                                       fetch: { try await fetcher.fetch() })

        let first = await store.vocabulary(now: noon)
        let second = await store.vocabulary(now: noon)

        XCTAssertEqual(first?.entries, Self.entries)
        XCTAssertEqual(second?.entries, Self.entries)
        let count = await fetcher.count
        XCTAssertEqual(count, 1, "one 27 KB request buys thirty days")
    }

    /// `Caches/` placement rests on the vocabulary surviving a relaunch — otherwise every
    /// cold launch spends a request before the rail can run at all.
    func testTheVocabularyPersistsAcrossInstances() async throws {
        let directory = makeDirectory()
        let first = Fetcher(returning: Self.entries)
        _ = await TagVocabularyStore(directory: directory,
                                     fetch: { try await first.fetch() }).vocabulary(now: noon)

        let second = Fetcher(returning: Self.entries)
        let reloaded = await TagVocabularyStore(directory: directory,
                                                fetch: { try await second.fetch() })
            .vocabulary(now: noon)

        XCTAssertEqual(reloaded?.entries, Self.entries)
        let count = await second.count
        XCTAssertEqual(count, 0, "a persisted vocabulary must not cost a request on relaunch")
    }

    func testAStaleVocabularyIsRefetched() async throws {
        let directory = makeDirectory()
        let first = Fetcher(returning: Self.entries)
        _ = await TagVocabularyStore(directory: directory,
                                     fetch: { try await first.fetch() }).vocabulary(now: noon)

        let refreshed = [TagVocabularyEntry(name: "Necromancy", category: "Theme-Fantasy",
                                            isGeneralSpoiler: false, isAdult: false)]
        let second = Fetcher(returning: refreshed)
        let store = TagVocabularyStore(directory: directory, fetch: { try await second.fetch() })

        let vocabulary = await store.vocabulary(now: noon.addingTimeInterval(TagVocabulary.ttl))

        XCTAssertEqual(vocabulary?.entries, refreshed)
        let count = await second.count
        XCTAssertEqual(count, 1)
    }

    /// The skip-rather-than-degrade rule. Unfiltered seeding is specifically the
    /// "recommend me webtoons and Male Protagonist" failure, so a missing vocabulary must
    /// cost the feature rather than corrupt it.
    func testAFailedFetchWithNoCacheReturnsNil() async throws {
        let fetcher = Fetcher(returning: nil)
        let store = TagVocabularyStore(directory: makeDirectory(),
                                       fetch: { try await fetcher.fetch() })

        let vocabulary = await store.vocabulary(now: noon)

        XCTAssertNil(vocabulary)
    }

    /// A stale vocabulary beats none: categories move on the order of years (ADR-0011
    /// measured the counts unchanged across three days), while an AniList outage would
    /// otherwise take the rail down with it.
    func testAFailedRefreshFallsBackToTheStaleVocabulary() async throws {
        let directory = makeDirectory()
        let first = Fetcher(returning: Self.entries)
        _ = await TagVocabularyStore(directory: directory,
                                     fetch: { try await first.fetch() }).vocabulary(now: noon)

        let failing = Fetcher(returning: nil)
        let store = TagVocabularyStore(directory: directory, fetch: { try await failing.fetch() })

        let vocabulary = await store.vocabulary(now: noon.addingTimeInterval(TagVocabulary.ttl))

        XCTAssertEqual(vocabulary?.entries, Self.entries)
    }

    /// A failed fetch must not be cached as an empty vocabulary — that would look like
    /// "AniList has no tags" for the next thirty days.
    func testAFailedFetchIsRetriedOnTheNextCall() async throws {
        let fetcher = Fetcher(returning: nil)
        let store = TagVocabularyStore(directory: makeDirectory(),
                                       fetch: { try await fetcher.fetch() })

        _ = await store.vocabulary(now: noon)
        _ = await store.vocabulary(now: noon)

        let count = await fetcher.count
        XCTAssertEqual(count, 2)
    }
}
