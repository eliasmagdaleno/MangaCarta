import Testing
import Foundation
import UIKit
@testable import MangaCarta

@Suite("LocalLibraryStoreTests")
struct LocalLibraryStoreTests {
    @Test func localLibraryPathsRelocateCoverURLs() {
        let root = URL(fileURLWithPath: "/new-container/Library/Application Support/LocalLibrary")
        let stale = URL(fileURLWithPath: "/old-container/Library/Application Support/LocalLibrary/item-1/cover.jpg")
        let expected = root.appendingPathComponent("item-1/cover.jpg")
        #expect(LocalLibraryPaths.relocated(stale, root: root) == expected)
        #expect(LocalLibraryPaths.relocated(expected, root: root) == expected)

        let remote = URL(string: "https://example.com/cover.jpg")!
        #expect(LocalLibraryPaths.relocated(remote, root: root) == remote)
        let unrelated = URL(fileURLWithPath: "/old-container/Library/item-1/cover.jpg")
        #expect(LocalLibraryPaths.relocated(unrelated, root: root) == unrelated)
        let rootOnly = URL(fileURLWithPath: "/old-container/Library/LocalLibrary")
        #expect(LocalLibraryPaths.relocated(rootOnly, root: root) == rootOnly)
        #expect(LocalLibraryPaths.relocated(nil, root: root) == nil)

        let spaced = URL(fileURLWithPath: "/old-container/Library/Application Support/LocalLibrary/item 1/cover.jpg")
        #expect(LocalLibraryPaths.relocated(spaced, root: root) == root.appendingPathComponent("item 1/cover.jpg"))
    }

    @Test func libraryItemDecodeRelocatesLocalCoverButKeepsRemoteCover() throws {
        let stale = "file:///old-container/Library/Application%20Support/LocalLibrary/item-1/cover.jpg"
        let localJSON = Data("{\"id\":\"item-1\",\"title\":\"Title\",\"coverURL\":\"\(stale)\"}".utf8)
        let localItem = try JSONDecoder().decode(LibraryItem.self, from: localJSON)
        #expect(localItem.coverURL == LocalLibraryPaths.defaultRoot.appendingPathComponent("item-1/cover.jpg"))

        let remoteJSON = Data("{\"id\":\"item-2\",\"title\":\"Title\",\"coverURL\":\"https://example.com/cover.jpg\"}".utf8)
        let remoteItem = try JSONDecoder().decode(LibraryItem.self, from: remoteJSON)
        #expect(remoteItem.coverURL == URL(string: "https://example.com/cover.jpg"))
    }

    @Test func readingEntryDecodeRelocatesLocalCoverButKeepsRemoteCover() throws {
        let fields = "\"id\":\"00000000-0000-0000-0000-000000000000\",\"mangaId\":\"m\",\"mangaTitle\":\"T\","
            + "\"chapterId\":\"c\",\"chapterNumber\":\"1\",\"page\":0,\"pageCount\":1,\"updatedAt\":0"
        let stale = "file:///old-container/Library/Application%20Support/LocalLibrary/item-1/cover.jpg"
        let localJSON = Data("{\(fields),\"coverURL\":\"\(stale)\"}".utf8)
        let localEntry = try JSONDecoder().decode(ReadingEntry.self, from: localJSON)
        #expect(localEntry.coverURL == LocalLibraryPaths.defaultRoot.appendingPathComponent("item-1/cover.jpg"))

        let remoteJSON = Data("{\(fields),\"coverURL\":\"https://example.com/cover.jpg\"}".utf8)
        let remoteEntry = try JSONDecoder().decode(ReadingEntry.self, from: remoteJSON)
        #expect(remoteEntry.coverURL == URL(string: "https://example.com/cover.jpg"))
    }

    private func archive(root: URL, files: [(String, Data)], corruptLastCRC: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("book.cbz")
        try LocalTestZip.write(files, to: url, corruptLastCRC: corruptLastCRC)
        return url
    }

    private func itemDirectories(at root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent != ".staging" } ?? []
    }

    private func image(width: Int, height: Int, color: UIColor = .red) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func chapterLabelsFollowComicInfoRules() {
        let full = ComicInfo(series: nil, title: "Issue", number: "2", volume: "1", summary: nil,
                             writer: nil, genres: [], frontCoverPageIndex: nil)
        #expect(LocalLibraryStore.chapterLabel(for: full, fallback: "Fallback") == "Vol. 1 · Ch. 2")
        let numberOnly = ComicInfo(series: nil, title: nil, number: "2", volume: nil, summary: nil,
                                   writer: nil, genres: [], frontCoverPageIndex: nil)
        let volumeOnly = ComicInfo(series: nil, title: nil, number: nil, volume: "1", summary: nil,
                                   writer: nil, genres: [], frontCoverPageIndex: nil)
        let titleOnly = ComicInfo(series: nil, title: "Issue", number: nil, volume: nil, summary: nil,
                                  writer: nil, genres: [], frontCoverPageIndex: nil)
        #expect(LocalLibraryStore.chapterLabel(for: numberOnly, fallback: "Fallback") == "Ch. 2")
        #expect(LocalLibraryStore.chapterLabel(for: volumeOnly, fallback: "Fallback") == "Vol. 1")
        #expect(LocalLibraryStore.chapterLabel(for: titleOnly, fallback: "Fallback") == "Issue")
        #expect(LocalLibraryStore.chapterLabel(for: nil, fallback: "Fallback") == "Fallback")
        #expect(LocalLibraryStore.chapterLabel(for: full, fallback: "Fallback", isSingleChapter: false) == "Fallback")
    }

    @Test func frontCoverIndexSelectsTheIndexedPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xml = Data("<ComicInfo><Series>Series</Series><Pages><Page Image=\"2\" Type=\"FrontCover\"/></Pages></ComicInfo>".utf8)
        let files = [("001.png", image(width: 1, height: 2)), ("002.png", image(width: 3, height: 4)),
                     ("003.png", image(width: 5, height: 6)), ("ComicInfo.xml", xml)]
        let url = try archive(root: root, files: files)
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await store.importArchive(at: url),
              let cover = await store.coverURL(itemId: record.itemId),
              let coverImage = UIImage(contentsOfFile: cover.path) else {
            Issue.record("expected cover")
            return
        }
        #expect(coverImage.size == CGSize(width: 15, height: 18))
    }

    @Test func nestedComicInfoIsIgnoredAndFilenameTitleRemains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nestedInfo = Data("<ComicInfo><Series>Wrong</Series></ComicInfo>".utf8)
        let url = try archive(root: root, files: [("nested/ComicInfo.xml", nestedInfo), ("001.png", LocalTestZip.png)])
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await store.importArchive(at: url) else { Issue.record("expected import"); return }
        #expect(record.title == "book")
        #expect(record.comicInfo == nil)
    }

    @Test func malformedComicInfoStillImportsWithFilenameTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try archive(root: root, files: [("ComicInfo.xml", Data("<ComicInfo>".utf8)), ("001.png", LocalTestZip.png)])
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await store.importArchive(at: url) else { Issue.record("expected import"); return }
        #expect(record.title == "book")
        #expect(record.comicInfo == nil)
    }

    @Test func seriesWinsTitleAndTitleWinsWhenSeriesMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seriesXML = Data("<ComicInfo><Series>Series Name</Series><Title>Issue Title</Title></ComicInfo>".utf8)
        let titleXML = Data("<ComicInfo><Title>Issue Title</Title></ComicInfo>".utf8)
        let seriesURL = root.appendingPathComponent("series.cbz")
        let titleURL = root.appendingPathComponent("title.cbz")
        try LocalTestZip.write([("001.png", LocalTestZip.png), ("ComicInfo.xml", seriesXML)], to: seriesURL)
        try LocalTestZip.write([("001.png", LocalTestZip.png), ("ComicInfo.xml", titleXML)], to: titleURL)
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let series) = try await store.importArchive(at: seriesURL),
              case .imported(let title) = try await store.importArchive(at: titleURL) else {
            Issue.record("expected imports")
            return
        }
        #expect(series.title == "Series Name")
        #expect(title.title == "Issue Title")
    }

    @Test func legacyItemJSONWithoutComicInfoDecodes() throws {
        let data = Data("""
        {"itemId":"id","title":"Title","sourceFilename":"book.cbz","sha256":"hash","byteSize":1,"importedAt":0,"chapters":[]}
        """.utf8)
        let record = try JSONDecoder().decode(LocalItemRecord.self, from: data)
        #expect(record.comicInfo == nil)
    }

    @Test func coverPageHelperFallsBackWhenIndexIsInvalid() {
        let first = URL(fileURLWithPath: "/first"), second = URL(fileURLWithPath: "/second")
        #expect(LocalLibraryStore.coverPage(pageURLs: [first, second], frontCoverPageIndex: 8,
                                            isDecodable: { $0 == second }) == second)
        #expect(LocalLibraryStore.coverPage(pageURLs: [first, second], frontCoverPageIndex: 1,
                                            isDecodable: { $0 == second }) == second)
    }

    @Test func duplicateImportIsSkippedAndRecordRemainsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try archive(root: root, files: [("001.png", LocalTestZip.png)])
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await store.importArchive(at: url) else { Issue.record("first import"); return }
        guard case .duplicate(let duplicate) = try await store.importArchive(at: url) else { Issue.record("duplicate"); return }
        #expect(duplicate == record.itemId)
        #expect(itemDirectories(at: root.appendingPathComponent("library")).count == 1)
    }

    @Test func invalidFirstPageFallsBackToNextDecodableCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidPNG = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0])
        let url = try archive(root: root, files: [("001.png", invalidPNG), ("002.png", LocalTestZip.png)])
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))

        guard case .imported(let record) = try await store.importArchive(at: url) else {
            Issue.record("expected import")
            return
        }
        #expect(await store.coverURL(itemId: record.itemId) != nil)
    }

    @Test func pagesWithoutDecodableCoverStillImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidPNG = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0])
        let url = try archive(root: root, files: [("001.png", invalidPNG)])
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))

        guard case .imported(let record) = try await store.importArchive(at: url) else {
            Issue.record("expected import")
            return
        }
        #expect(record.chapters.first?.pageCount == 1)
        #expect(await store.coverURL(itemId: record.itemId) == nil)
        #expect(await store.pageURLs(itemId: record.itemId, chapter: 1).count == 1)
    }

    @Test func itemSizeReportsExtractedDirectoryBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try archive(root: root, files: [("001.png", LocalTestZip.png), ("002.png", LocalTestZip.png)])
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await store.importArchive(at: url) else {
            Issue.record("expected import")
            return
        }
        let itemURL = root.appendingPathComponent("library").appendingPathComponent(record.itemId)
        let recordBytes = try Data(contentsOf: itemURL.appendingPathComponent("item.json")).count
        let coverBytes = try Data(contentsOf: itemURL.appendingPathComponent("cover.jpg")).count
        let expected = 2 * LocalTestZip.png.count + recordBytes + coverBytes
        #expect(await store.itemSize(itemId: record.itemId) == expected)
        let usage = await store.usage()
        #expect(usage.count == 1)
        #expect(usage.bytes == expected)
    }

    @Test func cancellingArchiveImportRemovesStagingAndDoesNotCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try archive(root: root, files: [("001.png", LocalTestZip.png), ("002.png", LocalTestZip.png)])
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)

        await #expect(throws: LocalImportError.cancelled) {
            try await Task {
                try await store.importArchive(at: url) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }.value
        }
        #expect(await store.allRecords().isEmpty)
        let staging = library.appendingPathComponent(".staging")
        #expect(try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func failedExtractionLeavesNoItemAndEmptyStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = try archive(root: root, files: [("001.png", LocalTestZip.png), ("002.png", LocalTestZip.png)], corruptLastCRC: true)
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)
        await #expect(throws: Error.self) { try await store.importArchive(at: corrupt) }
        #expect(itemDirectories(at: library).isEmpty)
        let staging = library.appendingPathComponent(".staging")
        let stagingIsEmpty = try? FileManager.default
            .contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).isEmpty
        #expect(stagingIsEmpty == true)

        let zero = try archive(root: root, files: [("ComicInfo.xml", Data("<ComicInfo/>".utf8)), (".DS_Store", Data([1]))])
        await #expect(throws: LocalImportError.noImages) { try await store.importArchive(at: zero) }
        #expect(itemDirectories(at: library).isEmpty)
    }

    @Test func stagingIsNeverListedAndCrashStagingIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stray = root.appendingPathComponent(".staging/old/item")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stray.appendingPathComponent("item.json"))
        let store = LocalLibraryStore(root: root)
        #expect(await store.allRecords().isEmpty)
    }

    @Test func deletingUnknownItemThrows() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalLibraryStore(root: root)
        await #expect(throws: Error.self) { try await store.delete(itemId: "missing") }
    }

    @Test func deleteRemovesItemAndReimportKeepsItemId() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try archive(root: root, files: [("001.png", LocalTestZip.png)])
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)
        guard case .imported(let first) = try await store.importArchive(at: url) else { Issue.record("first import"); return }
        try await store.delete(itemId: first.itemId)
        #expect(await store.record(itemId: first.itemId) == nil)
        guard case .imported(let second) = try await store.importArchive(at: url) else { Issue.record("reimport"); return }
        #expect(second.itemId == first.itemId)
    }
}
