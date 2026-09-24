import Testing
@testable import MangaCarta

@Suite("LocalSourceTests")
struct LocalSourceTests {
    @Test func unsupportedFeedsThrow() async {
        let source = LocalSource()
        await #expect(throws: SourceError.self) { try await source.popular(limit: 1, offset: 0) }
        await #expect(throws: SourceError.self) { try await source.newTitles(limit: 1, offset: 0) }
        await #expect(throws: SourceError.self) { try await source.latestUpdates(limitTitles: 1, language: "en", offset: 0) }
    }

    @Test func deletedItemFailsAsMissing() async {
        let source = LocalSource()
        await #expect(throws: SourceError.self) { try await source.chapters(mangaId: "deleted") }
    }
}
