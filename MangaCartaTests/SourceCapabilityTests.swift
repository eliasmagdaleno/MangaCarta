import Foundation
import Testing
@testable import MangaCarta

private struct CapabilitySource: MangaSource {
    let id = "capability"
    let name = "Capability"
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail { MangaDetail(description: "", authors: [], tags: [], contentRating: nil) }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

@Suite("SourceCapabilityTests")
struct SourceCapabilityTests {
    @Test func defaultsAreTrueThroughExistential() {
        let source: any MangaSource = CapabilitySource()
        #expect(source.isBrowsable)
        #expect(source.participatesInUpdates)
    }

    @Test func overrideIsReachedThroughExistential() {
        let source: any MangaSource = LocalSource()
        #expect(source.isBrowsable == false)
        #expect(source.participatesInUpdates == false)
    }
}
