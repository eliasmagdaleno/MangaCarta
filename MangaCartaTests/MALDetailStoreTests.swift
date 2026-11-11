import Foundation
import XCTest
@testable import MangaCarta

@MainActor
final class MALDetailStoreTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func detail(id: Int = 2, recommendationID: Int = 656) -> MyAnimeListMangaDetail {
        MyAnimeListMangaDetail(
            id: id, title: "Berserk", synopsis: "Guts",
            mainPicture: .init(medium: "m", large: "l"),
            genres: [.init(id: 1, name: "Action")],
            relatedManga: [.init(node: .init(id: 401, title: "Prototype", mainPicture: nil,
                                             alternativeTitles: nil, mediaType: nil),
                                relationType: "prequel", relationTypeFormatted: "Prequel")],
            recommendations: [.init(node: .init(id: recommendationID, title: "Vagabond",
                                                mainPicture: nil, alternativeTitles: nil, mediaType: nil),
                                    numRecommendations: 42)])
    }

    func testRealDecodedFixtureRoundTripsAcrossInstances() async throws {
        let json = """
        {"id":2,"title":"Berserk","synopsis":"Guts, a former mercenary...",
         "main_picture":{"medium":"https://example.com/m.jpg","large":"https://example.com/l.jpg"},
         "genres":[{"id":1,"name":"Action"},{"id":8,"name":"Drama"}],
         "related_manga":[{"node":{"id":401,"title":"Berserk: The Prototype"},"relation_type":"prequel",
                          "relation_type_formatted":"Prequel"}],
         "recommendations":[{"node":{"id":656,"title":"Vagabond"},"num_recommendations":42}]}
        """.data(using: .utf8)!
        let original = try decoder.decode(MyAnimeListMangaDetail.self, from: json)
        let directory = makeTestDirectory(#function)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = MALDetailStore(directory: directory)
        _ = await first.detail(for: original.id, now: now) { _ in original }
        let second = MALDetailStore(directory: directory)
        let loaded = await second.detail(for: original.id, now: now) { _ in XCTFail("fresh entry fetched"); return original }
        XCTAssertEqual(loaded, original)
    }

    func testNSFWDecodesKnownAndUnknownValues() throws {
        let values: [(String, MALNSFW)] = [("white", .white), ("gray", .gray),
                                           ("black", .black), ("purple", .unknown("purple"))]
        for (raw, expected) in values {
            let data = "\"\(raw)\"".data(using: .utf8)!
            XCTAssertEqual(try decoder.decode(MALNSFW.self, from: data), expected)
            let encoded = try JSONEncoder().encode(expected)
            XCTAssertEqual(try JSONDecoder().decode(MALNSFW.self, from: encoded), expected)
        }
    }

    func testRecordWithoutNSFWStillDecodes() async throws {
        let directory = makeTestDirectory(#function)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = "{\"2\":{\"detail\":{\"id\":2,\"title\":\"Berserk\",\"synopsis\":null,"
            + "\"main_picture\":null,\"genres\":null,\"related_manga\":null,"
            + "\"recommendations\":null},\"fetched_at\":0}}"
        try Data(json.utf8).write(to: directory.appendingPathComponent("mal-detail.json"))
        let store = MALDetailStore(directory: directory)
        let replacement = MyAnimeListMangaDetail(id: 2, title: "Berserk", synopsis: nil,
                                                  mainPicture: nil, genres: nil,
                                                  relatedManga: nil, recommendations: nil)
        let loaded = await store.detail(for: 2, now: Date(timeIntervalSince1970: 1)) { _ in XCTFail("must use cache"); return replacement }
        XCTAssertNil(loaded?.nsfw)
    }

    func testRecordWithoutAlternativeTitlesStillDecodes() throws {
        let json = """
        {"id":42,"title":"Berserk","synopsis":null,"main_picture":null,"genres":null,
         "related_manga":null,"recommendations":null,"nsfw":"white"}
        """.data(using: .utf8)!
        let value = try decoder.decode(MyAnimeListMangaDetail.self, from: json)
        XCTAssertNil(value.alternativeTitles)
        XCTAssertEqual(value.allTitles, ["Berserk"])

        let withTitles = MyAnimeListMangaDetail(id: 42, title: "  Main ", synopsis: nil,
                                                 mainPicture: nil, genres: nil, relatedManga: nil,
                                                 recommendations: nil, alternativeTitles: .init(
                                                    synonyms: ["Main", " Synonym "],
                                                    en: "English", ja: " Japanese "))
        XCTAssertEqual(withTitles.allTitles, ["Main", "English", "Japanese", "Synonym"])
    }

    func testFreshEntryAvoidsFetchWithin24Hours() async {
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let value = detail()
        let counter = CallCounter()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = await store.detail(for: value.id, now: start) { _ in await counter.increment(); return value }
        let loaded = await store.detail(for: value.id, now: start.addingTimeInterval(23 * 60 * 60)) { _ in await counter.increment(); return value }
        let callCount = await counter.value
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(loaded, value)
    }

    func testExpiredEntryCoalescesConcurrentFetches() async throws {
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let old = detail()
        let fresh = detail(recommendationID: 777)
        let start = Date(timeIntervalSince1970: 1_000)
        _ = await store.detail(for: old.id, now: start) { _ in old }
        let gate = FetchGate()
        let counter = CallCounter()
        let values = await withTaskGroup(of: MyAnimeListMangaDetail?.self, returning: [MyAnimeListMangaDetail?].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await store.detail(for: old.id, now: start.addingTimeInterval(25 * 60 * 60)) { _ in
                        await counter.increment()
                        await gate.enter()
                        await gate.waitForRelease()
                        return fresh
                    }
                }
            }
            try? await gate.waitUntilEntered(deadline: Date().addingTimeInterval(5))
            await gate.release()
            var output: [MyAnimeListMangaDetail?] = []
            for await value in group { output.append(value) }
            return output
        }
        let callCount = await counter.value
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(values.compactMap { $0 }, Array(repeating: fresh, count: 8))
    }

    func testFailedRefreshReturnsStaleRecord() async {
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let old = detail()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = await store.detail(for: old.id, now: now) { _ in old }
        let failed = await store.detail(for: old.id, now: now.addingTimeInterval(25 * 60 * 60)) { _ in throw TestError.failed }
        let replacement = detail(recommendationID: 777)
        let retried = await store.detail(for: old.id, now: now.addingTimeInterval(25 * 60 * 60)) { _ in replacement }
        XCTAssertEqual(failed, old)
        XCTAssertEqual(retried, replacement)
    }

    func testCorruptEntryIsIgnored() async {
        let directory = makeTestDirectory(#function)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("garbage".utf8).write(to: directory.appendingPathComponent("mal-detail.json"))
        let value = detail()
        let first = MALDetailStore(directory: directory)
        _ = await first.detail(for: value.id) { _ in value }
        let second = MALDetailStore(directory: directory)
        let loaded = await second.detail(for: value.id) { _ in XCTFail("repaired entry fetched"); return value }
        XCTAssertEqual(loaded, value)
    }

    func testCancelledFetchWritesNothing() async {
        let directory = makeTestDirectory(#function)
        let store = MALDetailStore(directory: directory)
        let result = await store.detail(for: 2) { _ in throw CancellationError() }
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mal-detail.json").path))
    }

    func testFailedFetchWithNoRecordReturnsNil() async {
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let result = await store.detail(for: 2) { _ in throw TestError.failed }
        XCTAssertNil(result)
    }

    func testMoreLikeThisReusesCachedDetailAcrossCalls() async {
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let manga = Manga(id: "source", sourceId: "source", title: "Berserk", description: "",
                          status: "unknown", year: nil, coverURL: nil, malId: 2)
        let resolutions = EntityResolutionStore(defaults: makeTestDefaults(#function))
        let resolver = MALEntityResolver(store: resolutions)
        let target = Manga(id: "target", sourceId: "source", title: "Vagabond", description: "",
                           status: "unknown", year: nil, coverURL: nil, malId: nil)
        let reverse = MALReverseResolver(store: resolutions, search: { _ in [target] },
                                         fetchByIds: { _ in [] }, fetchTitles: { _ in [] },
                                         source: { nil })
        let counter = CallCounter()
        let fetched = detail()
        let provider = MoreLikeThisProvider(resolver: resolver, reverse: reverse, detailStore: store,
                                            fetchDetail: { _ in await counter.increment(); return fetched }, source: { nil })
        _ = await provider.recommendations(for: manga)
        _ = await provider.recommendations(for: manga)
        let callCount = await counter.value
        XCTAssertEqual(callCount, 1)
    }

    /// Guards the view model's provider closure: it must capture the registry, not the VM,
    /// or every detail page opened leaks its view model.
    func testMoreLikeThisViewModelIsReleasedAfterLoad() async {
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let empty = MyAnimeListMangaDetail(id: 2, title: "Berserk", synopsis: nil, mainPicture: nil,
                                           genres: nil, relatedManga: nil, recommendations: [])
        _ = await store.detail(for: 2) { _ in empty }
        let registry = SourceRegistry(sources: [], defaults: makeTestDefaults(#function))
        let manga = Manga(id: "source", sourceId: "source", title: "Berserk", description: "",
                          status: "unknown", year: nil, coverURL: nil, malId: 2)
        var viewModel: MoreLikeThisViewModel? = MoreLikeThisViewModel(registry: registry)
        weak var weakViewModel = viewModel
        await viewModel?.load(for: manga, detailStore: store)
        viewModel = nil
        XCTAssertNil(weakViewModel)
    }

    /// A fetch orphaned by `invalidate` must not write its result over, or clear, the
    /// fetch that replaced it.
    func testInvalidatedFetchCannotOverwriteItsReplacement() async {
        let store = MALDetailStore(directory: makeTestDirectory(#function))
        let orphan = detail(recommendationID: 111)
        let replacement = detail(recommendationID: 222)
        let gate = FetchGate()
        let first = Task {
            await store.detail(for: 2) { _ in
                await gate.enter()
                await gate.waitForRelease()
                return orphan
            }
        }
        try? await gate.waitUntilEntered(deadline: Date().addingTimeInterval(5))
        await store.invalidate(malID: 2)
        _ = await store.detail(for: 2) { _ in replacement }
        await gate.release()
        _ = await first.value
        let loaded = await store.detail(for: 2) { _ in XCTFail("fresh replacement refetched"); return replacement }
        XCTAssertEqual(loaded, replacement)
    }
}

private enum TestError: Error { case failed }

private actor CallCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}

private actor FetchGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() {
        entered = true
    }

    func waitUntilEntered(deadline: Date) async throws {
        while !entered {
            if Date() >= deadline { throw TestError.failed }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Records the release even when no one is waiting yet, so a `release()` that lands
    /// before `waitForRelease()` can't strand the fetch forever.
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
