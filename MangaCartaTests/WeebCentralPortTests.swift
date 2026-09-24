import XCTest
@testable import MangaCarta

/// The bundled WeebCentral package is exercised through the same ExtensionRuntime path as
/// any installed repository. Captured HTML remains the pinned expectation corpus.
final class WeebCentralPortTests: XCTestCase {
    func testBundledDeclarationUsesTheSharedThemeEngine() throws {
        let declaration = try PortFixtures.declaration(PortFixtures.weebCentralJSON,
                                                       qualifiedId: "repo-test:weebcentral")
        XCTAssertEqual(declaration.engine, PortFixtures.engineName)
        XCTAssertEqual(declaration.name, "WeebCentral")
        XCTAssertEqual(declaration.adult, .none)
    }

    func testPinnedWeebCentralFixturesDriveSearchDetailChaptersPages() async throws {
        let port = try PortFixtures.weebCentral()
        let search = try await port.listings(.search, request: ["query": "berserk",
                                                                 "page": ["cursor": NSNull(), "limit": 8]])
        XCTAssertEqual(search.items.map(\.title).prefix(3), ["Berserk", "Berserk of Gluttony", "The Berserker's Second Playthrough"])

        let detail = try port.validator.validateDetail(try await port.runtime.invoke(
            .detail, request: ["listingId": PortFixtures.weebSeriesID])).value
        XCTAssertFalse(detail.description.isEmpty)
        XCTAssertFalse(detail.tags.isEmpty)

        let chapters = try port.validator.validateChapters(try await port.runtime.invoke(
            .chapters, request: ["listingId": PortFixtures.weebSeriesID])).value
        XCTAssertEqual(chapters.first?.number, "28")

        let pages = try port.validator.validatePages(try await port.runtime.invoke(
            .pages, request: ["chapterId": PortFixtures.weebChapterID, "quality": "original"])).value
        XCTAssertFalse(pages.isEmpty)
    }

    func testBundledEngineRequiresNestedPagingRequest() async throws {
        let port = try PortFixtures.weebCentral()
        let first = try await port.runtime.invoke(.search, request: [
            "query": "berserk", "page": ["cursor": NSNull(), "limit": 2]
        ]) as? [String: Any]
        let firstItems = try XCTUnwrap(first?["items"] as? [[String: Any]])
        XCTAssertFalse(firstItems.isEmpty)
        let nextCursor = try XCTUnwrap(first?["nextCursor"] as? String)

        let second = try await port.runtime.invoke(.search, request: [
            "query": "berserk", "page": ["cursor": nextCursor, "limit": 2]
        ]) as? [String: Any]
        let secondItems = try XCTUnwrap(second?["items"] as? [[String: Any]])
        XCTAssertFalse(secondItems.isEmpty)
        XCTAssertTrue(port.browser.requestedURLs.contains {
            $0.query?.contains("offset=2") == true
        }, "the returned cursor must drive the next nested page request")

        do {
            _ = try await port.runtime.invoke(.search, request: [
                "query": "berserk", "cursor": NSNull(), "limit": 2
            ])
            XCTFail("the shipped engine must not accept the pre-186 flat shape")
        } catch let error as ExtensionInvocationError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
    }
}
