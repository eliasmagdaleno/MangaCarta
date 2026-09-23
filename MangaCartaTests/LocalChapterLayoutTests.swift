import Testing
@testable import MangaCarta

@Suite("LocalChapterLayoutTests")
struct LocalChapterLayoutTests {
    @Test func emptyArchiveHasNoChapters() {
        #expect(LocalChapterLayout.normalize([]).isEmpty)
    }
}
