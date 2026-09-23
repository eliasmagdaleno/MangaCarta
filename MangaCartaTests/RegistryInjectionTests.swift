//
//  RegistryInjectionTests.swift
//  MangaCartaTests
//
//  One claim, three view models: **a view model built against an injected registry never
//  resolves through `SourceRegistry.shared`.**
//
//  This shipped as a real bug. The detail page resolved its source through the singleton
//  while the app had been built with an injected registry, so lookups missed, display names
//  fell back to raw ids, and the page tried to load chapters from a source that does not
//  serve that manga. Nothing caught it, because every test that injected a source passed one
//  explicitly and so never exercised the fallback.
//
//  Every source id below is deliberately absent from the built-in set. A view model that
//  reaches the singleton cannot answer with one of these — it answers with MangaDex — so a
//  regression fails these assertions rather than merely resolving differently.
//

import XCTest
@testable import MangaCarta

@MainActor
final class RegistryInjectionTests: XCTestCase {

    private static let injectedA = "injected-a"
    private static let injectedB = "injected-b"

    /// `SourceRegistry.activeSourceID` persists to `UserDefaults.standard`, and these tests
    /// run in the app host — so without this they would leave the simulator fixture pointed
    /// at a source that does not exist.
    private var savedActiveSourceID: Any?

    override func setUp() {
        super.setUp()
        savedActiveSourceID = UserDefaults.standard.object(forKey: "source.activeID")
    }

    override func tearDown() {
        if let savedActiveSourceID {
            UserDefaults.standard.set(savedActiveSourceID, forKey: "source.activeID")
        } else {
            UserDefaults.standard.removeObject(forKey: "source.activeID")
        }
        super.tearDown()
    }

    /// A registry holding two sources neither of which the app compiles in. The active one
    /// is put first: a fresh registry falls back to `sources[0]` unless the persisted id is
    /// one it holds, which no real device's is.
    private func injectedRegistry(active: String = injectedA) -> SourceRegistry {
        let sources = [
            InjectedStubSource(id: Self.injectedA, chapterNumbers: ["1"]),
            InjectedStubSource(id: Self.injectedB, chapterNumbers: ["1", "2", "3"])
        ]
        UserDefaults.standard.removeObject(forKey: "source.activeID")
        return SourceRegistry(sources: active == Self.injectedA ? sources : sources.reversed())
    }

    /// The singleton must be *reachable* for these tests to prove anything: if it happened
    /// to hold the same sources, resolving through it would look identical.
    func testTheSharedRegistryDoesNotKnowTheseSources() {
        XCTAssertNil(SourceRegistry.shared.source(id: Self.injectedA))
        XCTAssertNil(SourceRegistry.shared.source(id: Self.injectedB))
    }

    // MARK: - Home

    func testHomeFollowsTheInjectedRegistrysActiveSource() {
        let registry = injectedRegistry(active: Self.injectedB)
        let vm = HomeViewModel(registry: registry)

        XCTAssertEqual(vm.source?.id, Self.injectedB)
    }

    /// Read at access time, not captured at construction — a Settings switch has to
    /// re-source Home without recreating the view model.
    func testHomeFollowsTheInjectedRegistryAfterASourceSwitch() {
        let registry = injectedRegistry(active: Self.injectedA)
        let vm = HomeViewModel(registry: registry)

        registry.activeSourceID = Self.injectedB

        XCTAssertEqual(vm.source?.id, Self.injectedB)
    }

    // MARK: - Search

    func testSearchFollowsTheInjectedRegistrysActiveSource() {
        let vm = SearchViewModel(registry: injectedRegistry(active: Self.injectedB))

        XCTAssertEqual(vm.source?.id, Self.injectedB)
    }

    /// The chip bar scopes search without moving the app-wide active source, and the id it
    /// sets has to be looked up in the *injected* registry.
    func testSearchResolvesItsSelectedSourceInTheInjectedRegistry() {
        let vm = SearchViewModel(registry: injectedRegistry(active: Self.injectedA))

        vm.selectSource(id: Self.injectedB)

        XCTAssertEqual(vm.source?.id, Self.injectedB)
    }

    func testEmptyRegistryHasNoActiveSourceAndDoesNotFallback() {
        let registry = SourceRegistry(sources: [])
        let manga = Manga(id: "x", sourceId: LegacySourceID.unattributed, title: "Title", description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: nil)
        XCTAssertNil(registry.active)
        XCTAssertNil(registry.source(id: "mangadex"))
        XCTAssertNil(registry.source(for: manga))
        XCTAssertNil(registry.sourceForRefresh(sourceId: nil))
    }

    func testBrowseViewModelsDoNotReportAnErrorWithoutASource() async {
        let registry = SourceRegistry(sources: [])
        let home = HomeViewModel(registry: registry)
        home.loadHome()
        await Task.yield()
        XCTAssertNil(home.errorMessage)
        let search = SearchViewModel(registry: registry)
        XCTAssertNil(search.source)
    }

    // MARK: - Detail

    /// The original bug, end to end: a detail page opened on a manga from an injected
    /// source loads that source's chapters. Resolving through the singleton gives a source
    /// that does not serve this manga at all.
    func testDetailLoadsChaptersFromTheInjectedRegistry() async {
        let registry = injectedRegistry()
        let manga = Manga(id: "x", sourceId: Self.injectedB, title: "Title", description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: nil)
        let vm = MangaDetailViewModel(manga: manga)

        vm.adopt(registry: registry)
        await vm.loadAsync()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.chapters.count, 3)
    }

    /// Adopting on a later appear must not snap the page back to the Listing it opened
    /// with — the reader may have switched source since (ADR-0004).
    func testAdoptingAgainKeepsTheRetargetedListing() async {
        let registry = injectedRegistry()
        let manga = Manga(id: "x", sourceId: Self.injectedA, title: "Title", description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: nil)
        let vm = MangaDetailViewModel(manga: manga)
        vm.adopt(registry: registry)

        vm.retarget(to: ListingKey(sourceId: Self.injectedB, mangaId: "x"), using: registry)
        vm.adopt(registry: registry)
        await vm.loadAsync()

        XCTAssertEqual(vm.activeListing.sourceId, Self.injectedB)
        XCTAssertEqual(vm.chapters.count, 3)
    }

    /// A manga whose own source is not registered still gets *a* source — the same
    /// fallback `SourceRegistry.source(for:)` has always applied, taken from the injected
    /// registry rather than the singleton.
    func testDetailFallsBackWithinTheInjectedRegistry() async {
        let registry = injectedRegistry(active: Self.injectedB)
        let manga = Manga(id: "x", sourceId: "not-registered-anywhere", title: "Title",
                          description: "", status: "ongoing", year: nil, coverURL: nil,
                          malId: nil)
        let vm = MangaDetailViewModel(manga: manga)

        vm.adopt(registry: registry)
        await vm.loadAsync()

        XCTAssertEqual(vm.chapters.count, 3)
    }

    func testDetailDoesNotFallbackForAnUninstalledSource() async {
        let registry = injectedRegistry(active: Self.injectedB)
        let uninstalledID = "historical-extension"
        registry.setKnownSourceIDs([uninstalledID])
        let manga = Manga(id: "x", sourceId: uninstalledID, title: "Title",
                          description: "", status: "ongoing", year: nil, coverURL: nil,
                          malId: nil)
        let vm = MangaDetailViewModel(manga: manga)

        vm.adopt(registry: registry)
        await vm.loadAsync()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.chapters.isEmpty)
    }

    /// Loading before the view has adopted a registry says so rather than showing an empty
    /// chapter list, which reads as "this manga has no chapters".
    func testDetailWithoutARegistryReportsNoSourceRatherThanNoChapters() async {
        let manga = Manga(id: "x", sourceId: Self.injectedA, title: "Title", description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: nil)
        let vm = MangaDetailViewModel(manga: manga)

        await vm.loadAsync()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.chapters.isEmpty)
    }
}

/// Chapter counts are the assertion surface: each stub returns a distinct number, so which
/// source answered is visible without reaching into the view model's private state.
private struct InjectedStubSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    let chapterNumbers: [String]

    func chapters(mangaId: String) async throws -> [Chapter] {
        chapterNumbers.map { Chapter(id: "\(id)-\($0)", number: $0, title: nil, date: nil) }
    }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
