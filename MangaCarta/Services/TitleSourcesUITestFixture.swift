#if DEBUG
import Foundation

enum TitleSourcesUITestFixture {
    struct Storage {
        let defaults: UserDefaults
        let directory: URL
        let entityStore: EntityResolutionStore
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-title-sources")
    }

    @MainActor static func storage() -> Storage {
        let id = ProcessInfo.processInfo.environment["MANGACARTA_UI_TEST_STORAGE_ID"] ?? UUID().uuidString
        let suite = "title-sources-ui-test.\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaCarta-TitleSourcesUITest-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let entityStore = EntityResolutionStore(defaults: defaults)
        entityStore.record(sourceId: "title-sources-fixture-a", mangaId: "fixture-a-title",
                           .resolved(malId: 7001))
        return Storage(defaults: defaults, directory: directory, entityStore: entityStore)
    }

    @MainActor static func registry(defaults: UserDefaults) -> SourceRegistry {
        SourceRegistry(sources: [source(.a), source(.b), source(.c), source(.d)], defaults: defaults)
    }

    @MainActor static func seed(_ composition: AppComposition) {
        let a = manga(id: "fixture-a-title", source: .a, title: "Fixture Title", malId: 7001)
        let b = manga(id: "fixture-b-title", source: .b, title: "Fixture Title", malId: 7001)
        composition.library.toggle(a)
        let work = composition.works.workId(for: ListingKey(a)) ?? composition.works.mint(from: a)
        _ = composition.works.addListing(b, to: work, recordExternalIds: true)
    }

    static func fetchDetail(_ id: Int) async throws -> MyAnimeListMangaDetail {
        MyAnimeListMangaDetail(id: id, title: "Fixture Title", synopsis: "A fixed title-sources fixture.",
                               mainPicture: nil, genres: [], relatedManga: [], recommendations: [],
                               nsfw: .white, alternativeTitles: .init(synonyms: [], en: nil, ja: nil))
    }

    fileprivate enum Role { case a, b, c, d }

    private static func source(_ role: Role) -> TitleSourcesFixtureSource {
        let name: String
        switch role {
        case .a: name = "Source A"
        case .b: name = "Source B"
        case .c: name = "Source C"
        case .d: name = "Source D"
        }
        return TitleSourcesFixtureSource(role: role, id: "title-sources-fixture-\(role.id)", name: name)
    }

    private static func manga(id: String, source role: Role, title: String, malId: Int?) -> Manga {
        Manga(id: id, sourceId: "title-sources-fixture-\(role.id)", title: title, description: "",
              status: "ongoing", year: 2026, coverURL: nil, malId: malId)
    }
}

fileprivate extension TitleSourcesUITestFixture.Role {
    var id: String {
        switch self {
        case .a: return "a"
        case .b: return "b"
        case .c: return "c"
        case .d: return "d"
        }
    }
}

private struct TitleSourcesFixtureSource: MangaSource {
    let role: TitleSourcesUITestFixture.Role
    let id: String
    let name: String
    let publishesExternalIds = true

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        switch role {
        case .c where title == "Fixture Title":
            return [manga(id: "fixture-c-same", title: "Fixture Title", malId: 7001),
                    manga(id: "fixture-c-unrelated", title: "Something Else", malId: nil)]
        case .d where title == "Fixture Title":
            return [manga(id: "fixture-d-different", title: "Fixture Title (Novel)", malId: 7999)]
        default: return []
        }
    }

    func mangaDetail(id: String) async throws -> MangaDetail {
        .init(description: "", authors: [], tags: [], contentRating: nil)
    }

    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    func chapters(mangaId: String) async throws -> [Chapter] {
        let count: Int
        switch role {
        case .a: count = 12
        case .b: count = 10
        case .c: count = 14
        case .d: count = 0
        }
        guard count > 0 else { return [] }
        return (1...count).map { Chapter(id: "\(mangaId)-\($0)", number: String($0), title: nil) }
    }

    private func manga(id: String, title: String, malId: Int?) -> Manga {
        Manga(id: id, sourceId: self.id, title: title, description: "", status: "ongoing",
              year: 2026, coverURL: nil, malId: malId)
    }
}
#endif
