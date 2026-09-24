import Testing
import Foundation
@testable import MangaCarta

@Suite("LocalLibraryDeletionTests")
struct LocalLibraryDeletionTests {
    @Test @MainActor func removeListingDeletesLastWork() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let works = WorkStore(directory: directory)
        let manga = Manga(id: "item", sourceId: "local", title: "Item", description: "",
                          status: "completed", year: nil, coverURL: nil, malId: nil)
        let id = works.mint(from: manga)
        works.removeListing(ListingKey(manga))
        #expect(works.work(id) == nil)
        works.flush()
        #expect(WorkStore(directory: directory).work(id) == nil)
    }

    @Test @MainActor func reimportReattachesHistoryAfterDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("book.cbz")
        try LocalTestZip.write([("001.png", LocalTestZip.png)], to: archive)
        let localStore = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await localStore.importArchive(at: archive) else {
            Issue.record("import failed")
            return
        }
        let defaults = UserDefaults(suiteName: "LocalLibraryDeletionTests-\(UUID().uuidString)")!
        let works = WorkStore(directory: root.appendingPathComponent("works"))
        let library = LibraryStore(defaults: defaults, works: works)
        let manga = Manga(id: record.itemId, sourceId: "local", title: record.title, description: "",
                          status: "completed", year: nil, coverURL: await localStore.coverURL(itemId: record.itemId), malId: nil)
        library.toggle(manga)
        let history = HistoryStore(defaults: defaults, works: works)
        let chapter = Chapter(id: "\(record.itemId)/1", number: "1", title: record.chapters[0].title)
        history.record(manga: manga, chapter: chapter, position: ReadingPosition(page: 0, fraction: 0), pageCount: 1)
        let deletion = LocalLibraryDeletion(local: localStore, library: library, works: works)
        try await deletion.delete(itemId: record.itemId)
        #expect(history.entry(forChapter: chapter.id) != nil)
        guard case .imported(let reimported) = try await localStore.importArchive(at: archive) else {
            Issue.record("reimport failed")
            return
        }
        #expect(reimported.itemId == record.itemId)
        #expect(history.entry(forChapter: "\(reimported.itemId)/1") != nil)
    }
}
