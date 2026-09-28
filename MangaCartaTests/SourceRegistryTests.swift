import Foundation
import Testing
@testable import MangaCarta

@MainActor @Suite("SourceRegistryTests")
struct SourceRegistryTests {
    @Test func visibleSourcesNeverIncludesLocal() {
        let registry = SourceRegistry(sources: [LocalSource(), MangaDexSource()])
        #expect(registry.visibleSources(includeAdult: true).map(\.id) == [MangaDexSource.sourceID])
        #expect(!registry.browsableSourceNames.contains("Local"))
    }

    @Test func localIsResolvableById() {
        let registry = SourceRegistry(sources: [LocalSource(), MangaDexSource()])
        #expect(registry.source(id: "local")?.id == "local")
    }
    @Test func onlyAnAdultOnlySourceAndSwitchOffMeansNoActiveSource() {
        let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "a", isNSFW: true)],
                                      showAdultContent: { false })
        #expect(registry.active == nil)
    }

    @Test func onlyAnAdultOnlySourceAndSwitchOnMakesItActive() {
        let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "a", isNSFW: true)],
                                      showAdultContent: { true })
        #expect(registry.active?.id == "a")
    }

    @Test func aStoredAdultOnlyChoiceIsNotHonouredWhileTheSwitchIsOff() {
        let saved = UserDefaults.standard.object(forKey: "source.activeID")
        defer { UserDefaults.standard.set(saved, forKey: "source.activeID") }

        var show = true
        let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "safe"), StubSource(id: "a", isNSFW: true)],
                                      showAdultContent: { show })
        registry.activeSourceID = "a"
        show = false
        #expect(registry.active?.id == "safe")
    }

    @Test func aMixedSourceIsActiveWithTheSwitchOff() {
        let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "m", declaresAdultTitles: true)],
                                      showAdultContent: { false })
        #expect(registry.active?.id == "m")
    }

    @Test func fallbackPrefersANonAdultSourceEvenWithTheSwitchOn() {
        let saved = UserDefaults.standard.object(forKey: "source.activeID")
        defer { UserDefaults.standard.set(saved, forKey: "source.activeID") }

        let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "a", isNSFW: true), StubSource(id: "safe")],
                                      showAdultContent: { true })
        registry.activeSourceID = "gone"
        #expect(registry.active?.id == "safe")
    }

    @Test func discoveryRejectsAdultTitlesAndUnknownOrHiddenSources() {
        let registry = SourceRegistry(sources: [LocalSource(),
                                                StubSource(id: "m", declaresAdultTitles: true),
                                                StubSource(id: "a", isNSFW: true, declaresAdultTitles: true)],
                                      showAdultContent: { false })
        #expect(registry.admitsForDiscovery(manga("1", source: "m", rating: "safe")))
        #expect(!registry.admitsForDiscovery(manga("2", source: "m", rating: "erotica")))
        #expect(!registry.admitsForDiscovery(manga("3", source: "m", rating: nil)))
        #expect(!registry.admitsForDiscovery(manga("4", source: "a", rating: "safe")))
        #expect(!registry.admitsForDiscovery(manga("5", source: "gone", rating: nil)))
        #expect(registry.admitsForDiscovery(manga("6", source: "gone", rating: "safe")))
    }
}

private func manga(_ id: String, source: String, rating: String?) -> Manga {
    var value = Manga(id: id, sourceId: source, title: id, description: "",
                      status: "unknown", year: nil, coverURL: nil, malId: nil)
    value.contentRating = rating
    return value
}

private struct StubSource: MangaSource {
    let id: String
    var name: String { id }
    var isNSFW = false
    var declaresAdultTitles = false
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
