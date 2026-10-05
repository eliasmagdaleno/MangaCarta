import Testing
import Foundation
@testable import MangaCarta

@Suite("LocalLibraryDeletionTests")
struct LocalLibraryDeletionTests {
    @Test @MainActor func librarySeparatesLegacyListingFromInstalledSource() throws {
        let suite = TestDefaults("LibraryStoreListingKeyTests")
        defer { suite.remove() }
        let legacy = LibraryItem(id: "X", title: "Legacy", coverURL: nil, sourceId: nil)
        suite.defaults.set(try JSONEncoder().encode([legacy]), forKey: "library.items")
        let library = LibraryStore(defaults: suite.defaults)
        let installed = Manga(id: "X", sourceId: "repo:mangadex", title: "Installed",
                              description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)

        #expect(library.contains(installed) == false)
        #expect(library.item(for: ListingKey(installed)) == nil)
        library.toggle(installed)

        #expect(library.items.count == 2)
        #expect(library.items.contains { $0.id == "X" && $0.sourceId == nil })
        #expect(library.items.contains { $0.id == "X" && $0.sourceId == "repo:mangadex" })
    }

    @Test @MainActor func togglingLegacyListingRemovesOnlyLegacyItem() throws {
        let suite = TestDefaults("LibraryStoreListingKeyTests")
        defer { suite.remove() }
        let legacy = LibraryItem(id: "X", title: "Legacy", coverURL: nil, sourceId: nil)
        suite.defaults.set(try JSONEncoder().encode([legacy]), forKey: "library.items")
        let library = LibraryStore(defaults: suite.defaults)
        let installed = Manga(id: "X", sourceId: "repo:mangadex", title: "Installed",
                              description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
        library.toggle(installed)
        let legacyListing = installed.relisted(as: ListingKey(sourceId: LegacySourceID.unattributed, mangaId: "X"))

        library.toggle(legacyListing)

        #expect(library.items.count == 1)
        #expect(library.item(for: ListingKey(installed)) != nil)
        #expect(library.item(for: ListingKey(legacyListing)) == nil)
    }

    @Test @MainActor func collectionChangesDoNotTouchAnotherListing() throws {
        let suite = TestDefaults("LibraryStoreListingKeyTests")
        defer { suite.remove() }
        let legacy = LibraryItem(id: "X", title: "Legacy", coverURL: nil, sourceId: nil,
                                 collectionIds: [LibraryCollection.readingID])
        suite.defaults.set(try JSONEncoder().encode([legacy]), forKey: "library.items")
        let library = LibraryStore(defaults: suite.defaults)
        let installed = Manga(id: "X", sourceId: "repo:mangadex", title: "Installed",
                              description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
        let collection = "custom"

        library.toggleCollection(for: installed, collectionId: collection)
        #expect(library.item(for: ListingKey(installed))?.collectionIds == [collection])
        let legacyKey = ListingKey(sourceId: LegacySourceID.unattributed, mangaId: "X")
        #expect(library.item(for: legacyKey)?.collectionIds == [LibraryCollection.readingID])

        library.setCollections(for: installed, collectionIds: ["other"])
        #expect(library.item(for: ListingKey(installed))?.collectionIds == ["other"])
        #expect(library.item(for: legacyKey)?.collectionIds == [LibraryCollection.readingID])
    }
    @Test @MainActor func removeListingDeletesLastWork() async {
        let directory = TestDirectory("LocalLibraryDeletionTests").url
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
        let root = TestDirectory("LocalLibraryDeletionTests").url
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("book.cbz")
        try LocalTestZip.write([("001.png", LocalTestZip.png)], to: archive)
        let localStore = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await localStore.importArchive(at: archive) else {
            Issue.record("import failed")
            return
        }
        let suite = TestDefaults("LocalLibraryDeletionTests")
        defer { suite.remove() }
        let defaults = suite.defaults
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

    @Test @MainActor func missingStagedDirectoryStillRemovesCatalogAndWork() async throws {
        let root = TestDirectory("LocalLibraryDeletionTests").url
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("book.cbz")
        try LocalTestZip.write([("001.png", LocalTestZip.png)], to: archive)
        let localStore = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await localStore.importArchive(at: archive) else {
            Issue.record("import failed")
            return
        }
        let suite = TestDefaults("LocalLibraryDeletionTests")
        defer { suite.remove() }
        let defaults = suite.defaults
        let works = WorkStore(directory: root.appendingPathComponent("works"))
        let library = LibraryStore(defaults: defaults, works: works)
        let manga = Manga(id: record.itemId, sourceId: "local", title: record.title, description: "",
                          status: "completed", year: nil, coverURL: nil, malId: nil)
        library.toggle(manga)
        try FileManager.default.removeItem(at: root.appendingPathComponent("library").appendingPathComponent(record.itemId))

        try await LocalLibraryDeletion(local: localStore, library: library, works: works)
            .delete(itemId: record.itemId)

        #expect(!library.contains(record.itemId))
        #expect(works.workId(for: ListingKey(manga)) == nil)
    }
}
