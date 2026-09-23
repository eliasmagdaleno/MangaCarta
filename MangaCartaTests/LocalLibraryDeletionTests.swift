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
}
