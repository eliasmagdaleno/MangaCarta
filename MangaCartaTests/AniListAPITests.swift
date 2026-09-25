//
//  AniListAPITests.swift
//  MangaCartaTests
//
//  Slice 1 of ADR-0007. Fixtures are RECORDED from https://graphql.anilist.co
//  (2026-07-25) using the exact query the client ships, not hand-written — so a
//  schema change shows up as a decode failure here rather than in production.
//

import XCTest
@testable import MangaCarta

final class AniListAPITests: XCTestCase {

    // MARK: - Fixtures

    /// Solo Leveling, recorded live. A manhwa (the coverage gap that motivated
    /// AniList per ADR-0002), FINISHED, with ranked tags. Tag list truncated to 4.
    private static let soloLevelingJSON = Data("""
    {"data":{"Media":{
      "id":105398,
      "idMal":121496,
      "title":{"romaji":"Na Honjaman Level Up","english":"Solo Leveling","native":"나 혼자만 레벨업"},
      "synonyms":["I Level Up Alone","Only I Level Up"],
      "genres":["Action","Adventure","Fantasy"],
      "tags":[{"name":"Dungeon","rank":95},{"name":"Male Protagonist","rank":93},
              {"name":"Super Power","rank":92},{"name":"War","rank":90}],
      "status":"FINISHED",
      "chapters":201
    }}}
    """.utf8)

    /// One Piece, recorded live. Three properties worth having in a fixture:
    /// `romaji` and `native` are byte-identical ("ONE PIECE"), one synonym carries a
    /// trailing space, and it is `RELEASING` with `chapters: null` — the fact
    /// ADR-0004's "sources define the frontier" fallback exists for.
    /// Synonyms and tags truncated; the trailing `""` synonym is the only synthetic
    /// element, added to cover the blank-title case.
    private static let onePieceJSON = Data("""
    {"data":{"Media":{
      "id":30013,
      "idMal":13,
      "title":{"romaji":"ONE PIECE","english":"One Piece","native":"ONE PIECE"},
      "synonyms":["원피스","וואן פיס ",""],
      "genres":["Action","Adventure","Comedy"],
      "tags":[{"name":"Pirates","rank":96},{"name":"Travel","rank":96}],
      "status":"RELEASING",
      "chapters":null
    }}}
    """.utf8)

    private func http(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://graphql.anilist.co")!,
                        statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - Decoding

    func testFetchByMalIdDecodesIdsGenresRankedTagsAndChapterTotal() async throws {
        let api = AniListAPI(transport: { _ in (Self.soloLevelingJSON, self.http(200)) })

        let work = try await api.work(malId: 121496)

        XCTAssertEqual(work.anilistId, 105398)
        XCTAssertEqual(work.malId, 121496)
        // Searchable axis: AniList's 19 genres, which map onto MangaDex tag names.
        XCTAssertEqual(work.genres, ["Action", "Adventure", "Fantasy"])
        // Ranked axis: carries the 0-100 rank, unsearchable, for scoring only.
        XCTAssertEqual(work.tags, [RankedTag(name: "Dungeon", rank: 95),
                                   RankedTag(name: "Male Protagonist", rank: 93),
                                   RankedTag(name: "Super Power", rank: 92),
                                   RankedTag(name: "War", rank: 90)])
        XCTAssertEqual(work.publicationStatus, .finished)
        XCTAssertEqual(work.chapterTotal, 201)
    }

    /// Order is romaji → english → native → synonyms, mirroring
    /// `MyAnimeListManga.allTitles`. Note the romaji title here is "Na Honjaman
    /// Level Up", not "Solo Leveling" — which is exactly why ADR-0007 makes the
    /// Work's displayTitle sticky at mint time instead of taking the provider's.
    func testKnownTitlesCollectsEveryTitleInProviderOrder() async throws {
        let api = AniListAPI(transport: { _ in (Self.soloLevelingJSON, self.http(200)) })

        let work = try await api.work(malId: 121496)

        XCTAssertEqual(work.knownTitles, ["Na Honjaman Level Up",
                                         "Solo Leveling",
                                         "나 혼자만 레벨업",
                                         "I Level Up Alone",
                                         "Only I Level Up"])
    }

    func testKnownTitlesTrimsWhitespaceAndDropsDuplicatesAndBlanks() async throws {
        let api = AniListAPI(transport: { _ in (Self.onePieceJSON, self.http(200)) })

        let work = try await api.work(malId: 13)

        // "ONE PIECE" appears as both romaji and native — kept once, first position
        // wins. The trailing space is trimmed, and the blank synonym is dropped.
        XCTAssertEqual(work.knownTitles, ["ONE PIECE", "One Piece", "원피스", "וואן פיס"])
    }

    // MARK: - Publication status and the chapter total

    func testPublicationStatusMapsEveryAniListStatusString() {
        XCTAssertEqual(PublicationStatus(aniList: "FINISHED"), .finished)
        XCTAssertEqual(PublicationStatus(aniList: "RELEASING"), .releasing)
        XCTAssertEqual(PublicationStatus(aniList: "NOT_YET_RELEASED"), .notYetReleased)
        XCTAssertEqual(PublicationStatus(aniList: "CANCELLED"), .cancelled)
        XCTAssertEqual(PublicationStatus(aniList: "HIATUS"), .hiatus)
        // A status AniList adds later must degrade, not crash.
        XCTAssertEqual(PublicationStatus(aniList: "SOMETHING_NEW"), .unknown)
        XCTAssertEqual(PublicationStatus(aniList: nil), .unknown)
    }

    /// The fact ADR-0004's fallback rests on: an ongoing series has no known total,
    /// so completeness cannot be computed and the sources define the frontier.
    func testReleasingWorkHasNoChapterTotal() async throws {
        let api = AniListAPI(transport: { _ in (Self.onePieceJSON, self.http(200)) })

        let work = try await api.work(malId: 13)

        XCTAssertEqual(work.publicationStatus, .releasing)
        XCTAssertNil(work.chapterTotal)
    }

    // MARK: - Errors

    /// Recorded live: an id AniList doesn't know returns HTTP 404 with a GraphQL
    /// `errors` array AND `data.Media: null`. This must be distinguishable from a
    /// transport failure — "AniList has never heard of this Work" is a terminal
    /// answer the upgrade queue should record, not an error worth retrying.
    func testUnknownIdThrowsNotFound() async throws {
        let json = Data("""
        {"errors":[{"message":"Not Found.","status":404}],"data":{"Media":null}}
        """.utf8)
        let api = AniListAPI(transport: { _ in (json, self.http(404)) })

        do {
            _ = try await api.work(malId: 99_999_999)
            XCTFail("expected notFound")
        } catch let error as AniListError {
            XCTAssertEqual(error, .notFound)
        }
    }

    /// Recorded live: a bad query returns HTTP 400 with `data: null`. Carries the
    /// message through, because this class of failure is a bug in our query
    /// document and a silent nil would hide it.
    func testGraphQLErrorThrowsWithMessage() async throws {
        let json = Data("""
        {"errors":[{"message":"Cannot query field \\"nope\\" on type \\"Media\\".","status":400}],"data":null}
        """.utf8)
        let api = AniListAPI(transport: { _ in (json, self.http(400)) })

        do {
            _ = try await api.work(malId: 13)
            XCTFail("expected graphQL error")
        } catch let error as AniListError {
            XCTAssertEqual(error, .graphQL(message: "Cannot query field \"nope\" on type \"Media\"."))
        }
    }

    /// A 5xx from a proxy is usually an HTML error page, not GraphQL. Without an
    /// explicit status check that surfaces as an opaque `DecodingError`, which reads
    /// like a schema change and sends you debugging the wrong thing.
    func testServerErrorThrowsHTTPStatusRatherThanDecodingError() async throws {
        let api = AniListAPI(transport: { _ in (Data("<html>502 Bad Gateway</html>".utf8), self.http(502)) })

        do {
            _ = try await api.work(malId: 13)
            XCTFail("expected httpStatus")
        } catch let error as AniListError {
            XCTAssertEqual(error, .httpStatus(502))
        }
    }

    // MARK: - Rate limiting

    /// Counts transport invocations across the retry, without data races.
    private actor AttemptCounter {
        private(set) var count = 0
        func record() -> Int { count += 1; return count }
    }

    func testRetriesOnceOnRateLimitThenSucceeds() async throws {
        let attempts = AttemptCounter()
        let api = AniListAPI(transport: { _ in
            if await attempts.record() == 1 {
                return (Data("{}".utf8), self.http(429, headers: ["Retry-After": "0"]))
            }
            return (Self.soloLevelingJSON, self.http(200))
        })

        let work = try await api.work(malId: 121496)

        XCTAssertEqual(work.anilistId, 105398)
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 2, "should have retried exactly once")
    }

    func testGivesUpAsRateLimitedWhenRetryAlsoThrottled() async throws {
        let attempts = AttemptCounter()
        let api = AniListAPI(transport: { _ in
            _ = await attempts.record()
            return (Data("{}".utf8), self.http(429, headers: ["Retry-After": "0"]))
        })

        do {
            _ = try await api.work(malId: 121496)
            XCTFail("expected rateLimited")
        } catch let error as AniListError {
            XCTAssertEqual(error, .rateLimited)
        }
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 2, "one retry, then give up -- never a loop")
    }

    // MARK: - The tag vocabulary (ADR-0011, slice 1)

    /// Recorded from `MediaTagCollection` on 2026-07-28, truncated to five entries that
    /// cover every property the seeding rule reads: an excluded-category tag (`Technical`),
    /// a `Cast-Main Cast` tag, a globally-flagged spoiler, an adult tag, and an ordinary one.
    private static let tagCollectionJSON = Data("""
    {"data":{"MediaTagCollection":[
      {"name":"Dungeon","category":"Theme-Fantasy","isGeneralSpoiler":false,"isAdult":false},
      {"name":"Full Color","category":"Technical","isGeneralSpoiler":false,"isAdult":false},
      {"name":"Male Protagonist","category":"Cast-Main Cast","isGeneralSpoiler":false,"isAdult":false},
      {"name":"Time Manipulation","category":"Theme-Sci Fi","isGeneralSpoiler":true,"isAdult":false},
      {"name":"Tentacles","category":"Sexual Content","isGeneralSpoiler":false,"isAdult":true}
    ]}}
    """.utf8)

    func testTagVocabularyDecodesCategoryAndBothFlags() async throws {
        let api = AniListAPI(transport: { _ in (Self.tagCollectionJSON, self.http(200)) })

        let entries = try await api.tagVocabulary()

        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0], TagVocabularyEntry(name: "Dungeon",
                                                      category: "Theme-Fantasy",
                                                      isGeneralSpoiler: false,
                                                      isAdult: false))
        XCTAssertEqual(entries[1].category, "Technical")
        XCTAssertEqual(entries[2].category, "Cast-Main Cast")
        XCTAssertTrue(entries[3].isGeneralSpoiler)
        XCTAssertTrue(entries[4].isAdult)
    }

    /// The vocabulary shares the media path's error mapping, so a proxy's HTML 502
    /// must not surface as a DecodingError here either.
    func testTagVocabularyServerErrorThrowsHTTPStatus() async throws {
        let api = AniListAPI(transport: { _ in (Data("<html>502</html>".utf8), self.http(502)) })

        do {
            _ = try await api.tagVocabulary()
            XCTFail("expected httpStatus")
        } catch let error as AniListError {
            XCTAssertEqual(error, .httpStatus(502))
        }
    }

    // MARK: - AniListRateLimiter

    /// The budget is 30/min, so requests must be spaced, not merely serialized.
    /// Short interval here to keep the test fast; the shipped default is 2s.
    func testSpacesConsecutiveRequestsByTheMinimumInterval() async throws {
        let limiter = AniListRateLimiter(minimumInterval: 0.25)
        let start = Date()

        _ = try await limiter.run { 1 }
        _ = try await limiter.run { 2 }

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.25, "second request must wait out the interval")
    }

    /// A cold limiter must not make the user wait. The upgrade queue runs in the
    /// background, but a detail-page open jumps the queue and is user-visible.
    func testFirstRequestIsNotDelayed() async throws {
        let limiter = AniListRateLimiter(minimumInterval: 30)
        let start = Date()

        _ = try await limiter.run { 1 }

        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    /// The case that actually matters in production: Home's backfill, a library
    /// refresh, and a detail-page open all reach for the budget at once. Actors are
    /// **reentrant** — suspending at an `await` lets another caller in — so spacing
    /// that only inspects "when did the last one finish" collapses under concurrency
    /// and fires every request at once.
    func testSpacingHoldsWhenCallersArriveConcurrently() async throws {
        let limiter = AniListRateLimiter(minimumInterval: 0.2)
        let start = Date()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try? await limiter.run { 1 } }
            }
        }

        // 4 requests at 0.2s apart ⇒ the last one starts no earlier than 0.6s in.
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.6, "concurrent callers must still be spaced")
    }

    func testPropagatesTheOperationsError() async throws {
        let limiter = AniListRateLimiter(minimumInterval: 0)

        do {
            _ = try await limiter.run { throw AniListError.notFound }
            XCTFail("expected the operation's error to propagate")
        } catch let error as AniListError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testCancellationWhileWaitingStillRunsTheOperation() async throws {
        let limiter = AniListRateLimiter(minimumInterval: 1)
        _ = try await limiter.run { 1 }

        let waiting = Task { try await limiter.run { 2 } }
        waiting.cancel()

        let result = try await waiting.value
        XCTAssertEqual(result, 2)
    }
}
