import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("SourceTitleSearchTests")
struct SourceTitleSearchTests {
    @Test func outcomesPreserveRegistryOrder() async {
        let first = SearchSource(id: "first", delay: 0.08)
        let second = SearchSource(id: "second", delay: 0.01)
        let registry = makeRegistry([first, second])
        let outcomes = await SourceTitleSearch(registry: registry, showAdultContent: false).search(spellings: ["Title"])
        #expect(outcomes.map(\.sourceId) == ["first", "second"])
    }

    @Test func excludingDropsSourcesAndLocalIsNeverSearched() async {
        let local = SearchSource(id: LocalSource.sourceID)
        let excluded = SearchSource(id: "excluded")
        let included = SearchSource(id: "included")
        let outcomes = await SourceTitleSearch(registry: makeRegistry([local, excluded, included]), showAdultContent: false)
            .search(spellings: ["Title"], excluding: ["excluded"])
        #expect(outcomes.map(\.sourceId) == ["included"])
        #expect(await local.calls == 0)
        #expect(await excluded.calls == 0)
    }

    @Test func stopWhenStopsSpellingLoop() async {
        let source = SearchSource(id: "source", results: [manga("match", source: "source", title: "Title")])
        let outcomes = await SourceTitleSearch(registry: makeRegistry([source]), showAdultContent: false)
            .search(spellings: ["Title", "Alias"], stopWhen: { !$0.isEmpty })
        #expect(await source.titles == ["Title"])
        guard case .found(let results) = outcomes[0].result else { Issue.record("expected found"); return }
        #expect(results.map(\.id) == ["match"])
    }

    @Test func unansweredSourceTimesOutAndChallengePausesDeadline() async {
        let source = SearchSource(id: "slow", delay: 30)
        let start = Date()
        let outcomes = await SourceTitleSearch(registry: makeRegistry([source]), showAdultContent: false,
                                               challengeActive: {
                                                   Date().timeIntervalSince(start) < 0.12
                                               }, deadline: 0.04, probeInterval: 0.01)
            .search(spellings: ["Title"])
        #expect(Date().timeIntervalSince(start) >= 0.12)
        guard case .timedOut = outcomes[0].result else { Issue.record("expected timeout"); return }
        #expect(await source.cancelled)
    }
}

@MainActor
private func makeRegistry(_ sources: [SearchSource]) -> SourceRegistry {
    SourceRegistry(sources: sources, defaults: UserDefaults(suiteName: "SourceTitleSearchTests")!)
}

private func manga(_ id: String, source: String, title: String) -> Manga {
    Manga(id: id, sourceId: source, title: title, description: "", status: "unknown", year: nil, coverURL: nil, malId: nil)
}

private actor SearchSourceState {
    var calls = 0
    var titles: [String] = []
    var cancelled = false
}

private struct SearchSource: MangaSource, @unchecked Sendable {
    let id: String
    let delay: TimeInterval
    let results: [Manga]
    let state = SearchSourceState()
    var name: String { id }

    init(id: String, delay: TimeInterval = 0, results: [Manga] = []) {
        self.id = id; self.delay = delay; self.results = results
    }

    var calls: Int { get async { await state.calls } }
    var titles: [String] { get async { await state.titles } }
    var cancelled: Bool { get async { await state.cancelled } }

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        await state.increment(title)
        do {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            return results
        } catch {
            if Task.isCancelled { await state.markCancelled() }
            throw error
        }
    }

    func mangaDetail(id: String) async throws -> MangaDetail { throw SearchSourceError.unsupported }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { throw SearchSourceError.unsupported }
    func chapters(mangaId: String) async throws -> [Chapter] { throw SearchSourceError.unsupported }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
        throw SearchSourceError.unsupported
    }
}

private enum SearchSourceError: Error { case unsupported }

private extension SearchSourceState {
    func increment(_ title: String) { calls += 1; titles.append(title) }
    func markCancelled() { cancelled = true }
}
