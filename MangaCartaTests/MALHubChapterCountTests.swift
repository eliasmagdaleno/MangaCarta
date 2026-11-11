import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("MALHubChapterCountTests")
struct MALHubChapterCountTests {
    @Test func testOnlyTopThreeChoicesAreCounted() async {
        let directory = TestDirectory("MALHubChapterCount")
        let defaults = TestDefaults("MALHubChapterCount")
        defer { directory.remove() }
        defer { defaults.remove() }
        let source = CountFixtureSource(id: "count-a", count: 3)
        let registry = SourceRegistry(sources: [source], defaults: defaults.defaults,
                                     showAdultContent: { true })
        let loader = MALHubChapterCountLoader(registry: registry,
                                              cache: ListingCountCache(directory: directory.url))
        let choices = (0..<4).map { index in
            MALHubChoice(manga: source.manga(id: "\(index)", title: "Title \(index)"),
                         sourceName: source.name, kind: .possible)
        }
        let groups = [MALHubSourceGroup(sourceId: source.id, sourceName: source.name,
                                        choices: choices, ambiguous: false, status: .choices)]
        let result = await loader.load(groups)
        func key(_ id: String) -> ListingKey { ListingKey(sourceId: source.id, mangaId: id) }
        #expect(result[key("0")] == 3)
        #expect(result[key("1")] == 3)
        #expect(result[key("2")] == 3)
        #expect(result[key("3")] == nil)
        #expect(source.calls == 3)
    }

    @Test func testCachedCountAvoidsSourceCall() async {
        let directory = TestDirectory("MALHubChapterCountCache")
        let defaults = TestDefaults("MALHubChapterCountCache")
        defer { directory.remove() }
        defer { defaults.remove() }
        let source = CountFixtureSource(id: "count-a", count: 7)
        let listing = ListingKey(sourceId: source.id, mangaId: "cached")
        let cache = ListingCountCache(directory: directory.url)
        cache.record(42, for: listing)
        let loader = MALHubChapterCountLoader(registry: SourceRegistry(
            sources: [source], defaults: defaults.defaults), cache: cache)
        let choice = MALHubChoice(manga: source.manga(id: listing.mangaId, title: "Cached"),
                                  sourceName: source.name, kind: .exact)
        let group = MALHubSourceGroup(sourceId: source.id, sourceName: source.name,
                                      choices: [choice], ambiguous: false, status: .choices)
        let result = await loader.load([group])
        #expect(result[listing] == 42)
        #expect(source.calls == 0)
    }

    @Test func testMissingOrFailedCountReadsUnknownNotZero() async {
        let directory = TestDirectory("MALHubChapterCountUnknown")
        let defaults = TestDefaults("MALHubChapterCountUnknown")
        defer { directory.remove() }
        defer { defaults.remove() }
        let source = CountFixtureSource(id: "count-a", count: nil)
        let registry = SourceRegistry(sources: [source], defaults: defaults.defaults)
        let loader = MALHubChapterCountLoader(registry: registry,
                                              cache: ListingCountCache(directory: directory.url))
        let choice = MALHubChoice(manga: source.manga(id: "unknown", title: "Unknown"),
                                  sourceName: source.name, kind: .exact)
        let group = MALHubSourceGroup(sourceId: source.id, sourceName: source.name,
                                      choices: [choice], ambiguous: false, status: .choices)
        let result = await loader.load([group])
        #expect(result[ListingKey(sourceId: source.id, mangaId: "unknown")] == nil)
    }

    @Test func testCountsDistinctChaptersLikeFulfillment() async {
        let directory = TestDirectory("MALHubChapterCountDistinct")
        let defaults = TestDefaults("MALHubChapterCountDistinct")
        defer { directory.remove() }
        defer { defaults.remove() }
        let chapters = [
            Chapter(id: "a", number: "1", title: nil, groups: ["A"]),
            Chapter(id: "b", number: "1", title: nil, groups: ["B"]),
            Chapter(id: "c", number: "2", title: nil, groups: ["A"])
        ]
        let source = CountFixtureSource(id: "count-a", chapters: chapters)
        let registry = SourceRegistry(sources: [source], defaults: defaults.defaults)
        let loader = MALHubChapterCountLoader(registry: registry,
                                              cache: ListingCountCache(directory: directory.url))
        let choice = MALHubChoice(manga: source.manga(id: "distinct", title: "Distinct"),
                                  sourceName: source.name, kind: .exact)
        let group = MALHubSourceGroup(sourceId: source.id, sourceName: source.name,
                                      choices: [choice], ambiguous: false, status: .choices)
        let result = await loader.load([group])
        #expect(result[ListingKey(sourceId: source.id, mangaId: "distinct")] == 2)
    }

    /// A count fetched for the chooser lands in `ListingCountCache`, in fulfillment's units,
    /// so the next open (and fulfillment ranking) reads it instead of recounting.
    @Test func testFetchedCountIsRecordedInCache() async {
        let directory = TestDirectory("MALHubChapterCountRecord")
        let defaults = TestDefaults("MALHubChapterCountRecord")
        defer { directory.remove() }
        defer { defaults.remove() }
        let source = CountFixtureSource(id: "count-a", count: 5)
        let cache = ListingCountCache(directory: directory.url)
        let loader = MALHubChapterCountLoader(registry: SourceRegistry(
            sources: [source], defaults: defaults.defaults), cache: cache)
        let choice = MALHubChoice(manga: source.manga(id: "fresh", title: "Fresh"),
                                  sourceName: source.name, kind: .exact)
        _ = await loader.load([MALHubSourceGroup(sourceId: source.id, sourceName: source.name,
                                                 choices: [choice], ambiguous: false, status: .choices)])
        #expect(cache.count(for: ListingKey(sourceId: source.id, mangaId: "fresh")) == 5)
    }

    /// Source-local ids are only unique within a Source; two Sources' "1" are two Listings.
    @Test func testSameMangaIdOnTwoSourcesIsCountedSeparately() async {
        let directory = TestDirectory("MALHubChapterCountTwoSources")
        let defaults = TestDefaults("MALHubChapterCountTwoSources")
        defer { directory.remove() }
        defer { defaults.remove() }
        let a = CountFixtureSource(id: "count-a", count: 2)
        let b = CountFixtureSource(id: "count-b", count: 9)
        let loader = MALHubChapterCountLoader(registry: SourceRegistry(
            sources: [a, b], defaults: defaults.defaults), cache: ListingCountCache(directory: directory.url))
        let groups = [a, b].map { source in
            MALHubSourceGroup(sourceId: source.id, sourceName: source.name,
                              choices: [MALHubChoice(manga: source.manga(id: "1", title: "Same"),
                                                     sourceName: source.name, kind: .exact)],
                              ambiguous: false, status: .choices)
        }
        let result = await loader.load(groups)
        #expect(result[ListingKey(sourceId: "count-a", mangaId: "1")] == 2)
        #expect(result[ListingKey(sourceId: "count-b", mangaId: "1")] == 9)
    }
}

@MainActor
private final class CountFixtureSource: MangaSource {
    let id: String
    let name: String
    let count: Int?
    let chapterList: [Chapter]?
    private(set) var calls = 0

    init(id: String, count: Int?) {
        self.id = id
        name = "Count Source"
        self.count = count
        chapterList = nil
    }

    init(id: String, chapters: [Chapter]) {
        self.id = id
        name = "Count Source"
        count = nil
        chapterList = chapters
    }

    func manga(id: String) async throws -> Manga? { manga(id: id, title: id) }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { .init(description: "", authors: [], tags: [], contentRating: nil) }
    func chapters(mangaId: String) async throws -> [Chapter] {
        calls += 1
        if let chapterList { return chapterList }
        guard let count else { throw SourceError.unavailable("count") }
        return (0..<count).map { Chapter(id: "\($0)", number: "\($0)", title: nil) }
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }

    func manga(id: String, title: String) -> Manga {
        Manga(id: id, sourceId: self.id, title: title, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: nil)
    }
}
