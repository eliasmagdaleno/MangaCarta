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
        #expect(result["0"] == 3)
        #expect(result["1"] == 3)
        #expect(result["2"] == 3)
        #expect((result["3"] ?? nil) == nil)
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
        #expect(result[listing.mangaId] == 42)
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
        #expect((result["unknown"] ?? nil) == nil)
    }
}

@MainActor
private final class CountFixtureSource: MangaSource {
    let id: String
    let name: String
    let count: Int?
    private(set) var calls = 0

    init(id: String, count: Int?) {
        self.id = id
        name = "Count Source"
        self.count = count
    }

    func manga(id: String) async throws -> Manga? { manga(id: id, title: id) }
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { .init(description: "", authors: [], tags: [], contentRating: nil) }
    func chapters(mangaId: String) async throws -> [Chapter] {
        calls += 1
        guard let count else { throw SourceError.unavailable("count") }
        return (0..<count).map { Chapter(id: "\($0)", number: "\($0)", title: nil) }
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }

    func manga(id: String, title: String) -> Manga {
        Manga(id: id, sourceId: self.id, title: title, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: nil)
    }
}
