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
        let resolver = MALEntityResolver(store: .shared)
        let target = Manga(id: "target", sourceId: "source", title: "Vagabond", description: "",
                           status: "unknown", year: nil, coverURL: nil, malId: nil)
        let reverse = MALReverseResolver(search: { _ in [target] }, fetchByIds: { _ in [] })
        let counter = CallCounter()
        let fetched = detail()
        let provider = MoreLikeThisProvider(resolver: resolver, reverse: reverse, detailStore: store,
                                            fetchDetail: { _ in await counter.increment(); return fetched }, source: { nil })
        _ = await provider.recommendations(for: manga)
        _ = await provider.recommendations(for: manga)
        let callCount = await counter.value
        XCTAssertEqual(callCount, 1)
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

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation = $0 }
    }
}
