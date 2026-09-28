import XCTest
@testable import MangaCarta

/// ADR-0022 A6: an installed Source's discovery results are filtered by title rating.
@MainActor
final class AdultListingFilterTests: XCTestCase {
    private static let id = "6f1d9c2e-4b7a-4c1e-9e3d-2a8b5c7d1f00:rated"
    private var lifecycle: SourceLifecycleRegistry!

    override func setUp() {
        super.setUp()
        lifecycle = SourceLifecycleRegistry()
    }

    /// Every page carries one title per rating, plus one unrated title.
    private func rated(adult: String, declares: Bool, show: Bool) throws -> ExtensionSource {
        let script = """
        registerEngine("rated", {
          invoke: function (operation, request, context) {
            var items = [
              { id: "safe", title: "S", contentRating: "safe" },
              { id: "sugg", title: "G", contentRating: "suggestive" },
              { id: "ero", title: "E", contentRating: "erotica" },
              { id: "porn", title: "P", contentRating: "pornographic" },
              { id: "none", title: "U" }
            ];
            if (operation === "latestUpdates") {
              items = items.map(function (l) { return { chapterId: "c-" + l.id, listing: l }; });
            }
            return { ok: true, value: { items: items, nextCursor: null, exhausted: true } };
          }
        });
        """
        let declaration = try PortFixtures.declaration("""
        {
          "localId": "rated", "name": "Rated", "engine": "rated", "adult": "\(adult)",
          "capabilities": { "search": true, "popular": true, "newTitles": true, "latestUpdates": true,
                            "tagBrowse": true, "detail": true, "chapters": true, "pages": true },
          "languages": { "mode": "fixed", "values": ["en"] },
          "network": { "httpOrigins": [], "browserOrigins": [], "assetOrigins": [] },
          "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" },
          "configuration": {}
        }
        """, qualifiedId: Self.id)
        try lifecycle.register(declaration)
        return ExtensionSource(declaration: declaration, script: script, isNSFW: false,
                               lifecycle: lifecycle, host: FixtureSourceHost(site: PortFixtures.weebCentralSite),
                               declaresAdultTitles: declares, showAdultContent: { show })
    }

    func testMixedSwitchOffHidesAdultAndUnratedEverywhere() async throws {
        let source = try rated(adult: "mixed", declares: true, show: false)
        let expected = ["safe", "sugg"]
        let search = try await source.search(title: "x", limit: 20, offset: 0).map(\.id)
        let popular = try await source.popular(limit: 20, offset: 0).map(\.id)
        let newTitles = try await source.newTitles(limit: 20, offset: 0).map(\.id)
        let tag = try await source.mangaByTag(tag: "t", limit: 20, offset: 0).map(\.id)
        let latest = try await source.latestUpdates(limitTitles: 20, language: "en", offset: 0).map(\.manga.id)
        XCTAssertEqual(search, expected)
        XCTAssertEqual(popular, expected)
        XCTAssertEqual(newTitles, expected)
        XCTAssertEqual(tag, expected)
        XCTAssertEqual(latest, expected)
    }

    func testNoneSourceSwitchOffKeepsUnratedButHidesAdultLabelledListings() async throws {
        let source = try rated(adult: "none", declares: false, show: false)
        let ids = try await source.popular(limit: 20, offset: 0).map(\.id)
        XCTAssertEqual(ids, ["safe", "sugg", "none"])
    }

    func testSwitchOnReturnsEverything() async throws {
        let source = try rated(adult: "mixed", declares: true, show: true)
        let ids = try await source.popular(limit: 20, offset: 0).map(\.id)
        XCTAssertEqual(ids.count, 5)
    }

    /// Review Focus 2: resolving a saved adult title to MAL must not be filtered.
    func testTheResolutionCopyIsUnfiltered() async throws {
        let source = try rated(adult: "mixed", declares: true, show: false)
        let ids = try await source.unfilteredForResolution().search(title: "x", limit: 20, offset: 0).map(\.id)
        XCTAssertEqual(ids.count, 5)
    }
}
