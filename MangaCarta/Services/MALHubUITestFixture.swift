#if DEBUG
import Foundation

enum MALHubUITestFixture {
    struct Storage {
        let defaults: UserDefaults
        let directory: URL
        let detailStore: MALDetailStore
        let choiceStore: MALSourceChoiceStore
        let entityStore: EntityResolutionStore
    }

    enum State {
        case adultOn
        case adultOff
        case noRails
        case unmatched

        var adult: Bool {
            switch self {
            case .adultOn: return true
            case .adultOff: return false
            case .noRails, .unmatched: return true
            }
        }
    }

    static var state: State? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uitest-mal-hub") { return .adultOn }
        if arguments.contains("-uitest-mal-hub-adult-off") { return .adultOff }
        if arguments.contains("-uitest-mal-hub-no-rails") { return .noRails }
        if arguments.contains("-uitest-mal-hub-unmatched") { return .unmatched }
        return nil
    }

    @MainActor static func storage() -> Storage {
        let id = ProcessInfo.processInfo.environment["MANGACARTA_UI_TEST_STORAGE_ID"] ?? UUID().uuidString
        let suite = "mal-hub-ui-test.\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaCarta-MALHubUITest-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let detailStore = MALDetailStore(directory: directory.appendingPathComponent("MALDetail"))
        let choiceStore = MALSourceChoiceStore(directory: directory.appendingPathComponent("MALHub"))
        let entityStore = EntityResolutionStore(defaults: defaults)
        // A Library row opens with no MAL id, so without this the forward resolver asks the
        // live MAL search first. That only "worked" where MAL answered (no match, then the
        // bridge through Source A); on CI, with no MAL client id, it threw and no rail rendered.
        entityStore.record(sourceId: MALHubFixtureSourceA.idValue, mangaId: "hub-fixture-title",
                           .resolved(malId: 1000))
        return Storage(defaults: defaults, directory: directory, detailStore: detailStore,
                       choiceStore: choiceStore, entityStore: entityStore)
    }

    @MainActor static func registry(state: State, defaults: UserDefaults) -> SourceRegistry {
        SourceRegistry(sources: [MALHubFixtureSourceA(), MALHubFixtureSourceB(), MALHubFixtureSourceC(),
                                 MALHubFixtureSourceD(), MALHubFixtureSourceE()],
                       defaults: defaults, showAdultContent: { state.adult })
    }

    static func fetchDetail(_ id: Int) async throws -> MyAnimeListMangaDetail {
        if id == 1000 {
            return detail(id: id, title: "Hub Fixture Title", related: [
                relation(id: 1100, title: "Fixture Related")
            ], recommendations: [
                recommendation(id: 1200, title: "Fixture Resolved", weight: 30),
                recommendation(id: 1300, title: "Fixture Chooser", weight: 20),
                recommendation(id: 1400, title: "Fixture Nowhere", weight: 10),
                recommendation(id: 1500, title: "Fixture Single Exact", weight: 5),
                recommendation(id: 1600, title: "Fixture Challenge", weight: 4)
            ])
        }
        if id == 2000 { return detail(id: id, title: "No Rails Fixture", related: [], recommendations: []) }
        if id == 3000 { return detail(id: id, title: "Unmatched Fixture", related: [], recommendations: []) }
        let titles = [1200: "Fixture Resolved", 1300: "Fixture Chooser", 1400: "Fixture Nowhere",
                      1500: "Fixture Single Exact", 1600: "Fixture Challenge", 1100: "Fixture Related"]
        let title = titles[id] ?? "Fixture"
        return detail(id: id, title: title, related: [], recommendations: [])
    }

    @MainActor
    static func seed(_ composition: AppComposition) {
        let state = self.state ?? .adultOn
        let manga: Manga
        switch state {
        case .adultOn, .adultOff:
            manga = Manga(id: "hub-fixture-title", sourceId: MALHubFixtureSourceA.idValue,
                          title: "Hub Fixture Title", description: "", status: "ongoing",
                          year: 2026, coverURL: nil, malId: 1000)
        case .noRails:
            manga = Manga(id: "no-rails-fixture", sourceId: MALHubFixtureSourceA.idValue,
                          title: "No Rails Fixture", description: "", status: "ongoing",
                          year: 2026, coverURL: nil, malId: 2000)
        case .unmatched:
            manga = Manga(id: "unmatched-fixture", sourceId: MALHubFixtureSourceA.idValue,
                          title: "Unmatched Fixture", description: "", status: "ongoing",
                          year: 2026, coverURL: nil, malId: nil)
        }
        composition.library.toggle(manga)
        let workID = composition.works.mint(from: manga)
        if case .unmatched = state {
            composition.attempts.record(.unmatched(knownTitlesCount: 1), for: workID)
            composition.attempts.flush()
        }
    }

    private static func detail(id: Int, title: String,
                               related: [MyAnimeListMangaDetail.Relation],
                               recommendations: [MyAnimeListMangaDetail.Recommendation]) -> MyAnimeListMangaDetail {
        MyAnimeListMangaDetail(id: id, title: title, synopsis: "A fixed fixture synopsis.",
                               mainPicture: nil, genres: [.init(id: 1, name: "Drama")],
                               relatedManga: related, recommendations: recommendations,
                               nsfw: .white,
                               alternativeTitles: .init(synonyms: ["Fixture Alternate"], en: nil, ja: nil))
    }

    private static func relation(id: Int, title: String) -> MyAnimeListMangaDetail.Relation {
        .init(node: .init(id: id, title: title, mainPicture: nil, alternativeTitles: nil, mediaType: "manga"),
              relationType: "sequel", relationTypeFormatted: "Sequel")
    }

    private static func recommendation(id: Int, title: String, weight: Int) -> MyAnimeListMangaDetail.Recommendation {
        .init(node: .init(id: id, title: title, mainPicture: nil, alternativeTitles: nil, mediaType: "manga"), numRecommendations: weight)
    }
}

private struct MALHubFixtureSourceA: MangaSource {
    static let idValue = "mal-hub-fixture-a"
    let id = Self.idValue
    let name = "Fixture Source A"
    let publishesExternalIds = true

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        if title == "Hub Fixture Title" { return [manga(id: "hub-fixture-title", title: title, malId: 1000)] }
        if title == "Fixture Resolved" && limit == 10 { return [manga(id: "resolved", title: title, malId: 1200)] }
        if title == "Fixture Chooser" && limit == 20 { return [manga(id: "chooser-a", title: title, malId: 1300)] }
        if title == "Fixture Single Exact" && limit == 20 { return [manga(id: "single-exact", title: title, malId: 1500)] }
        return []
    }

    func mangaDetail(id: String) async throws -> MangaDetail { .init(description: "", authors: [], tags: [], contentRating: nil) }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    func manga(id: String) async throws -> Manga? { nil }
    /// The parent has seven chapters so its detail page exposes Show all; every other
    /// fixture title keeps the three-chapter count used by existing chooser assertions.
    func chapters(mangaId: String) async throws -> [Chapter] {
        let numbers = mangaId == "hub-fixture-title" ? ["1", "2", "3", "4", "5", "6", "7"] : ["1", "2", "3"]
        return numbers.map { Chapter(id: "\(mangaId)-\($0)", number: $0, title: nil) }
    }

    private func manga(id: String, title: String, malId: Int?) -> Manga {
        Manga(id: id, sourceId: self.id, title: title, description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: malId)
    }
}

private struct MALHubFixtureSourceB: MangaSource {
    let id = "mal-hub-fixture-b"
    let name = "Fixture Source B"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        if title == "Fixture Chooser" {
            return [Manga(id: "chooser-b", sourceId: id, title: "Fixture Chooser",
                          description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil,
                          altTitles: ["Fixture Chooser Alternate"])]
        }
        return []
    }
    func mangaDetail(id: String) async throws -> MangaDetail { .init(description: "", authors: [], tags: [], contentRating: nil) }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

private struct MALHubFixtureSourceC: MangaSource {
    let id = "mal-hub-fixture-c"
    let name = "Fixture Source C"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        if title == "Fixture Chooser" {
            return [Manga(id: "chooser-c", sourceId: id, title: title, description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: 1300)]
        }
        return []
    }
    func mangaDetail(id: String) async throws -> MangaDetail { .init(description: "", authors: [], tags: [], contentRating: nil) }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    /// Throws, so this choice's count stays unknown — shown as "Chapter count unknown", never 0.
    func chapters(mangaId: String) async throws -> [Chapter] { throw SourceError.unavailable("fixture chapters") }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

private struct MALHubFixtureSourceD: MangaSource {
    let id = "mal-hub-fixture-d"
    let name = "Fixture Source D"

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        if title == "Fixture Chooser" { throw SourceError.unavailable("fixture search") }
        return []
    }
    func mangaDetail(id: String) async throws -> MangaDetail { .init(description: "", authors: [], tags: [], contentRating: nil) }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
/// Puts the real Cloudflare challenge wait on screen when the reader searches for
/// "Fixture Challenge", with no site behind it. The sheet's Cancel fails the wait, so this
/// Source then shows "Couldn't check" while the others' results stand (design §5).
private struct MALHubFixtureSourceE: MangaSource {
    let id = "mal-hub-fixture-e"
    let name = "Fixture Source E"

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        if title == "Fixture Challenge" && limit == 20 {
            try await WebViewService.shared.uiTestAwaitChallenge()
        }
        return []
    }
    func mangaDetail(id: String) async throws -> MangaDetail { .init(description: "", authors: [], tags: [], contentRating: nil) }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}
#endif
