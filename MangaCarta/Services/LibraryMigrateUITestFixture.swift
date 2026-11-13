#if DEBUG
import Foundation

enum LibraryMigrateUITestFixture {
    private static let prefix = "library-migrate-fixture-"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-library-migrate")
    }

    static var isSlowSearch: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-library-migrate-slow")
    }

    @MainActor static func storage() -> (defaults: UserDefaults, directory: URL) {
        let id = ProcessInfo.processInfo.environment["MANGACARTA_UI_TEST_STORAGE_ID"] ?? UUID().uuidString
        let suite = "\(prefix)\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaCarta-LibraryMigrateUITest-\(id)", isDirectory: true)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        return (defaults, directory)
    }

    @MainActor static func registry(defaults: UserDefaults) -> SourceRegistry {
        SourceRegistry(sources: [FixtureSource(role: .a), FixtureSource(role: .b), FixtureSource(role: .c)],
                       defaults: defaults)
    }

    @MainActor static func seed(_ composition: AppComposition) {
        let titles = ["Same Entry Title", "Likely Title", "Ambiguous Title", "Missing Title", "Already Title"]
        for (index, title) in titles.enumerated() {
            let malId = 9100 + index
            let a = manga(title: title, source: .a, malId: malId)
            if composition.library.item(for: ListingKey(a)) == nil { composition.library.toggle(a) }
            let workId = composition.works.workId(for: ListingKey(a)) ?? composition.works.mint(from: a)
            let b = manga(title: title, source: .b, malId: malId)
            if title == "Already Title" {
                _ = composition.works.addListing(b, to: workId, recordExternalIds: true)
            }
            if title == "Same Entry Title" {
                let chapter = Chapter(id: "fixture-same-a-1", number: "1", title: nil)
                composition.history.record(manga: a, chapter: chapter,
                                           position: ReadingPosition(page: 9, fraction: 0), pageCount: 10)
            }
        }
    }

    private enum Role: String { case a, b, c }

    private static func manga(title: String, source role: Role, malId: Int?) -> Manga {
        Manga(id: role == .a ? "a-\(slug(title))" : "b-\(slug(title))", sourceId: "library-migrate-\(role.rawValue)",
              title: title, description: "", status: "ongoing", year: 2026, coverURL: nil,
              malId: malId, altTitles: nil, contentRating: nil)
    }

    private static func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private struct FixtureSource: MangaSource {
        let role: Role
        var id: String { "library-migrate-\(role.rawValue)" }
        var name: String { "Source \(role.rawValue.uppercased())" }
        var publishesExternalIds: Bool { true }

        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
            guard role == .b else { return [] }
            if LibraryMigrateUITestFixture.isSlowSearch {
                try await Task.sleep(for: .seconds(30))
            }
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "same entry title":
                return [result("Same Entry Title", malId: 9100, suffix: "same")]
            case "likely title":
                return [result("Likely Title", malId: nil, suffix: "likely")]
            case "ambiguous title":
                return [result("Ambiguous Title One", malId: 9102, suffix: "ambiguous-one"),
                        result("Ambiguous Title Two", malId: 9102, suffix: "ambiguous-two")]
            default: return []
            }
        }

        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }

        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }

        func chapters(mangaId: String) async throws -> [Chapter] {
            (1...3).map { Chapter(id: "\(mangaId)-\($0)", number: String($0), title: nil) }
        }

        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }

        private func result(_ title: String, malId: Int?, suffix: String) -> Manga {
            Manga(id: "b-\(suffix)", sourceId: id, title: title, description: "", status: "ongoing",
                  year: 2026, coverURL: nil, malId: malId)
        }
    }
}
#endif
