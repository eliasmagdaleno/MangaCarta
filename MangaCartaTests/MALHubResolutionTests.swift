import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("MALHubResolutionTests")
struct MALHubResolutionTests {
    @Test func testExactIdOpensDirectly() async {
        let source = FakeMALSource(id: "one", results: [manga("one", source: "one", title: "Other", malId: 42)])
        let resolver = makeResolver(sources: [source])
        let result = await resolver.resolve(candidate: candidate(42, title: "MAL"))
        guard case .open(let value) = result else { Issue.record("expected direct open"); return }
        #expect(value.malId == 42)
    }

    @Test func testMultipleExactSourcesRequireChoice() async {
        let a = FakeMALSource(id: "a", results: [manga("a1", source: "a", title: "A", malId: 42)])
        let b = FakeMALSource(id: "b", results: [manga("b1", source: "b", title: "B", malId: 42)])
        let result = await makeResolver(sources: [a, b]).resolve(candidate: candidate(42, title: "MAL"))
        guard case .chooser(let groups) = result else { Issue.record("expected chooser"); return }
        #expect(groups.flatMap(\.choices).count == 2)
    }

    @Test func testResolvedCandidateOpensWithoutSearching() async {
        let source = FakeMALSource(id: "one")
        let listing = manga("one", source: "one", title: "Resolved", malId: 42)
        let result = await makeResolver(sources: [source]).resolve(candidate: candidate(42, title: "MAL", resolved: listing))
        guard case .open(let value) = result else { Issue.record("expected open"); return }
        #expect(value == listing)
        #expect(await source.recorder.calls == 0)
    }

    @Test func testFuzzyChoicesRequireReaderConfirmation() async {
        let source = FakeMALSource(id: "one", results: [manga("one", source: "one", title: "Berserk", malId: nil)])
        let result = await makeResolver(sources: [source]).resolve(candidate: candidate(42, title: "Berserk"))
        guard case .chooser(let groups) = result else { Issue.record("expected chooser"); return }
        #expect(groups[0].choices.first?.kind == .possible)
    }

    @Test func testAmbiguousChoicesAreShownWithoutPreselection() async {
        let source = FakeMALSource(id: "one", results: [
            manga("one", source: "one", title: "Hero", malId: nil),
            manga("two", source: "one", title: "Hero", malId: nil),
        ])
        let result = await makeResolver(sources: [source]).resolve(candidate: candidate(42, title: "Hero"))
        guard case .chooser(let groups) = result else { Issue.record("expected chooser"); return }
        #expect(groups[0].ambiguous)
        #expect(groups[0].choices.allSatisfy { $0.kind == .possible })
    }

    @Test func testSearchesEveryAdmittedSourceWithBoundedConcurrency() async {
        let recorder = SearchRecorder()
        let sources = (0..<6).map {
            FakeMALSource(id: "s\($0)", results: [], delay: 0.3, recorder: recorder)
        }
        let result = await makeResolver(sources: sources, deadline: 2, probeInterval: 0.01)
            .resolve(candidate: candidate(42, title: "Missing"))
        guard case .notFound = result else { Issue.record("expected not found"); return }
        for source in sources {
            #expect(await source.recorder.calls(for: source.id) == 1)
        }
        #expect(await recorder.maxConcurrent == 4)
        #expect(await recorder.calls == 6)
    }

    @Test func testSearchSpellingsComeFromTappedDetailNotNestedNode() async {
        let recorder = SearchRecorder()
        let source = FakeMALSource(id: "one", recorder: recorder)
        let detail = makeDetail(title: "Tapped", alternatives: ["English", "Native", "Extra"])
        _ = await makeResolver(sources: [source]).resolve(candidate: candidate(42, title: "Nested"), detail: detail)
        #expect(await recorder.titles == ["Tapped", "English", "Native"])

        let fallback = SearchRecorder()
        let fallbackSource = FakeMALSource(id: "fallback", recorder: fallback)
        let noAlternates = makeDetail(title: "Tapped", alternatives: [])
        _ = await makeResolver(sources: [fallbackSource], alternativeTitles: { _ in ["MAL", "Fallback"] })
            .resolve(candidate: candidate(42, title: "Nested"), detail: noAlternates)
        #expect(await fallback.titles == ["Tapped", "Fallback"])
    }

    @Test func testLocalAndHiddenSourcesAreNeverSearched() async {
        let local = FakeMALSource(id: LocalSource.sourceID)
        let hidden = FakeMALSource(id: "hidden", isNSFW: true)
        let visible = FakeMALSource(id: "visible")
        _ = await makeResolver(sources: [local, hidden, visible]).resolve(candidate: candidate(42, title: "Missing"))
        #expect(await local.recorder.calls == 0)
        #expect(await hidden.recorder.calls == 0)
        #expect(await visible.recorder.calls == 1)
    }

    @Test func testSourceFailureIsPerSourceAndTransient() async {
        let failed = FakeMALSource(id: "failed", error: TestError.failed)
        let good = FakeMALSource(id: "good", results: [manga("good", source: "good", title: "Good", malId: nil)])
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let store = MALSourceChoiceStore(directory: directory.url)
        let result = await makeResolver(sources: [failed, good], store: store).resolve(candidate: candidate(42, title: "Good"))
        guard case .chooser(let groups) = result else { Issue.record("expected chooser"); return }
        #expect(groups.first(where: { $0.sourceId == "failed" })?.status == .couldNotCheckFailed)
        #expect(groups.first(where: { $0.sourceId == "good" })?.choices.first?.kind == .possible)
        #expect(await store.choice(for: 42) == nil)
    }

    @Test func testDeadlineCutsOffSlowSearchWithoutChallenge() async {
        let source = FakeMALSource(id: "slow", delay: 30)
        let resolver = makeResolver(sources: [source], deadline: 0.2, probeInterval: 0.02)
        let start = Date()
        _ = await resolver.resolve(candidate: candidate(42, title: "Slow"))
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(await source.recorder.cancelled)
    }

    @Test func testChallengeSuspendsOrchestrationDeadline() async {
        let source = FakeMALSource(id: "challenged", delay: 0.6)
        let result = await makeResolver(sources: [source], deadline: 0.2, probeInterval: 0.02,
                                        challengeActive: { true }).resolve(candidate: candidate(42, title: "Slow"))
        guard case .notFound = result else { Issue.record("expected completed search with no result"); return }
        #expect(await source.recorder.cancelled == false)
    }

    @Test func testCancellationLeavesNoPendingWorkOrWrite() async {
        let sources = (0..<6).map { FakeMALSource(id: "cancel\($0)", delay: 30) }
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let store = MALSourceChoiceStore(directory: directory.url)
        let resolver = makeResolver(sources: sources, store: store, deadline: 30)
        let task = Task { await resolver.resolve(candidate: candidate(42, title: "Cancel")) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        _ = await task.value
        #expect(await store.choice(for: 42) == nil)
        for source in sources { #expect(await source.recorder.cancelled) }
    }

    @Test func testRememberedChoiceOpensDirectlyWhileValid() async {
        let source = FakeMALSource(id: "remembered", detailRating: "safe")
        let value = manga("m", source: "remembered", title: "Remembered", malId: nil)
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let store = MALSourceChoiceStore(directory: directory.url)
        await store.confirm(malId: 42, sourceId: "remembered", manga: value, title: "MAL")
        let result = await makeResolver(sources: [source], store: store).resolve(candidate: candidate(42, title: "MAL"))
        guard case .open(let opened) = result else { Issue.record("expected remembered open"); return }
        #expect(opened.id == "m")
    }

    @Test func testMissingRememberedChoiceFallsBackToChooser() async {
        let source = FakeMALSource(id: "source", results: [manga("new", source: "source", title: "MAL", malId: 42)])
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let store = MALSourceChoiceStore(directory: directory.url)
        let stale = manga("gone", source: "missing", title: "Old", malId: nil)
        await store.confirm(malId: 42, sourceId: "missing", manga: stale, title: "MAL")
        let result = await makeResolver(sources: [source], store: store).resolve(candidate: candidate(42, title: "MAL"))
        guard case .open(let opened) = result else { Issue.record("expected new exact result"); return }
        #expect(opened.id == "new")
        #expect(await store.choice(for: 42) == nil)
    }

    @Test func testRememberedChoiceNotAdmittedIsDiscarded() async {
        let source = FakeMALSource(id: "adult", detailRating: "pornographic")
        let value = manga("remembered", source: "adult", title: "MAL", malId: nil)
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let store = MALSourceChoiceStore(directory: directory.url)
        await store.confirm(malId: 42, sourceId: "adult", manga: value, title: "MAL")
        let result = await makeResolver(sources: [source], store: store)
            .resolve(candidate: candidate(42, title: "MAL"))
        guard case .open(let opened) = result else {
            #expect(await store.choice(for: 42) == nil)
            return
        }
        #expect(opened.id != "remembered")
        #expect(await store.choice(for: 42) == nil)
    }

    @Test func testTransientRevalidationFailureKeepsChoice() async {
        let source = FakeMALSource(id: "remembered", detailError: TestError.failed)
        let value = manga("m", source: "remembered", title: "Remembered", malId: nil)
        let directory = TestDirectory(#function)
        defer { directory.remove() }
        let store = MALSourceChoiceStore(directory: directory.url)
        await store.confirm(malId: 42, sourceId: "remembered", manga: value, title: "MAL")
        _ = await makeResolver(sources: [source], store: store).resolve(candidate: candidate(42, title: "MAL"))
        #expect(await store.choice(for: 42) != nil)
    }
}

private enum TestError: Error { case failed }

private func candidate(_ id: Int, title: String, resolved: Manga? = nil) -> MALDiscoveryCandidate {
    MALDiscoveryCandidate(malId: id, title: title, coverURL: nil, reason: .recommendation,
                          resolvedListing: resolved)
}

private func manga(_ id: String, source: String, title: String, malId: Int? = nil) -> Manga {
    Manga(id: id, sourceId: source, title: title, description: "", status: "unknown",
          year: nil, coverURL: nil, malId: malId)
}

private func makeDetail(title: String, alternatives: [String]) -> MyAnimeListMangaDetail {
    .init(id: 42, title: title, synopsis: nil, mainPicture: nil, genres: nil,
          relatedManga: nil, recommendations: nil,
          alternativeTitles: .init(synonyms: Array(alternatives.dropFirst(2)),
                                  en: alternatives.first, ja: alternatives.dropFirst().first))
}

@MainActor
private func makeResolver(sources: [FakeMALSource], store: MALSourceChoiceStore? = nil,
                          showAdultContent: Bool = false, deadline: TimeInterval = 1,
                          probeInterval: TimeInterval = 0.02,
                          challengeActive: @escaping @Sendable () async -> Bool = { false },
                          alternativeTitles: @escaping @Sendable (Int) async throws -> [String] = { _ in [] }) -> MALHubResolver {
    let defaults = TestDefaults("MALHubResolution")
    defer { defaults.remove() }
    let directory = TestDirectory("MALHubResolution")
    defer { directory.remove() }
    let registry = SourceRegistry(sources: sources, defaults: defaults.defaults)
    return MALHubResolver(registry: registry, store: store ?? MALSourceChoiceStore(directory: directory.url),
                          showAdultContent: showAdultContent, challengeActive: challengeActive,
                          deadline: deadline, probeInterval: probeInterval,
                          alternativeTitles: alternativeTitles)
}

private actor SearchRecorder {
    var calls = 0
    var concurrent = 0
    var maxConcurrent = 0
    var titles: [String] = []
    var cancelled = false

    var callsBySource: [String: Int] = [:]
    func begin(_ title: String, sourceID: String) {
        calls += 1
        callsBySource[sourceID, default: 0] += 1
        titles.append(title)
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
    }
    func calls(for sourceID: String) -> Int { callsBySource[sourceID, default: 0] }
    func end() { concurrent -= 1 }
    func cancellation() { cancelled = true; concurrent = max(0, concurrent - 1) }
}

private struct FakeMALSource: MangaSource, @unchecked Sendable {
    let id: String
    var name: String { id }
    var isNSFW: Bool
    let results: [Manga]
    let delay: TimeInterval
    let error: Error?
    let detailError: Error?
    let detailRating: String?
    let recorder: SearchRecorder

    init(id: String, results: [Manga] = [], isNSFW: Bool = false, delay: TimeInterval = 0,
         error: Error? = nil, detailError: Error? = nil, detailRating: String? = nil,
         recorder: SearchRecorder = SearchRecorder()) {
        self.id = id; self.results = results; self.isNSFW = isNSFW; self.delay = delay
        self.error = error; self.detailError = detailError; self.detailRating = detailRating
        self.recorder = recorder
    }

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        await recorder.begin(title, sourceID: id)
        do {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            if let error { throw error }
            await recorder.end()
            return results
        } catch {
            if Task.isCancelled { await recorder.cancellation() } else { await recorder.end() }
            throw error
        }
    }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        if let detailError { throw detailError }
        return MangaDetail(description: "", authors: [], tags: [], contentRating: detailRating)
    }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
