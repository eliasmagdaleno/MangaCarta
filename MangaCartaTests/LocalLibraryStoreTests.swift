import Testing
import Foundation
@testable import MangaCarta

@Suite("LocalLibraryStoreTests")
struct LocalLibraryStoreTests {
    private func archive(root: URL, files: [(String, Data)], corruptLastCRC: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("book.cbz")
        try LocalTestZip.write(files, to: url, corruptLastCRC: corruptLastCRC)
        return url
    }

    private func itemDirectories(at root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent != ".staging" } ?? []
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
