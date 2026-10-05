//
//  MangaDetailRetargetTests.swift
//  MangaCartaTests
//
//  Switching source on the detail page. ADR-0001 makes this a fulfillment change, not an
//  identity one: the Work is the manga, a Listing is only one source's copy of it, so the
//  title and cover on screen stay put while chapters come from somewhere else.
//

import XCTest
@testable import MangaCarta

@MainActor
final class MangaDetailRetargetTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults("MangaDetailRetargetTests")
    }

    private let mangaDexListing = Manga(
        id: "op", sourceId: "mangadex", title: "One Piece", description: "",
        status: "ongoing", year: nil, coverURL: URL(string: "https://example.com/cover.jpg"), malId: 42)

    private func registry() -> SourceRegistry {
        SourceRegistry(sources: [
            RetargetStubSource(id: "mangadex", chapterNumbers: ["1", "2"]),
            RetargetStubSource(id: "weebcentral", chapterNumbers: ["1", "2", "3"])
        ], defaults: defaults)
    }

    /// The point of the picker: after switching, chapters come from the chosen Listing.
    func testRetargetingLoadsChaptersFromTheChosenListing() async {
        let registry = registry()
        let vm = MangaDetailViewModel(manga: mangaDexListing,
                                      source: registry.source(id: "mangadex"))

        vm.retarget(to: ListingKey(sourceId: "weebcentral", mangaId: "one-piece"),
                    using: registry)
        await vm.loadAsync()

        XCTAssertEqual(vm.chapters.count, 3)
    }

    /// The identity does not move. `manga` is what the title, cover and Work lookup all read
    /// from, and re-pointing it at another source's row would rename the title under the
    /// reader as a side effect of choosing where to read.
    func testRetargetingLeavesTheDisplayedMangaAlone() async {
        let registry = registry()
        let vm = MangaDetailViewModel(manga: mangaDexListing,
                                      source: registry.source(id: "mangadex"))

        vm.retarget(to: ListingKey(sourceId: "weebcentral", mangaId: "one-piece"),
                    using: registry)
        await vm.loadAsync()

        XCTAssertEqual(vm.manga.id, "op")
        XCTAssertEqual(vm.manga.sourceId, "mangadex")
    }

    /// Which Listing is being fulfilled from, so the picker can mark the current row. It has
    /// to start as the Listing the page was opened with rather than as nil, or the picker
    /// shows nothing selected until the reader switches once.
    func testTheActiveListingStartsAsTheOpenedOne() {
        let vm = MangaDetailViewModel(manga: mangaDexListing,
                                      source: registry().source(id: "mangadex"))

        XCTAssertEqual(vm.activeListing, ListingKey(sourceId: "mangadex", mangaId: "op"))
    }

    func testReaderMangaStartsAsTheOpenedListing() {
        let vm = MangaDetailViewModel(manga: mangaDexListing,
                                      source: registry().source(id: "mangadex"))

        XCTAssertEqual(vm.readerManga, mangaDexListing)
    }

    func testReaderMangaFollowsRetargetedListingWhileKeepingDisplayedFields() {
        let registry = registry()
        let vm = MangaDetailViewModel(manga: mangaDexListing,
                                      source: registry.source(id: "mangadex"))

        vm.retarget(to: ListingKey(sourceId: "weebcentral", mangaId: "one-piece"), using: registry)

        XCTAssertEqual(vm.readerManga.id, "one-piece")
        XCTAssertEqual(vm.readerManga.sourceId, "weebcentral")
        XCTAssertEqual(vm.readerManga.title, mangaDexListing.title)
        XCTAssertEqual(vm.readerManga.coverURL, mangaDexListing.coverURL)
        XCTAssertEqual(vm.readerManga.malId, mangaDexListing.malId)
        XCTAssertEqual(registry.source(for: vm.readerManga)?.id, "weebcentral")
    }

    /// An unregistered source cannot fulfill anything, so retargeting to one is refused
    /// rather than half-applied. Leaving the view model pointed at a source it cannot reach
    /// would empty the chapter list and read as the manga having no chapters.
    func testRetargetingToAnUnregisteredSourceIsRefused() {
        let vm = MangaDetailViewModel(manga: mangaDexListing,
                                      source: registry().source(id: "mangadex"))

        vm.retarget(to: ListingKey(sourceId: "gone", mangaId: "x"), using: registry())

        XCTAssertEqual(vm.activeListing, ListingKey(sourceId: "mangadex", mangaId: "op"))
    }
}

private struct RetargetStubSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    let chapterNumbers: [String]

    func chapters(mangaId: String) async throws -> [Chapter] {
        chapterNumbers.map { Chapter(id: UUID().uuidString, number: $0, title: nil, date: nil) }
    }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
