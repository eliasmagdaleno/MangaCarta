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

        var adult: Bool {
            switch self {
            case .adultOn: return true
            case .adultOff: return false
            }
        }
    }

    static var state: State? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uitest-mal-hub") { return .adultOn }
        if arguments.contains("-uitest-mal-hub-adult-off") { return .adultOff }
        return nil
    }

    static var opensDetail: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-mal-hub-open-detail")
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
        return Storage(defaults: defaults, directory: directory, detailStore: detailStore,
                       choiceStore: choiceStore, entityStore: entityStore)
    }

    @MainActor static func registry(state: State, defaults: UserDefaults) -> SourceRegistry {
        SourceRegistry(sources: [MALHubFixtureSourceA(), MALHubFixtureSourceB(), MALHubFixtureSourceC(), MALHubFixtureSourceD()],
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
                recommendation(id: 1500, title: "Fixture Single Exact", weight: 5)
            ])
        }
        let titles = [1200: "Fixture Resolved", 1300: "Fixture Chooser", 1400: "Fixture Nowhere",
                      1500: "Fixture Single Exact", 1100: "Fixture Related"]
        let title = titles[id] ?? "Fixture"
        return detail(id: id, title: title, related: [], recommendations: [])
    }

    @MainActor
    static func seed(_ composition: AppComposition) -> WorkID {
        let manga = Manga(id: "hub-fixture-title", sourceId: MALHubFixtureSourceA.idValue,
                          title: "Hub Fixture Title", description: "", status: "ongoing",
                          year: 2026, coverURL: nil, malId: 1000)
        composition.library.toggle(manga)
        return composition.works.mint(from: manga)
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
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    func manga(id: String) async throws -> Manga? { nil }

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
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
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
#endif
