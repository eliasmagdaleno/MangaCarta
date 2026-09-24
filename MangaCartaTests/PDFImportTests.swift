import Foundation
import PDFKit
import Testing
import UIKit
@testable import MangaCarta

@Suite("PDFImportTests")
struct PDFImportTests {
    @Test func threePagePDFImportsInOrderWithCoverAndNoRetainedPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("sample.pdf")
        try makePDF(at: pdf, pageCount: 3)
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)

        guard case .imported(let record) = try await store.importArchive(at: pdf) else {
            Issue.record("expected PDF import")
            return
        }
        #expect(record.chapters.count == 1)
        #expect(record.chapters[0].pageCount == 3)
        #expect(record.chapters[0].pageFiles == ["0001.jpg", "0002.jpg", "0003.jpg"])
        let pages = await store.pageURLs(itemId: record.itemId, chapter: 1)
        #expect(pages.count == 3)
        #expect(pages.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(await store.coverURL(itemId: record.itemId) != nil)
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(record.itemId).appendingPathComponent("cover.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(record.itemId).appendingPathComponent("sample.pdf").path))
    }

    @Test func corruptPDFFailsWithoutLeavingPartialDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: pdf)
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)

        await #expect(throws: LocalImportError.unreadablePDF) { try await store.importArchive(at: pdf) }
        #expect(await store.allRecords().isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        #expect(entries.filter { $0.lastPathComponent != ".staging" }.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(at: library.appendingPathComponent(".staging"), includingPropertiesForKeys: nil).isEmpty) == true)
    }

    private func makePDF(at url: URL, pageCount: Int) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                UIColor(hue: CGFloat(index) / CGFloat(pageCount), saturation: 0.35, brightness: 1, alpha: 1).setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 400))
                let text = "Page \(index + 1)"
                (text as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        try data.write(to: url)
    }
}
