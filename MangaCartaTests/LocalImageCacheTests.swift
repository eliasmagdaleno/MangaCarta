import Foundation
import Testing
import UIKit
@testable import MangaCarta

@Test func fileURLImageBypassesFetcherAndDisk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("page.png")
    let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    try bytes.write(to: file)
    let cacheDir = root.appendingPathComponent("cache")
    let cache = ImageCache(directory: cacheDir, fetcher: { _ in
        Issue.record("fetcher called")
        return bytes
    })
    #expect(await cache.loadImage(for: file) != nil)
    #expect((try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil).isEmpty) == true)
}

@Test func missingFileImageReturnsNil() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = ImageCache(directory: directory, fetcher: { _ in
        Issue.record("fetcher called")
        return Data()
    })
    #expect(await cache.loadImage(for: URL(fileURLWithPath: "/tmp/does-not-exist-local-page.png")) == nil)
}

@Suite("LocalImageCacheTests")
struct LocalImageCacheTests {
    @Test func fileURLBypassesFetcherAndDisk() async throws { try await fileURLImageBypassesFetcherAndDisk() }
    @Test func missingFileReturnsNil() async { await missingFileImageReturnsNil() }
}
