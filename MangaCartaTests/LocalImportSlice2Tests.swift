import Foundation
import Testing
import UIKit
@testable import MangaCarta

private enum LocalTestZip {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    static func write(_ files: [(String, Data)], to url: URL) throws {
        var body = Data(); var central = Data(); var offset: UInt32 = 0
        for (name, data) in files {
            let n = Data(name.utf8), crc = checksum(data)
            body.append(u32(0x04034b50)); body.append(u16(20)); body.append(u16(0)); body.append(u16(0)); body.append(u16(0)); body.append(u16(0)); body.append(u32(crc)); body.append(u32(UInt32(data.count))); body.append(u32(UInt32(data.count))); body.append(u16(UInt16(n.count))); body.append(u16(0)); body.append(n); body.append(data)
            central.append(u32(0x02014b50)); central.append(u16(20)); central.append(u16(20)); central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u32(crc)); central.append(u32(UInt32(data.count))); central.append(u32(UInt32(data.count))); central.append(u16(UInt16(n.count))); central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u32(0)); central.append(u32(offset)); central.append(n)
            offset = UInt32(body.count)
        }
        let start = UInt32(body.count); body.append(central); body.append(u32(0x06054b50)); body.append(u16(0)); body.append(u16(0)); body.append(u16(UInt16(files.count))); body.append(u16(UInt16(files.count))); body.append(u32(UInt32(central.count))); body.append(u32(start)); body.append(u16(0)); try body.write(to: url)
    }
    private static func u16(_ x: UInt16) -> Data { Data([UInt8(x & 255), UInt8(x >> 8)]) }
    private static func u32(_ x: UInt32) -> Data { Data([UInt8(x & 255), UInt8((x >> 8) & 255), UInt8((x >> 16) & 255), UInt8(x >> 24)]) }
    private static func checksum(_ data: Data) -> UInt32 { var c: UInt32 = 0xffff_ffff; for b in data { c ^= UInt32(b); for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xedb8_8320 : c >> 1 } }; return c ^ 0xffff_ffff }
}

private struct LocalFixture {
    let root: URL
    let archive: URL
    init(files: [(String, Data)] = [("001.png", LocalTestZip.png), ("002.png", LocalTestZip.png)]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        archive = root.appendingPathComponent("book.cbz")
        try LocalTestZip.write(files, to: archive)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func localImportWritesRealPagesAndRecord() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let result = try await store.importArchive(at: fixture.archive)
    guard case .imported(let record) = result else { Issue.record("expected import"); return }
    #expect(record.chapters.first?.pageCount == 2)
    #expect(await store.pageURLs(itemId: record.itemId, chapter: 1).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(await store.coverURL(itemId: record.itemId) != nil)
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
}

@Test func localImportDeduplicatesAndDeleteReimportsStableId() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    guard case .imported(let first) = try await store.importArchive(at: fixture.archive) else { Issue.record("first import"); return }
    guard case .duplicate(let duplicate) = try await store.importArchive(at: fixture.archive) else { Issue.record("duplicate"); return }
    #expect(duplicate == first.itemId)
    try await store.delete(itemId: first.itemId)
    guard case .imported(let second) = try await store.importArchive(at: fixture.archive) else { Issue.record("reimport"); return }
    #expect(second.itemId == first.itemId)
}

@Test func localSourceReadsFileURLsAndFiltersTitles() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    _ = try await store.importArchive(at: fixture.archive)
    let source = LocalSource(store: store)
    let results = try await source.search(title: "book", limit: 10, offset: 0)
    #expect(results.count == 1)
    let chapters = try await source.chapters(mangaId: results[0].id)
    let pages = try await source.pageURLs(chapterId: chapters[0].id, preferDataSaver: false)
    #expect(pages.allSatisfy { $0.isFileURL })
    #expect(results[0].sourceId == LocalSource.sourceID)
}

@Test func localSourceCapabilitiesDispatchThroughExistential() {
    let source: any MangaSource = LocalSource()
    #expect(source.isBrowsable == false)
    #expect(source.participatesInUpdates == false)
}

@MainActor @Test func registryAlwaysRegistersLocalButNeverBrowsesIt() {
    let registry = SourceRegistry(sources: [LocalSource(), MangaDexSource()])
    #expect(registry.source(id: "local") != nil)
    #expect(!registry.visibleSources(includeAdult: true).contains { $0.id == "local" })
    #expect(registry.active?.id == MangaDexSource.sourceID)
}

@Suite("LocalImportSlice2Tests")
struct LocalImportSlice2Tests {
    @Test func importWritesRealPagesAndRecord() async throws { try await localImportWritesRealPagesAndRecord() }
    @Test func deduplicatesAndReimportsStableId() async throws { try await localImportDeduplicatesAndDeleteReimportsStableId() }
    @Test func sourceReadsFileURLsAndFiltersTitles() async throws { try await localSourceReadsFileURLsAndFiltersTitles() }
    @Test func capabilitiesDispatchThroughExistential() { localSourceCapabilitiesDispatchThroughExistential() }
    @MainActor @Test func registryFiltersLocal() { registryAlwaysRegistersLocalButNeverBrowsesIt() }
}
