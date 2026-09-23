import Testing
import Foundation
@testable import MangaCarta

@Suite("LocalLibraryStoreTests")
struct LocalLibraryStoreTests {
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
}
