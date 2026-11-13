import Foundation
import ImageIO
import PDFKit
import Testing
import UIKit
@testable import MangaCarta

@MainActor
@Suite("PDFVectorImportTests")
struct PDFVectorImportTests {
    @Test func threePagePDFStoresOneDocumentAndNoPageRasters() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("sample.pdf")
        try makePDF(at: source, pageCount: 3)
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"), pdfImport: .vector)
        let result = try await store.importArchive(at: source)
        guard case .imported(let record) = result else { Issue.record("expected import"); return }
        let item = root.appendingPathComponent("library").appendingPathComponent(record.itemId)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: item.path)) == ["document.pdf", "cover.jpg", "item.json"])
        #expect(record.chapters == [LocalChapter(number: 1, title: "sample", pageCount: 3, documentFilename: "document.pdf")])
        #expect(try Data(contentsOf: item.appendingPathComponent("document.pdf")) == Data(contentsOf: source))
        #expect(PDFDocument(url: item.appendingPathComponent("document.pdf"))?.pageCount == 3)
        #expect(record.byteSize == (try Data(contentsOf: source)).count)
        let cover = try #require(CGImageSourceCreateWithURL(item.appendingPathComponent("cover.jpg") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(max(cover.width, cover.height) <= 512 && max(cover.width, cover.height) > 0)
        #expect(await store.pageURLs(itemId: record.itemId, chapter: 1).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func vectorImportReportsTwoMilestones() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("sample.pdf"); try makePDF(at: source, pageCount: 3)
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"), pdfImport: .vector)
        let lock = NSLock(); var reports: [(Int, Int)] = []
        _ = try await store.importArchive(at: source) { value in lock.lock(); reports.append((value.completed, value.total)); lock.unlock() }
        lock.lock(); defer { lock.unlock() }; #expect(reports.map { $0.0 } == [1, 2]); #expect(reports.map { $0.1 } == [2, 2])
    }

    @Test func corruptAndZeroPagePDFsFailWithoutLeavingAnything() async throws {
        let root = try makeRoot()
        let library = root.appendingPathComponent("library"); let store = LocalLibraryStore(root: library, pdfImport: .vector)
        let corrupt = root.appendingPathComponent("bad.pdf"); try Data("bad".utf8).write(to: corrupt)
        let empty = root.appendingPathComponent("empty.pdf"); try makeZeroPagePDF(at: empty)
        await #expect(throws: LocalImportError.unreadablePDF) { try await store.importArchive(at: corrupt) }
        await #expect(throws: LocalImportError.unreadablePDF) { try await store.importArchive(at: empty) }
        #expect(await store.allRecords().isEmpty); try assertEmpty(library)
    }

    @Test func passwordLockedPDFStillFailsWithExistingMessage() async throws {
        let root = try makeRoot(); let source = root.appendingPathComponent("locked.pdf")
        try makePDF(at: source, pageCount: 1); let document = try #require(PDFDocument(url: source))
        #expect(document.write(to: source, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "user"]))
        let library = root.appendingPathComponent("library"); let store = LocalLibraryStore(root: library, pdfImport: .vector)
        await #expect(throws: LocalImportError.passwordProtectedPDF) { try await store.importArchive(at: source) }
        #expect(LocalImportViewModel.message(for: LocalImportError.passwordProtectedPDF) == "This PDF is password-protected")
        try assertEmpty(library)
    }

    @Test func legacyImageRecordDecodesAsImagesAndIsNotRewritten() async throws {
        let root = try makeRoot(); let library = root.appendingPathComponent("library")
        let id = "legacy"; let item = library.appendingPathComponent(id); try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        let date = Date(); let json: [String: Any] = ["itemId": id, "title": "Legacy", "sourceFilename": "legacy.cbz", "sha256": "hash", "byteSize": 2, "importedAt": date.timeIntervalSinceReferenceDate, "chapters": [["number": 1, "title": "One", "pageCount": 2, "pageFiles": ["0001.jpg", "0002.jpg"]]], "comicInfo": NSNull()]
        try JSONSerialization.data(withJSONObject: json).write(to: item.appendingPathComponent("item.json"))
        try FileManager.default.createDirectory(at: item.appendingPathComponent("pages/1"), withIntermediateDirectories: true)
        try Data([1]).write(to: item.appendingPathComponent("pages/1/0001.jpg"), options: .atomic); try Data([2]).write(to: item.appendingPathComponent("pages/1/0002.jpg"), options: .atomic)
        let before = try Data(contentsOf: item.appendingPathComponent("item.json")); let store = LocalLibraryStore(root: library, pdfImport: .vector)
        let record = try #require(await store.record(itemId: id)); #expect(record.chapters[0].pageStorage == .images(["0001.jpg", "0002.jpg"]))
        #expect(await store.pageURLs(itemId: id, chapter: 1).map(\.lastPathComponent) == ["0001.jpg", "0002.jpg"])
        _ = await store.allRecords(); _ = await store.itemSize(itemId: id); _ = await store.chapters(forMangaID: id)
        #expect(try Data(contentsOf: item.appendingPathComponent("item.json")) == before)
    }

    @Test func chapterRoundTripsBothStorageKinds() throws {
        for chapter in [LocalChapter(number: 1, title: "Images", pageCount: 1, pageFiles: ["a.jpg"]), LocalChapter(number: 1, title: "PDF", pageCount: 2, documentFilename: "document.pdf")] {
            let data = try JSONEncoder().encode(chapter); let decoded = try JSONDecoder().decode(LocalChapter.self, from: data); #expect(decoded == chapter)
            if case .pdf = chapter.pageStorage { #expect(String(decoding: data, as: UTF8.self).contains("\"pageFiles\":[ ]") || String(decoding: data, as: UTF8.self).contains("\"pageFiles\":[]")) }
        }
    }

    @Test func deletingVectorItemRemovesDocumentAndMetadata() async throws {
        let root = try makeRoot(); let source = root.appendingPathComponent("sample.pdf"); try makePDF(at: source, pageCount: 1)
        let library = root.appendingPathComponent("library"); let store = LocalLibraryStore(root: library, pdfImport: .vector); let result = try await store.importArchive(at: source)
        guard case .imported(let record) = result else { return }; #expect(await store.itemSize(itemId: record.itemId) >= (try Data(contentsOf: source)).count); try await store.delete(itemId: record.itemId); #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(record.itemId).path))
    }

    @Test func cancelledVectorImportLeavesNothing() async throws {
        let root = try makeRoot(); let source = root.appendingPathComponent("sample.pdf"); try makePDF(at: source, pageCount: 1)
        let library = root.appendingPathComponent("library"); let store = LocalLibraryStore(root: library, pdfImport: .vector)
        let box = CancellationBox()
        let task = Task { try await store.importArchive(at: source) { _ in box.task?.cancel() } }
        box.task = task
        do { _ = try await task.value; Issue.record("expected cancellation") } catch { #expect(error as? LocalImportError == .cancelled) }
        try assertEmpty(library)
    }

    @Test func rasterModeIsStillTheDefault() async throws {
        let root = try makeRoot(); let source = root.appendingPathComponent("sample.pdf"); try makePDF(at: source, pageCount: 2)
        let library = root.appendingPathComponent("library"); let store = LocalLibraryStore(root: library); let result = try await store.importArchive(at: source)
        guard case .imported(let record) = result else { return }; #expect(record.chapters[0].pageStorage == .images(record.chapters[0].pageFiles)); #expect(await store.pageURLs(itemId: record.itemId, chapter: 1).count == 2); #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(record.itemId).appendingPathComponent("document.pdf").path))
    }

    @Test func rotatedFirstPageCoverIsLandscape() async throws {
        let root = try makeRoot(); let source = root.appendingPathComponent("rotated.pdf"); try makePDF(at: source, pageCount: 1, rotate: true)
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"), pdfImport: .vector); let result = try await store.importArchive(at: source); guard case .imported(let record) = result else { return }
        let cover = try #require(await store.coverURL(itemId: record.itemId)); let image = try #require(CGImageSourceCreateWithURL(cover as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }); #expect(image.width > image.height)
    }

    private func makeRoot() throws -> URL {
        let root = TestDirectory("PDFVectorImportTests-\(UUID().uuidString)").url
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePDF(at url: URL, pageCount: Int, rotate: Bool = false) throws { let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)); try renderer.pdfData { context in for _ in 0..<pageCount { context.beginPage(); UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 400)) } }.write(to: url); if rotate, let document = PDFDocument(url: url), let page = document.page(at: 0) { page.rotation = 90; #expect(document.write(to: url)) } }
    private func makeZeroPagePDF(at url: URL) throws { try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8).write(to: url) }
    private func assertEmpty(_ library: URL) throws { let entries = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil); #expect(entries.filter { $0.lastPathComponent != ".staging" }.isEmpty); #expect((try? FileManager.default.contentsOfDirectory(at: library.appendingPathComponent(".staging"), includingPropertiesForKeys: nil).isEmpty) == true) }
}

private final class CancellationBox: @unchecked Sendable {
    var task: Task<LocalImportResult, Error>?
}
