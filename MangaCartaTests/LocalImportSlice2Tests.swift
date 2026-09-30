import Foundation
import Testing
import UIKit
@testable import MangaCarta

enum LocalTestZip {
    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    static func write(_ files: [(String, Data)], to url: URL, corruptLastCRC: Bool = false) throws {
        var body = Data(); var central = Data(); var offset: UInt32 = 0
        for (index, pair) in files.enumerated() {
            let (name, data) = pair
            let n = Data(name.utf8), crc = checksum(data)
            body.append(u32(0x04034b50)); body.append(u16(20)); body.append(u16(0))
            body.append(u16(0)); body.append(u16(0)); body.append(u16(0)); body.append(u32(crc))
            body.append(u32(UInt32(data.count))); body.append(u32(UInt32(data.count)))
            body.append(u16(UInt16(n.count))); body.append(u16(0)); body.append(n); body.append(data)
            central.append(u32(0x02014b50)); central.append(u16(20)); central.append(u16(20))
            central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u16(0))
            central.append(u32(corruptLastCRC && index == files.count - 1 ? crc ^ 1 : crc))
            central.append(u32(UInt32(data.count)))
            central.append(u32(UInt32(data.count))); central.append(u16(UInt16(n.count))); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0)); central.append(u16(0))
            central.append(u32(0)); central.append(u32(offset)); central.append(n)
            offset = UInt32(body.count)
        }
        let start = UInt32(body.count)
        body.append(central); body.append(u32(0x06054b50)); body.append(u16(0)); body.append(u16(0))
        body.append(u16(UInt16(files.count))); body.append(u16(UInt16(files.count)))
        body.append(u32(UInt32(central.count))); body.append(u32(start)); body.append(u16(0))
        try body.write(to: url)
    }
    private static func u16(_ x: UInt16) -> Data {
        Data([UInt8(x & 255), UInt8(x >> 8)])
    }

    private static func u32(_ x: UInt32) -> Data {
        Data([UInt8(x & 255), UInt8((x >> 8) & 255), UInt8((x >> 16) & 255), UInt8(x >> 24)])
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in data {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xedb8_8320 : c >> 1 }
        }
        return c ^ 0xffff_ffff
    }
}

private struct LocalFixture {
    let root: URL
    let archive: URL
    init(files: [(String, Data)] = [("001.png", LocalTestZip.png), ("002.png", LocalTestZip.png)]) throws {
        root = TestDirectory("LocalImportSlice2Tests").url
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        archive = root.appendingPathComponent("book.cbz")
        try LocalTestZip.write(files, to: archive)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func writeSeriesArchive(in root: URL, name: String, series: String?, volume: String? = nil,
                                number: String? = nil, files: [(String, Data)] = [("001.png", LocalTestZip.png)]) throws -> URL {
    let archive = root.appendingPathComponent(name)
    var entries = files
    if let series {
        let volumeXML = volume.map { "<Volume>\($0)</Volume>" } ?? ""
        let numberXML = number.map { "<Number>\($0)</Number>" } ?? ""
        let xml = "<ComicInfo><Series>\(series)</Series>\(volumeXML)\(numberXML)</ComicInfo>"
        entries.append(("ComicInfo.xml", Data(xml.utf8)))
    }
    try LocalTestZip.write(entries, to: archive)
    return archive
}

@MainActor
private func localImporter(root: URL, store: LocalLibraryStore,
                           suite: TestDefaults) -> (LocalImportViewModel, LibraryStore, WorkStore) {
    let works = WorkStore(directory: root.appendingPathComponent("works"))
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel()
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))
    return (importer, library, works)
}

@MainActor @Test func localImportGroupsSeriesAcrossBatchesAndKeepsStandaloneItemsSeparate() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let v1 = try writeSeriesArchive(in: fixture.root, name: "v1.cbz", series: " Saga ", volume: "1", number: "1")
    let v2 = try writeSeriesArchive(in: fixture.root, name: "v2.cbz", series: "saga", volume: "2", number: "2")
    let v3 = try writeSeriesArchive(in: fixture.root, name: "v3.cbz", series: "SAGA", volume: "3", number: "3")
    let standalone = try writeSeriesArchive(in: fixture.root, name: "standalone.cbz", series: nil)
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let suite = TestDefaults("local-import-slice6")
    defer { suite.remove() }
    let (importer, library, works) = localImporter(root: fixture.root, store: store, suite: suite)

    await importer.importFilesAndWait([v1, v2])
    await importer.importFilesAndWait([v3, standalone])

    let seriesID = LocalSeriesIdentity.seriesID(for: "saga")
    #expect(library.items.count == 2)
    #expect(library.item(for: seriesID) != nil)
    #expect(works.workId(for: ListingKey(sourceId: LocalSource.sourceID, mangaId: seriesID)) != nil)
    #expect(works.allWorkIds().count == 2)
    let chapters = try await LocalSource(store: store).chapters(mangaId: seriesID)
    #expect(chapters.map(\.number) == ["1", "2", "3"])
    #expect(chapters.allSatisfy { Double($0.number) != nil })
}

@Test func localSeriesNumbersRemainStableAndResolveCollisions() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let v2 = try writeSeriesArchive(in: fixture.root, name: "volume-2.cbz", series: "Numbers", volume: "2", number: "2")
    let v1 = try writeSeriesArchive(in: fixture.root, name: "volume-1.cbz", series: "Numbers", volume: "1", number: "1")
    let v1b = try writeSeriesArchive(in: fixture.root, name: "volume-1b.cbz", series: "Numbers", volume: "1", number: "1",
                                     files: [("002.png", LocalTestZip.png)])
    let folders = try writeSeriesArchive(in: fixture.root, name: "folders.cbz", series: "Numbers", volume: "3", number: "3",
                                         files: [("a/001.png", LocalTestZip.png), ("b/001.png", LocalTestZip.png)])
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let first = try await store.importArchive(at: v2)
    guard case .imported = first else { Issue.record("first import failed"); return }
    let seriesID = LocalSeriesIdentity.seriesID(for: "numbers")
    #expect(await store.chapters(forMangaID: seriesID).map(\.number) == ["2"])
    _ = try await store.importArchive(at: v1)
    let afterV1 = await store.chapters(forMangaID: seriesID)
    #expect(afterV1.first(where: { $0.record.sourceFilename == "volume-2.cbz" })?.number == "2")
    _ = try await store.importArchive(at: v1b)
    _ = try await store.importArchive(at: folders)
    let numbers = await store.chapters(forMangaID: seriesID).map(\.number)
    #expect(numbers.contains("1.1"))
    #expect(numbers.contains("3.1"))
    #expect(numbers.allSatisfy { Double($0) != nil })
}

@MainActor @Test func localSeriesDeleteAndReimportPreservesReadState() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let archive = try writeSeriesArchive(in: fixture.root, name: "read.cbz", series: "Read Me", volume: "1", number: "1")
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let suite = TestDefaults("local-import-slice6")
    defer { suite.remove() }
    let (importer, library, works) = localImporter(root: fixture.root, store: store, suite: suite)
    await importer.importFilesAndWait([archive])
    let seriesID = LocalSeriesIdentity.seriesID(for: "read me")
    let source = LocalSource(store: store)
    let listing = Manga(id: seriesID, sourceId: LocalSource.sourceID, title: "Read Me", description: "",
                        status: "completed", year: nil, coverURL: nil, malId: nil)
    let chapter = try #require(try await source.chapters(mangaId: seriesID).first)
    let readSuite = TestDefaults("local-import-read")
    defer { readSuite.remove() }
    let defaults = readSuite.defaults
    let history = HistoryStore(defaults: defaults, works: works)
    history.markRead(manga: listing, chapter: chapter)
    try await LocalLibraryDeletion(local: store, library: library, works: works).delete(itemId: seriesID)
    await importer.importFilesAndWait([archive])
    let restored = try #require(try await source.chapters(mangaId: seriesID).first)
    #expect(history.isRead(chapterId: restored.id))
    #expect(library.item(for: seriesID) != nil)
}

// Decision 17: deleting a series removes every member, its Library item and its Listing.
@MainActor @Test func localSeriesDeleteRemovesEveryMemberItemAndListing() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let libraryRoot = fixture.root.appendingPathComponent("library")
    let store = LocalLibraryStore(root: libraryRoot)
    let suite = TestDefaults("local-import-slice6")
    defer { suite.remove() }
    let (importer, library, works) = localImporter(root: fixture.root, store: store, suite: suite)
    let v1 = try writeSeriesArchive(in: fixture.root, name: "d1.cbz", series: "Gone", volume: "1")
    let v2 = try writeSeriesArchive(in: fixture.root, name: "d2.cbz", series: "Gone", volume: "2")
    let other = try writeSeriesArchive(in: fixture.root, name: "keep.cbz", series: nil)
    await importer.importFilesAndWait([v1, v2, other])
    let seriesID = LocalSeriesIdentity.seriesID(for: "gone")
    let members = await store.records(forMangaID: seriesID)
    #expect(members.count == 2)
    let kept = try #require(await store.allRecords().first { $0.comicInfo == nil })

    try await LocalLibraryDeletion(local: store, library: library, works: works).delete(itemId: seriesID)

    for member in members {
        #expect(!FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(member.itemId).path))
    }
    #expect(await store.records(forMangaID: seriesID).isEmpty)
    #expect(library.item(for: seriesID) == nil)
    #expect(works.workId(for: ListingKey(sourceId: LocalSource.sourceID, mangaId: seriesID)) == nil)
    #expect(await store.record(itemId: kept.itemId) != nil)
    #expect(library.item(for: kept.itemId) != nil)
}

@MainActor @Test func localSeriesMigrationConvergesPreSliceItemsAndIsIdempotent() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let v1 = try writeSeriesArchive(in: fixture.root, name: "old-v1.cbz", series: "Legacy", volume: "1", number: "1")
    let v2 = try writeSeriesArchive(in: fixture.root, name: "old-v2.cbz", series: "Legacy", volume: "2", number: "2")
    let standalone = try writeSeriesArchive(in: fixture.root, name: "no-series.cbz", series: nil)
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let first = try await store.importArchive(at: v1)
    let second = try await store.importArchive(at: v2)
    let noSeries = try await store.importArchive(at: standalone)
    guard case .imported(let firstRecord) = first, case .imported(let secondRecord) = second,
          case .imported(let noSeriesRecord) = noSeries else {
        Issue.record("expected imports")
        return
    }
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-migration")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let history = HistoryStore(defaults: defaults, works: works)
    func manga(_ id: String, _ title: String) -> Manga {
        Manga(id: id, sourceId: LocalSource.sourceID, title: title, description: "", status: "completed",
              year: nil, coverURL: nil, malId: nil)
    }
    library.toggle(manga(firstRecord.itemId, "Legacy Vol 1"))
    library.toggle(manga(secondRecord.itemId, "Legacy Vol 2"))
    library.toggle(manga(noSeriesRecord.itemId, "Standalone"))
    let oldChapter = try #require(try await LocalSource(store: store).chapters(mangaId: firstRecord.itemId).first)
    history.markRead(manga: manga(firstRecord.itemId, "Legacy Vol 1"), chapter: oldChapter)
    history.record(manga: manga(firstRecord.itemId, "Legacy Vol 1"), chapter: oldChapter,
                   position: ReadingPosition(page: 0), pageCount: 1)

    let seriesID = LocalSeriesIdentity.seriesID(for: "legacy")
    await LocalSeriesMigration.run(local: store, library: library, history: history, works: works)
    let afterFirst = (library.items, history.entries, history.readMarks, works.allWorkIds())
    await LocalSeriesMigration.run(local: store, library: library, history: history, works: works)
    #expect(library.items.count == 2)
    #expect(library.item(for: seriesID)?.chapterNumbers == ["1", "2"])
    #expect(works.workId(for: ListingKey(sourceId: LocalSource.sourceID, mangaId: seriesID)) != nil)
    #expect(history.entries.allSatisfy { $0.mangaId == seriesID || $0.mangaId == noSeriesRecord.itemId })
    #expect(history.readMarks.contains { $0.mangaId == seriesID && $0.chapterNumber == "1" })
    #expect(afterFirst.0 == library.items)
    #expect(afterFirst.1 == history.entries)
    #expect(afterFirst.2 == history.readMarks)
    #expect(afterFirst.3 == works.allWorkIds())
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

@Test func localSourceDetailMapsSummaryWritersAndGenres() async throws {
    let fixture = try LocalFixture(files: [
        ("001.png", LocalTestZip.png),
        ("ComicInfo.xml", Data(("<ComicInfo><Series>Series</Series><Summary>Summary</Summary>" +
                                "<Writer>A, B</Writer><Genre>Action, Fantasy</Genre></ComicInfo>").utf8))
    ]); defer { fixture.cleanup() }
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    guard case .imported(let record) = try await store.importArchive(at: fixture.archive) else { Issue.record("expected import"); return }
    let detail = try await LocalSource(store: store).mangaDetail(id: record.itemId)
    #expect(detail.description == "Summary")
    #expect(detail.authors == ["A", "B"])
    #expect(detail.tags.map { $0.name } == ["Action", "Fantasy"])
}

@MainActor @Test func localImportViewModelMintsWorkAndListing() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-work")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel()
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))

    await importer.importFilesAndWait([fixture.archive])

    let item = try #require(library.items.first)
    #expect(item.sourceId == LocalSource.sourceID)
    #expect(item.chapterNumbers == ["1"])
    let listing = ListingKey(sourceId: LocalSource.sourceID, mangaId: item.id)
    #expect(works.workId(for: listing) != nil)
}

@MainActor @Test func registryAlwaysRegistersLocalButNeverBrowsesIt() {
    let registry = SourceRegistry(sources: [LocalSource(), MangaDexSource()])
    #expect(registry.source(id: "local") != nil)
    #expect(!registry.visibleSources(includeAdult: true).contains { $0.id == "local" })
    #expect(registry.active?.id == MangaDexSource.sourceID)
}

@MainActor @Test func localImportViewModelReportsUnreadablePDF() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let pdf = fixture.root.appendingPathComponent("broken.pdf")
    try Data("not a PDF".utf8).write(to: pdf)
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-pdf-error")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel()
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))

    await importer.importFilesAndWait([pdf])

    #expect(importer.errors == ["broken.pdf: Could not read this PDF"])
}

@MainActor @Test func localImportViewModelCancellationIsSilent() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-pdf-cancel")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel()
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))

    importer.importFiles([fixture.archive])
    importer.cancel()
    await importer.importFilesAndWait([])

    #expect(importer.errors.isEmpty)
}

@MainActor @Test func localImportViewModelCleansHandedOverFilesButNotPickerFiles() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-cleanup")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel(containerRoot: fixture.root)
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))
    importer.importOpenedURL(fixture.archive)
    await importer.importFilesAndWait([])
    #expect(!FileManager.default.fileExists(atPath: fixture.archive.path))

    let picker = fixture.root.appendingPathComponent("picker.cbz")
    try LocalTestZip.write([("001.png", LocalTestZip.png)], to: picker)
    importer.importFiles([picker])
    await importer.importFilesAndWait([])
    #expect(FileManager.default.fileExists(atPath: picker.path))
}

// In-place opening hands over the reader's original file, which lies outside the container.
@MainActor @Test func localImportViewModelKeepsHandedOverFileOutsideContainer() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let container = fixture.root.appendingPathComponent("container")
    let store = LocalLibraryStore(root: container.appendingPathComponent("library"))
    let works = WorkStore(directory: container.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-in-place")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel(containerRoot: container)
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))
    importer.importOpenedURL(fixture.archive)
    await importer.importFilesAndWait([])
    #expect(importer.errors.isEmpty)
    #expect((await store.allRecords()).count == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
}

// Files lists an app under Open With only if it opens documents in place, and makes it the
// tap-to-open default only at Owner rank (measured on iOS 26.5, 2026-09-29; spec decision 12).
@Test func infoPlistMakesMangaCartaTheDefaultCBZOpener() throws {
    let info = try #require(Bundle.main.infoDictionary)
    #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
    let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
    func rank(_ type: String) -> String? {
        types.first { ($0["LSItemContentTypes"] as? [String])?.contains(type) == true }?["LSHandlerRank"] as? String
    }
    #expect(rank("com.mangacarta.cbz") == "Owner")
    #expect(rank("public.zip-archive") == "Alternate")
    #expect(rank("com.adobe.pdf") == "Alternate")
}

@MainActor @Test func localImportViewModelQueuesBatchArrivingMidImport() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let second = fixture.root.appendingPathComponent("second.cbz")
    try LocalTestZip.write([("001.png", LocalTestZip.png)], to: second)
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-queue")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel()
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))
    importer.importFiles([fixture.archive])
    importer.importFiles([second])
    await importer.importFilesAndWait([])
    #expect((await store.allRecords()).count == 2)
}

@MainActor @Test func localImportViewModelCancelClearsQueuedHandedOverFiles() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let second = fixture.root.appendingPathComponent("second.cbz")
    try LocalTestZip.write([("001.png", LocalTestZip.png)], to: second)
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-cancel-queue")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel(containerRoot: fixture.root)
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))
    importer.importOpenedURL(fixture.archive)
    importer.importOpenedURL(second)
    importer.cancel()
    await importer.importFilesAndWait([])
    #expect(!FileManager.default.fileExists(atPath: second.path))
}

@MainActor @Test func localImportViewModelAcceptsFileSharedAfterCancel() async throws {
    let fixture = try LocalFixture(); defer { fixture.cleanup() }
    let slow = fixture.root.appendingPathComponent("slow.cbz")
    let second = fixture.root.appendingPathComponent("second.cbz")
    let pages = (0..<400).map { (String(format: "%04d.png", $0), LocalTestZip.png) }
    try LocalTestZip.write(pages, to: slow)
    try LocalTestZip.write([("001.png", LocalTestZip.png)], to: second)
    let store = LocalLibraryStore(root: fixture.root.appendingPathComponent("library"))
    let works = WorkStore(directory: fixture.root.appendingPathComponent("works"))
    let suite = TestDefaults("local-import-post-cancel")
    defer { suite.remove() }
    let defaults = suite.defaults
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: defaults, works: works, registry: registry)
    let importer = LocalImportViewModel(containerRoot: fixture.root)
    importer.configure(registry: registry, library: library, works: works,
                       readingModes: ReadingModeStore(defaults: defaults, works: works))
    importer.importOpenedURL(slow)
    await Task.yield()
    importer.cancel()
    importer.importOpenedURL(second)
    await importer.importFilesAndWait([])
    #expect((await store.allRecords()).contains { $0.sourceFilename == "second.cbz" })
    #expect(!FileManager.default.fileExists(atPath: second.path))
}

@Suite("LocalImportSlice2Tests")
struct LocalImportSlice2Tests {
    @Test func importWritesRealPagesAndRecord() async throws { try await localImportWritesRealPagesAndRecord() }
    @Test func deduplicatesAndReimportsStableId() async throws { try await localImportDeduplicatesAndDeleteReimportsStableId() }
    @Test func sourceReadsFileURLsAndFiltersTitles() async throws { try await localSourceReadsFileURLsAndFiltersTitles() }
    @Test func capabilitiesDispatchThroughExistential() { localSourceCapabilitiesDispatchThroughExistential() }
    @MainActor @Test func registryFiltersLocal() { registryAlwaysRegistersLocalButNeverBrowsesIt() }
    @MainActor @Test func cancellationIsSilent() async throws { try await localImportViewModelCancellationIsSilent() }
    @MainActor @Test func groupsSeriesAcrossBatches() async throws {
        try await localImportGroupsSeriesAcrossBatchesAndKeepsStandaloneItemsSeparate()
    }
    @Test func stableSeriesNumbers() async throws { try await localSeriesNumbersRemainStableAndResolveCollisions() }
    @MainActor @Test func deleteReimportPreservesReadState() async throws {
        try await localSeriesDeleteAndReimportPreservesReadState()
    }
    @MainActor @Test func migrationConvergesPreSliceState() async throws {
        try await localSeriesMigrationConvergesPreSliceItemsAndIsIdempotent()
    }
}
