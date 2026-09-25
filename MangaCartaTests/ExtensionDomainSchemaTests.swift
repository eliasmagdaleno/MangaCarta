//
//  ExtensionDomainSchemaTests.swift
//  MangaCartaTests
//
//  Host API v1 domain-wire conformance. The Host API design owns the bytes;
//  ADR-0003 Amendment 2 owns why validation belongs to the host.
//

import Foundation
import XCTest
@testable import MangaCarta

final class ExtensionDomainSchemaTests: XCTestCase {
    private var validator: ExtensionDomainValidator {
        let calendar = Calendar(identifier: .gregorian)
        let now = DateComponents(calendar: calendar, timeZone: TimeZone(secondsFromGMT: 0),
                                 year: 2026, month: 9, day: 3).date!
        return ExtensionDomainValidator(
            currentDate: now,
            calendar: calendar,
            assetOrigins: ["https://cdn.example.test"],
            hostAPIVersion: HostAPIVersion(major: 1, minor: 2)
        )
    }

    // MARK: - Listing

    func testInvalidMALIdIsDroppedWithWarning() throws {
        let result = try validator.validateListing(["id": "manga-1", "title": "A Title",
                                                    "externalIds": ["mal": "0"]])
        XCTAssertNil(result.value.externalIds["mal"])
        XCTAssertEqual(result.warnings.map(\.fieldPath), ["listing.externalIds.mal"])
        XCTAssertEqual(result.warnings.map(\.itemIndex), [nil])
    }

    func testMALIdsMustBePositiveDecimalIntegers() throws {
        let invalidValues: [String] = ["0", "-1", "12a", " 12", String(repeating: "9", count: 100)]
        for value in invalidValues {
            let result = try validator.validateListing(["id": "manga-1", "title": "A Title",
                                                         "externalIds": ["mal": value]])
            XCTAssertNil(result.value.externalIds["mal"], "unexpectedly kept \(value)")
            XCTAssertEqual(result.warnings.map(\.fieldPath), ["listing.externalIds.mal"])
        }

        let valid = try validator.validateListing(["id": "manga-1", "title": "A Title",
                                                    "externalIds": ["mal": "123"]])
        XCTAssertEqual(valid.value.externalIds["mal"], "123")
        XCTAssertTrue(valid.warnings.isEmpty)
    }

    func testSparseListingPreservesWireMetadataAndAdapterUsesInvokedSource() throws {
        let result = try validator.validateListingPage(exhaustedPage(items: [[
            "id": "  manga-1  ",
            "title": "  A Title  ",
            "sourceId": "another-repository:hostile-source",
            "externalIds": ["mal": "123", "future-catalog": "opaque-value"],
            "alternateTitles": ["", "Other", "Other", "  ", "Exact Case", "exact case"]
        ]]))

        let listing = try XCTUnwrap(result.items.first)
        XCTAssertEqual(listing.id, "manga-1")
        XCTAssertEqual(listing.title, "A Title")
        XCTAssertEqual(listing.externalIds["future-catalog"], "opaque-value")
        XCTAssertEqual(listing.alternateTitles, ["Other", "Exact Case", "exact case"])
        XCTAssertNil(listing.contentRating, "Missing rating is unknown, never safe")

        let manga = listing.toManga(sourceID: "invoked-repository:actual-source")
        XCTAssertEqual(manga.sourceId, "invoked-repository:actual-source")
        XCTAssertEqual(manga.description, "")
        XCTAssertEqual(manga.status, "unknown")
        XCTAssertEqual(manga.malId, 123)
        XCTAssertEqual(manga.altTitles, ["Other", "Exact Case", "exact case"])
    }

    func testListingCollectionDropsMissingIdentityAndMaySucceedEmpty() throws {
        let result = try validator.validateListingPage(exhaustedPage(items: [
            ["title": "No id"],
            ["id": "no-title"],
            ["id": "blank-title", "title": "   "]
        ]))

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.warnings.map(\.code), [
            .missingRequiredField, .missingRequiredField, .missingRequiredField
        ])
        XCTAssertEqual(result.warnings.map(\.itemIndex), [0, 1, 2])
    }

    func testListingCollectionRejectsStructurallyWrongItem() {
        assertInvalidResponse {
            _ = try validator.validateListingPage(exhaustedPage(items: ["not-an-object"]))
        }
        assertInvalidResponse {
            _ = try validator.validateListingPage(exhaustedPage(items: [[
                "id": NSNull(), "title": "Null is a wrong type, not an omission"
            ]]))
        }
    }

    func testListingOptionalFieldsHonorEnumsBoundsAndExactTypes() throws {
        let accepted = try validator.validateListingPage(exhaustedPage(items: [[
            "id": "manga-1",
            "title": "A Title",
            "status": "completed",
            "year": 2027,
            "contentRating": "suggestive"
        ]]))
        XCTAssertEqual(accepted.items.first?.year, 2027)
        XCTAssertEqual(accepted.items.first?.toManga(sourceID: "source").contentRating,
                       "suggestive")

        let invalidFields: [(String, Any)] = [
            ("status", "finished"),
            ("year", 2028),
            ("year", 2026.5),
            ("contentRating", "unclassified"),
            ("contentRating", NSNull()),
            ("externalIds", ["mal": 123]),
            ("alternateTitles", ["Valid", 7])
        ]
        for (field, value) in invalidFields {
            assertInvalidResponse(field) {
                _ = try validator.validateListingPage(exhaustedPage(items: [[
                    "id": "manga-1", "title": "A Title", field: value
                ]]))
            }
        }
    }

    func testMalformedCoverWarnsAndDropsTheField() throws {
        let malformed = try validator.validateListingPage(exhaustedPage(items: [[
            "id": "manga-1", "title": "A Title", "coverURL": "not an absolute URL"
        ]]))
        XCTAssertNil(malformed.items.first?.coverURL)
        XCTAssertEqual(malformed.warnings.map(\.code), [.malformedURL])
    }

    func testWildcardAssetOriginMatchesExactlyOneLabel() throws {
        let wildcard = ExtensionDomainValidator(assetOrigins: ["https://*.mangadex.network"])
        let accepted = try wildcard.validateListing(["id": "manga-1", "title": "Title",
                                                     "coverURL": "https://a.mangadex.network/cover.jpg"])
        XCTAssertNotNil(accepted.value.coverURL)
        for host in ["mangadex.network", "a.b.mangadex.network", "evilmangadex.network"] {
            let result = try wildcard.validateListing(["id": "manga-1", "title": "Title",
                                                       "coverURL": "https://\(host)/cover.jpg"])
            XCTAssertNil(result.value.coverURL, host)
            XCTAssertEqual(result.warnings.map(\.code), [.policyInvalidURL], host)
        }
    }

    /// ADR-0024: a cover is cosmetic on both readings, so a policy-invalid cover drops the
    /// field rather than erasing the feed it arrived in. The rejected URL is never loaded
    /// either way, so no boundary weakens.
    func testPolicyInvalidCoverWarnsAndKeepsTheItem() throws {
        let policyInvalidCovers = [
            "http://cdn.example.test/cover.jpg",
            "https://evil.example/cover.jpg",
            "data:text/plain,not-an-image",
            "file:///tmp/cover.jpg",
            "blob:https://cdn.example.test/opaque",
            "javascript:alert(1)",
            "custom://cdn.example.test/cover.jpg"
        ]
        for cover in policyInvalidCovers {
            let result = try validator.validateListingPage(exhaustedPage(items: [[
                "id": "manga-1", "title": "A Title", "coverURL": cover
            ]]))
            XCTAssertEqual(result.items.count, 1, cover)
            XCTAssertNil(result.items.first?.coverURL, cover)
            XCTAssertEqual(result.warnings.map(\.code), [.policyInvalidURL], cover)
        }
    }

    /// The relaxation above is scoped to the optional cover field alone. One bad cover must
    /// not cost the feed, but one bad page URL still costs the operation.
    func testPolicyInvalidPageURLStillRejectsTheOperation() {
        for url in ["http://cdn.example.test/page-001.jpg", "javascript:alert(1)"] {
            assertInvalidResponse(url) {
                _ = try validator.validatePages([["url": url]])
            }
        }
    }

    // MARK: - Update

    func testSparseUpdateAdaptsAndInvalidUpdatesDropIndividually() throws {
        let result = try validator.validateUpdatePage(exhaustedPage(items: [
            ["chapterId": " chapter-42 ", "listing": [
                "id": "manga-1", "title": "Title", "sourceId": "hostile-source"
            ]],
            ["listing": ["id": "manga-2", "title": "Missing chapter"]],
            ["chapterId": "chapter-44", "listing": "wrong-shape"]
        ]))

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.warnings.map(\.itemIndex), [1, 2])
        let update = try XCTUnwrap(result.items.first?.toMangaUpdate(sourceID: "invoked-source"))
        XCTAssertEqual(update.chapterId, "chapter-42")
        XCTAssertEqual(update.manga.sourceId, "invoked-source")
    }

    // MARK: - Detail

    func testSparseDetailDefaultsAndInvalidTagsDropWithWarnings() throws {
        let result = try validator.validateDetail([
            "tags": [
                ["name": " Action "],
                ["id": "blank", "name": "   ", "group": "genre"],
                "wrong-shape"
            ]
        ])

        XCTAssertEqual(result.value.description, "")
        XCTAssertEqual(result.value.authors, [])
        XCTAssertNil(result.value.contentRating)
        XCTAssertEqual(result.value.tags, [ExtensionTag(id: nil, name: "Action", group: nil)])
        XCTAssertEqual(result.warnings.map(\.itemIndex), [1, 2])

        let adapted = result.value.toMangaDetail()
        XCTAssertEqual(adapted.description, "")
        XCTAssertEqual(adapted.tags, [Tag(id: nil, name: "Action", group: nil)])
    }

    func testDetailRejectsNonObjectAndInvalidNonTagFields() {
        assertInvalidResponse {
            _ = try validator.validateDetail(["an", "array"])
        }
        assertInvalidResponse {
            _ = try validator.validateDetail(["authors": ["Author", 7]])
        }
        assertInvalidResponse {
            _ = try validator.validateDetail(["contentRating": "unknown"])
        }
        assertInvalidResponse {
            _ = try validator.validateDetail(["description": NSNull()])
        }
    }

    // MARK: - Chapter

    func testSparseChapterDefaultsAndInvalidPublishedAtOnlyDropsField() throws {
        let result = try validator.validateChapters(["items": [
            ["id": " chapter-1 "],
            ["id": "chapter-2", "number": "2", "publishedAt": "not-a-date"],
            ["id": "chapter-3", "number": "3", "publishedAt": "2026-09-01t12:34:56z"],
            ["id": "chapter-4", "number": "4", "publishedAt": NSNull()]
        ]])

        XCTAssertEqual(result.value.map(\.id), [
            "chapter-1", "chapter-2", "chapter-3", "chapter-4"
        ])
        XCTAssertEqual(result.value.first?.toChapter().number, "?")
        XCTAssertNil(result.value[1].publishedAt)
        XCTAssertNotNil(result.value[2].publishedAt)
        XCTAssertNil(result.value[3].publishedAt)
        XCTAssertEqual(result.warnings.map(\.code), [.invalidField, .invalidField])
        XCTAssertEqual(result.warnings.first?.fieldPath, "items[1].publishedAt")
    }

    func testChapterGroupsAreTrimmedAndOptional() throws {
        let result = try validator.validateChapters(["items": [
            ["id": "with-groups", "groups": ["  Alpha  ", "Beta"]],
            ["id": "without-groups"]
        ]])

        XCTAssertEqual(result.value[0].groups, ["Alpha", "Beta"])
        XCTAssertEqual(result.value[0].toChapter().groups, ["Alpha", "Beta"])
        XCTAssertNil(result.value[1].groups)
        XCTAssertTrue(result.warnings.isEmpty)

        let tenGroups = try validator.validateChapters(["items": [[
            "id": "ten-groups", "groups": Array(repeating: "group", count: 10)
        ]]])
        XCTAssertEqual(tenGroups.value.first?.groups?.count, 10)
    }

    func testInvalidChapterGroupsAreIgnoredWithWarnings() throws {
        let invalidValues: [Any] = [
            "not-an-array",
            ["valid", 7],
            ["   "],
            Array(repeating: "group", count: 11),
            [String(repeating: "x", count: 201)]
        ]

        for value in invalidValues {
            let result = try validator.validateChapters(["items": [[
                "id": "chapter", "groups": value
            ]]])
            XCTAssertEqual(result.value.map(\.id), ["chapter"], "chapter should survive \(value)")
            XCTAssertNil(result.value.first?.groups, "unexpectedly accepted \(value)")
            XCTAssertEqual(result.warnings.count, 1)
            XCTAssertTrue(result.warnings[0].fieldPath.hasPrefix("items[0].groups"))
        }
    }

    func testChaptersDropInvalidItemsWithoutReorderingOrMerging() throws {
        let result = try validator.validateChapters(["items": [
            ["id": "second", "number": "2", "publishedAt": "2026-09-01T12:34:56Z"],
            ["number": "missing-id"],
            ["id": "first", "number": "1", "publishedAt": "2026-09-01T12:34:56.123Z"],
            ["id": "second", "number": "2b", "publishedAt": "2026-09-01T05:34:56-07:00"],
            ["id": "wrong-number", "number": 3]
        ]])

        XCTAssertEqual(result.value.map(\.id), ["second", "first", "second"])
        XCTAssertEqual(result.value.map(\.number), ["2", "1", "2b"])
        XCTAssertEqual(result.warnings.map(\.itemIndex), [1, 4])
        XCTAssertNotNil(result.value[0].toChapter().date)
        XCTAssertNotNil(result.value[1].toChapter().date)
        XCTAssertNotNil(result.value[2].toChapter().date)
    }

    // MARK: - Page image

    func testPageListsAcceptValidSparseAndEmptyValues() throws {
        let populated = try validator.validatePages(["items": [[
            "url": "https://cdn.example.test/page-001.jpg"
        ]]])
        XCTAssertEqual(populated.value.map(\.url.absoluteString), [
            "https://cdn.example.test/page-001.jpg"
        ])
        XCTAssertTrue(populated.warnings.isEmpty)

        let empty = try validator.validatePages(["items": []])
        XCTAssertTrue(empty.value.isEmpty, "Empty content remains empty, not fabricated completion")
    }

    func testAnyInvalidPageRejectsTheWholeResult() {
        let invalidPages: [Any] = [
            ["url": "https://cdn.example.test/one.jpg", "headers": ["Referer": "secret"]],
            ["url": "http://cdn.example.test/two.jpg"],
            ["url": "https://evil.example/three.jpg"],
            ["headers": [:]],
            ["url": "https://cdn.example.test/null-headers.jpg", "headers": NSNull()],
            "not-an-object"
        ]

        for page in invalidPages {
            assertInvalidResponse {
                _ = try validator.validatePages(["items": [
                    ["url": "https://cdn.example.test/good.jpg"], page
                ]])
            }
        }
    }

    // MARK: - Pagination and JSON envelope values

    func testPaginationRequiresCursorXorExhaustion() throws {
        let withCursor = try validator.validateListingPage([
            "items": [], "nextCursor": "opaque", "exhausted": false
        ])
        XCTAssertEqual(withCursor.nextCursor, "opaque")
        XCTAssertFalse(withCursor.exhausted)

        let exhausted = try validator.validateListingPage(exhaustedPage(items: []))
        XCTAssertNil(exhausted.nextCursor)
        XCTAssertTrue(exhausted.exhausted)

        let invalid: [[String: Any]] = [
            ["items": [], "nextCursor": "opaque", "exhausted": true],
            ["items": [], "nextCursor": NSNull(), "exhausted": false],
            ["items": [], "exhausted": false],
            ["items": [], "nextCursor": 7, "exhausted": false]
        ]
        for page in invalid {
            assertInvalidResponse {
                _ = try validator.validateListingPage(page)
            }
        }
    }

    func testCursorUsesUTF8ByteLimitAndShortPageDoesNotInferExhaustion() throws {
        let maximumCursor = String(repeating: "é", count: 1_024)
        let accepted = try validator.validateListingPage([
            "items": [["id": "only", "title": "Short page"]],
            "nextCursor": maximumCursor,
            "exhausted": false
        ])
        XCTAssertEqual(accepted.nextCursor, maximumCursor)
        XCTAssertFalse(accepted.exhausted)

        assertInvalidResponse {
            _ = try validator.validateListingPage([
                "items": [], "nextCursor": maximumCursor + "x", "exhausted": false
            ])
        }
    }

    func testJSONOnlyPreflightRejectsNonJSONValuesEverywhere() {
        let cyclic = NSMutableDictionary()
        cyclic["self"] = cyclic
        let invalidValues: [Any] = [
            Date(),
            Data([0x01]),
            Double.infinity,
            Double.nan,
            Int64(9_007_199_254_740_992),
            { 42 },
            cyclic
        ]

        for value in invalidValues {
            assertInvalidResponse {
                _ = try validator.validateDetail(["unknownFutureField": value])
            }
        }
    }

    // MARK: - Helpers

    private func exhaustedPage(items: [Any]) -> [String: Any] {
        ["items": items, "nextCursor": NSNull(), "exhausted": true]
    }

    private func assertInvalidResponse(
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), context, file: file, line: line) { error in
            guard let schemaError = error as? ExtensionSchemaError else {
                XCTFail("Expected ExtensionSchemaError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(schemaError.code, .invalidResponse, file: file, line: line)
        }
    }
}
