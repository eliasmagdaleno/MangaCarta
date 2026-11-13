import Foundation
import ImageIO
import PDFKit
import Testing
import UIKit
@testable import MangaCarta

/// Slice 1 of the vector PDF reader (design `2026-11-09-vector-pdf-reader-design.md`, Amendment 1):
/// a `.vector` store keeps the PDF and renders only a cover. Production still uses `.raster`
/// until the reader can draw a PDF; `rasterModeIsStillTheDefault` pins that.
@Suite("PDFVectorImportTests")
final class PDFVectorImportTests {
    private let directory = TestDirectory("PDFVectorImportTests")
    private var root: URL { directory.url }
    private var library: URL { root.appendingPathComponent("library") }

    deinit { directory.remove() }

    // MARK: - Criterion 1: one document, one cover, no page rasters

    @Test func threePagePDFStoresOneDocumentAndNoPageRasters() async throws {
        let source = try makePDF(named: "sample.pdf", pageCount: 3)
        let store = vectorStore()

        let record = try importedRecord(await store.importArchive(at: source))

        let item = library.appendingPathComponent(record.itemId)
        let contents = try FileManager.default.contentsOfDirectory(atPath: item.path)
        #expect(Set(contents) == ["document.pdf", "cover.jpg", "item.json"])
        #expect(record.chapters.count == 1)
        #expect(record.chapters[0].pageCount == 3)
        #expect(record.chapters[0].pageStorage == .pdf(documentFilename: "document.pdf"))

        let sourceBytes = try Data(contentsOf: source)
        #expect(try Data(contentsOf: item.appendingPathComponent("document.pdf")) == sourceBytes)
        #expect(PDFDocument(url: item.appendingPathComponent("document.pdf"))?.pageCount == 3)
        #expect(record.byteSize == sourceBytes.count)

        let cover = try image(at: item.appendingPathComponent("cover.jpg"))
        #expect(max(cover.width, cover.height) == 512)
        #expect(cover.height > cover.width)

        // Nothing for the image path to read; slice 2 adds the page references.
        #expect(await store.pageURLs(itemId: record.itemId, chapter: 1).isEmpty)
        // The original is the user's file and is never moved or deleted.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func vectorImportReportsTwoMilestones() async throws {
        let source = try makePDF(named: "sample.pdf", pageCount: 3)
        let reports = ProgressLog()

        _ = try await vectorStore().importArchive(at: source) { reports.append($0) }

        #expect(reports.values.map(\.completed) == [1, 2])
        #expect(reports.values.map(\.total) == [2, 2])
    }

    // MARK: - Criteria 2 and 3: rejected documents leave nothing

    @Test func corruptAndZeroPagePDFsFailWithoutLeavingAnything() async throws {
        let store = vectorStore()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = root.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: corrupt)
        let empty = root.appendingPathComponent("empty.pdf")
        try writeZeroPagePDF(to: empty)

        await #expect(throws: LocalImportError.unreadablePDF) { try await store.importArchive(at: corrupt) }
        await #expect(throws: LocalImportError.unreadablePDF) { try await store.importArchive(at: empty) }

        #expect(await store.allRecords().isEmpty)
        try expectLibraryIsEmpty()
    }

    @MainActor @Test func passwordLockedPDFStillFailsWithExistingMessage() async throws {
        let source = try makePDF(named: "locked.pdf", pageCount: 1)
        let document = try #require(PDFDocument(url: source))
        #expect(PDFFixtureWriter.write(document, to: source, options: [.ownerPasswordOption: "owner",
                                                                       .userPasswordOption: "user"]))
        let store = vectorStore()

        await #expect(throws: LocalImportError.passwordProtectedPDF) { try await store.importArchive(at: source) }

        #expect(LocalImportViewModel.message(for: LocalImportError.passwordProtectedPDF)
            == "This PDF is password-protected")
        try expectLibraryIsEmpty()
    }

    // MARK: - Criterion 4: records written before this change

    @Test func legacyImageRecordDecodesAsImagesAndIsNotRewritten() async throws {
        let itemId = "legacy"
        let item = library.appendingPathComponent(itemId)
        let pages = item.appendingPathComponent("pages/1")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Data([1]).write(to: pages.appendingPathComponent("0001.jpg"))
        try Data([2]).write(to: pages.appendingPathComponent("0002.jpg"))
        // Exactly what the previous build wrote: no `pageStorage` key, and `JSONEncoder`'s default
        // date form (seconds since the reference date).
        let legacyJSON = """
        {"itemId":"legacy","title":"Legacy","sourceFilename":"legacy.pdf","sha256":"abc","byteSize":2,\
        "importedAt":784000000,"chapters":[{"number":1,"title":"Legacy","pageCount":2,\
        "pageFiles":["0001.jpg","0002.jpg"]}]}
        """
        let recordURL = item.appendingPathComponent("item.json")
        try Data(legacyJSON.utf8).write(to: recordURL)
        let before = try Data(contentsOf: recordURL)
        let store = vectorStore()

        let record = try #require(await store.record(itemId: itemId))
        #expect(record.chapters[0].pageStorage == .images(["0001.jpg", "0002.jpg"]))
        let urls = await store.pageURLs(itemId: itemId, chapter: 1)
        #expect(urls == [pages.appendingPathComponent("0001.jpg"), pages.appendingPathComponent("0002.jpg")])

        _ = await store.allRecords()
        _ = await store.itemSize(itemId: itemId)
        _ = await store.chapters(forMangaID: itemId)
        #expect(try Data(contentsOf: recordURL) == before)
    }

    @Test func chapterRoundTripsBothStorageKinds() throws {
        let images = LocalChapter(number: 1, title: "Images", pageCount: 1, pageFiles: ["0001.jpg"])
        let pdf = LocalChapter(number: 1, title: "PDF", pageCount: 2, documentFilename: "document.pdf")

        for chapter in [images, pdf] {
            let data = try JSONEncoder().encode(chapter)
            #expect(try JSONDecoder().decode(LocalChapter.self, from: data) == chapter)
        }

        // An older build decodes `pageFiles` unconditionally, so a PDF chapter must still carry it.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pdf))
        let encodedPDF = try #require(object as? [String: Any])
        #expect(encodedPDF["pageFiles"] as? [String] == [])
    }

    // MARK: - Criterion 9: delete

    @Test func deletingVectorItemRemovesDocumentAndMetadata() async throws {
        let source = try makePDF(named: "sample.pdf", pageCount: 1)
        let store = vectorStore()
        let record = try importedRecord(await store.importArchive(at: source))
        let item = library.appendingPathComponent(record.itemId)
        #expect(FileManager.default.fileExists(atPath: item.appendingPathComponent("document.pdf").path))
        let sourceSize = try Data(contentsOf: source).count
        #expect(await store.itemSize(itemId: record.itemId) >= sourceSize)

        try await store.delete(itemId: record.itemId)

        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - Cancellation, the default, rotation

    @Test func cancelledVectorImportLeavesNothing() async throws {
        let source = try makePDF(named: "sample.pdf", pageCount: 1)
        let store = vectorStore()

        // The progress callback runs synchronously inside the importing task, so cancelling the
        // current task from it lands before the cover is written and the item is committed.
        let task = Task {
            try await store.importArchive(at: source) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        await #expect(throws: LocalImportError.cancelled) { try await task.value }
        try expectLibraryIsEmpty()
    }

    @Test func rasterModeIsStillTheDefault() async throws {
        let source = try makePDF(named: "sample.pdf", pageCount: 2)
        let store = LocalLibraryStore(root: library)

        let record = try importedRecord(await store.importArchive(at: source))

        #expect(record.chapters[0].pageStorage == .images(["0001.jpg", "0002.jpg"]))
        let urls = await store.pageURLs(itemId: record.itemId, chapter: 1)
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let item = library.appendingPathComponent(record.itemId)
        #expect(!FileManager.default.fileExists(atPath: item.appendingPathComponent("document.pdf").path))
    }

    @Test func rotatedFirstPageCoverIsLandscape() async throws {
        let source = try makePDF(named: "rotated.pdf", pageCount: 1, rotateFirstPage: true)
        let store = vectorStore()

        let record = try importedRecord(await store.importArchive(at: source))

        let cover = try image(at: try #require(await store.coverURL(itemId: record.itemId)))
        #expect(cover.width > cover.height)
        #expect(max(cover.width, cover.height) == 512)
    }

    // MARK: - Helpers

    private func vectorStore() -> LocalLibraryStore {
        LocalLibraryStore(root: library, pdfImport: .vector)
    }

    private func importedRecord(_ result: LocalImportResult) throws -> LocalItemRecord {
        guard case .imported(let record) = result else {
            throw ImportExpectation.notImported(result)
        }
        return record
    }

    /// Portrait 300 × 400 pages; `rotateFirstPage` turns page one a quarter, making it landscape.
    private func makePDF(named name: String, pageCount: Int, rotateFirstPage: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                let hue = CGFloat(index) / CGFloat(pageCount)
                UIColor(hue: hue, saturation: 0.35, brightness: 1, alpha: 1).setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 400))
            }
        }
        try data.write(to: url)
        if rotateFirstPage {
            let document = try #require(PDFDocument(url: url))
            try #require(document.page(at: 0)).rotation = 90
            #expect(PDFFixtureWriter.write(document, to: url))
        }
        return url
    }

    private func writeZeroPagePDF(to url: URL) throws {
        let bytes = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n"
            + "<< /Root 1 0 R >>\n%%EOF\n"
        try Data(bytes.utf8).write(to: url)
    }

    private func image(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func expectLibraryIsEmpty() throws {
        let entries = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        #expect(entries.filter { $0.lastPathComponent != ".staging" }.isEmpty)
        let staging = try FileManager.default.contentsOfDirectory(at: library.appendingPathComponent(".staging"),
                                                                  includingPropertiesForKeys: nil)
        #expect(staging.isEmpty)
    }
}

/// `PDFDocument.write` is not safe to call from two tests at once: with both PDF suites running in
/// parallel it intermittently returned `false`, leaving an unrotated or unlocked fixture. Every
/// fixture write in the test target goes through this one lock. It guards test setup only; the
/// importer never writes a PDF.
enum PDFFixtureWriter {
    private static let lock = NSLock()

    static func write(_ document: PDFDocument, to url: URL,
                      options: [PDFDocumentWriteOption: Any] = [:]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return document.write(to: url, withOptions: options)
    }
}

private enum ImportExpectation: Error {
    case notImported(LocalImportResult)
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [LocalImportProgress] = []

    func append(_ report: LocalImportProgress) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    var values: [LocalImportProgress] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}
