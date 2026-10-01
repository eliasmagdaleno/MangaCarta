//
//  AdultSourceGatingTests.swift
//  MangaCartaTests
//
//  ADR-0022: the release build registers no adult source, and Settings hides the
//  "show adult sources" control while there is nothing for it to gate. The view
//  reads `SourceRegistry.hasAdultSource` to decide, so that is what is tested here —
//  the release invariant is that it is false for the app's built-in set.
//

import XCTest
@testable import MangaCarta

@MainActor
final class AdultSourceGatingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults("AdultSourceGatingTests")
    }

    /// The invariant ADR-0022 exists to hold. If an adult source is ever merged into
    /// the built-in set, this fails — which is the point, not a nuisance.
    func testBuiltInSourcesServeNoAdultContent() {
        XCTAssertFalse(SourceRegistry(defaults: defaults).hasAdultSource)
    }

    func testAnAdultSourceIsDetected() {
        let registry = SourceRegistry(sources: [GatingSource(id: "safe", isNSFW: false),
                                                GatingSource(id: "adult", isNSFW: true)], defaults: defaults)
        XCTAssertTrue(registry.hasAdultSource)
    }

    func testSourcesThatDeclareThemselvesSafeLeaveNothingToGate() {
        let registry = SourceRegistry(sources: [GatingSource(id: "safe", isNSFW: false)], defaults: defaults)
        XCTAssertFalse(registry.hasAdultSource)
    }
}

private struct GatingSource: MangaSource {
    let id: String
    let isNSFW: Bool
    var name: String { id }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
