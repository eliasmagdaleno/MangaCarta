import Foundation
import ImageIO
import PDFKit
import Testing
import UIKit
@testable import MangaCarta

@Suite("PDFImportTests")
struct PDFImportTests {
    @Test func threePagePDFImportsRenderedPagesInOrderWithCoverAndNoRetainedPDF() async throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("sample")
        try makePDF(at: pdf, pageCount: 3)
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)
        guard case .imported(let record) = try await store.importArchive(at: pdf) else {
            Issue.record("expected PDF import")
            return
        }
        let pages = await store.pageURLs(itemId: record.itemId, chapter: 1)
        #expect(record.chapters.count == 1)
        #expect(record.chapters[0].pageCount == 3)
        #expect(pages.count == 3)
        #expect(pages.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        for (index, page) in pages.enumerated() {
            let image = try #require(CGImageSourceCreateWithURL(page as CFURL, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let expected = UIColor(hue: CGFloat(index) / 3, saturation: 0.35, brightness: 1, alpha: 1)
            #expect(rgbaImage(from: image).pixel(at: CGPoint(x: image.width / 2, y: image.height / 2))
                .distance(to: expected) < 0.15)
            let rendered = rgbaImage(from: image)
            #expect(rendered.pixel(at: CGPoint(x: image.width / 2, y: 10)).distance(to: .red) < 0.2)
            #expect(rendered.pixel(at: CGPoint(x: 10, y: image.height / 2)).distance(to: .blue) < 0.2)
            #expect(rendered.pixel(at: CGPoint(x: image.width / 2, y: image.height - 10)).distance(to: expected) < 0.2)
            #expect(max(image.width, image.height) == 2_600)
            #expect(abs(Double(image.width) / Double(image.height) - 0.75) < 0.01)
        }
        #expect(await store.coverURL(itemId: record.itemId) != nil)
        let cover = try #require(await store.coverURL(itemId: record.itemId))
        let coverImage = try #require(CGImageSourceCreateWithURL(cover as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(max(coverImage.width, coverImage.height) == 512)
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent(record.itemId)
            .appendingPathComponent("sample").path))
    }

    @Test func rotatedPDFPageImportsAsLandscape() async throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("rotated.pdf")
        try makePDF(at: pdf, pageCount: 1, rotateLastPage: true)
        let store = LocalLibraryStore(root: root.appendingPathComponent("library"))
        guard case .imported(let record) = try await store.importArchive(at: pdf) else {
            Issue.record("expected rotated PDF import")
            return
        }
        let page = try #require(await store.pageURLs(itemId: record.itemId, chapter: 1).first)
        let image = try #require(CGImageSourceCreateWithURL(page as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let rendered = rgbaImage(from: image)
        let pageColor = UIColor(hue: 0, saturation: 0.35, brightness: 1, alpha: 1)
        let leftEdge = rendered.pixel(at: CGPoint(x: 100, y: image.height / 2))
        #expect(leftEdge.distance(to: pageColor) < 0.2)
        #expect(!leftEdge.isRed)
        #expect(rendered.pixel(at: CGPoint(x: image.width / 2, y: 10)).isBlue)
        #expect(rendered.pixel(at: CGPoint(x: image.width - 100, y: image.height / 2)).isRed)
        #expect(image.width > image.height)
        #expect(max(image.width, image.height) == 2_600)
    }

    @Test func corruptAndZeroPagePDFsFailWithoutLeavingPartialDirectories() async throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)
        let corrupt = root.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: corrupt)
        let empty = root.appendingPathComponent("empty.pdf")
        try makeZeroPagePDF(at: empty)
        await #expect(throws: LocalImportError.unreadablePDF) { try await store.importArchive(at: corrupt) }
        await #expect(throws: LocalImportError.unreadablePDF) { try await store.importArchive(at: empty) }
        #expect(await store.allRecords().isEmpty)
        try assertLibraryIsEmpty(library)
    }

    @Test func userPasswordLockedPDFFailsWithoutLeavingAnything() async throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("locked.pdf")
        try makePDF(at: pdf, pageCount: 1)
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.write(to: pdf, withOptions: [PDFDocumentWriteOption.ownerPasswordOption: "owner",
                                                       PDFDocumentWriteOption.userPasswordOption: "user"]))
        let library = root.appendingPathComponent("library")
        let store = LocalLibraryStore(root: library)
        await #expect(throws: LocalImportError.passwordProtectedPDF) { try await store.importArchive(at: pdf) }
        #expect(await store.allRecords().isEmpty)
        try assertLibraryIsEmpty(library)
    }

    private func testRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePDF(at url: URL, pageCount: Int, rotateLastPage: Bool = false) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                UIColor(hue: CGFloat(index) / CGFloat(max(pageCount, 1)), saturation: 0.35,
                        brightness: 1, alpha: 1).setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 400))
                UIColor.red.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 300, height: 100))
                UIColor.blue.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 400))
            }
        }
        try data.write(to: url)
        guard rotateLastPage, let document = PDFDocument(url: url), let page = document.page(at: pageCount - 1) else {
            return
        }
        page.rotation = 90
        #expect(document.write(to: url))
    }

    private func makeZeroPagePDF(at url: URL) throws {
        let bytes = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n"
            + "<< /Root 1 0 R >>\n%%EOF\n"
        try Data(bytes.utf8).write(to: url)
    }

    private func assertLibraryIsEmpty(_ library: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        #expect(entries.filter { $0.lastPathComponent != ".staging" }.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(at: library.appendingPathComponent(".staging"),
            includingPropertiesForKeys: nil).isEmpty) == true)
    }
}

private extension UIColor {
    var isRed: Bool { redComponent > greenComponent + 0.3 && redComponent > blueComponent + 0.3 }
    var isBlue: Bool { blueComponent > redComponent + 0.2 && blueComponent > greenComponent + 0.2 }

    private var redComponent: CGFloat { components.0 }
    private var greenComponent: CGFloat { components.1 }
    private var blueComponent: CGFloat { components.2 }

    private var components: (CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    func distance(to other: UIColor) -> CGFloat {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)
    }
}

private struct RGBAImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(at point: CGPoint) -> UIColor {
        let x = min(width - 1, max(0, Int(point.x)))
        let y = min(height - 1, max(0, Int(point.y)))
        let index = (y * width + x) * 4
        return UIColor(red: CGFloat(bytes[index]) / 255, green: CGFloat(bytes[index + 1]) / 255,
                       blue: CGFloat(bytes[index + 2]) / 255, alpha: CGFloat(bytes[index + 3]) / 255)
    }
}

private func rgbaImage(from image: CGImage) -> RGBAImage {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(data: baseAddress, width: image.width, height: image.height,
                                       bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return RGBAImage(width: image.width, height: image.height, bytes: bytes)
}
