import Foundation
import Testing
@testable import MangaCarta

@Suite("LocalChapterLayoutTests")
struct LocalChapterLayoutTests {
    private func chapters(_ names: [String]) throws -> [ZipArchiveReader.Chapter] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("shape.cbz")
        try LocalTestZip.write(names.map { ($0, LocalTestZip.png) }, to: archive)
        return try ZipArchiveReader(url: archive).chapters()
    }

    @Test func twoTopLevelFoldersYieldTwoChapters() throws {
        let result = LocalChapterLayout.normalize(try chapters(["Ch 10/001.png", "Ch 2/001.png"]))
        #expect(result.map(\.title) == ["Ch 2", "Ch 10"])
    }

    @Test func singleWrapperFolderYieldsOneChapter() throws {
        let result = LocalChapterLayout.normalize(try chapters(["Title/001.png", "Title/002.png"]), itemTitle: "Title")
        #expect(result.count == 1)
        #expect(result[0].pageCount == 2)
    }

    @Test func rootImagesBesideSingleFolderFormLeadingChapter() throws {
        let result = LocalChapterLayout.normalize(try chapters(["cover.png", "Title/001.png", "Title/002.png"]), itemTitle: "Title")
        #expect(result.map(\.title) == ["Root", "Title"])
        #expect(result.map(\.pageCount) == [1, 2])
    }

    @Test func rootImagesBesideFoldersFormLeadingChapter() throws {
        let result = LocalChapterLayout.normalize(try chapters(["cover.png", "A/001.png", "B/001.png"]), itemTitle: "Book")
        #expect(result.map(\.title) == ["Root", "A", "B"])
    }

    @Test func deeperNestingIsFlattenedInPathOrder() throws {
        let result = LocalChapterLayout.normalize(try chapters(["A/x/1.png", "A/y/1.png", "B/1.png"]), itemTitle: "Book")
        #expect(result[0].title == "A")
        #expect(result[0].pageCount == 2)
        #expect(result[0].pageFiles == ["1.png", "1.png"])
    }
}
