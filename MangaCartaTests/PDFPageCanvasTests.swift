import CoreGraphics
import PDFKit
import SwiftUI
import Testing
import UIKit
@testable import MangaCarta

@MainActor
struct PDFPageGeometryTests {
    @Test func unrotatedCropBoxKeepsPortraitAspect() {
        #expect(PDFPageGeometry.displayedSize(cropBox: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 0)
                == CGSize(width: 600, height: 800))
    }

    @Test func quarterTurnsSwapDisplayedDimensions() {
        let cropBox = CGRect(x: 0, y: 0, width: 600, height: 800)
        #expect(PDFPageGeometry.displayedSize(cropBox: cropBox, rotation: 90) == CGSize(width: 800, height: 600))
        #expect(PDFPageGeometry.displayedSize(cropBox: cropBox, rotation: 270) == CGSize(width: 800, height: 600))
    }

    @Test func halfTurnKeepsDimensions() {
        #expect(PDFPageGeometry.displayedSize(cropBox: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 180)
                == CGSize(width: 600, height: 800))
    }

    @Test func cropBoxUsesItsSizeRegardlessOfOrigin() {
        #expect(PDFPageGeometry.displayedSize(cropBox: CGRect(x: 100, y: 200, width: 600, height: 800), rotation: 0)
                == CGSize(width: 600, height: 800))
    }

    @Test func testSmallPageScalesUpToFill() throws {
        let crop = CGRect(x: 0, y: 0, width: 300, height: 400)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let directory = try makePDFCanvasTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("small-page.pdf")
        let document = try makeSinglePagePDF(bounds: crop)
        #expect(PDFFixtureWriter.write(document, to: url))
        let reopened = try #require(PDFDocument(url: url))
        let page = try #require(reopened.page(at: 0)?.pageRef)
        let recorder = PDFPageRenderingRecorder()
        let view = PDFPageCanvasView(page: PDFDocumentPage(document: reopened, page: page), renderer: recorder)
        view.frame = bounds
        let context = try #require(CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        view.draw(view.layer, in: context)
        let transform = try #require(recorder.transform)
        let mappedMin = crop.origin.applying(transform)
        let mappedMax = CGPoint(x: crop.maxX, y: crop.maxY).applying(transform)
        #expect(abs(mappedMin.x - bounds.minX) < 0.001)
        #expect(abs(mappedMin.y - bounds.minY) < 0.001)
        #expect(abs(mappedMax.x - bounds.maxX) < 0.001)
        #expect(abs(mappedMax.y - bounds.maxY) < 0.001)
    }

    @Test func testRotatedPageFitsBounds() {
        let crop = CGRect(x: 0, y: 0, width: 600, height: 800)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let transform = PDFPageGeometry.drawingTransform(cropBox: crop, rotation: 90, in: bounds)
        let corners = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                       CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.maxX, y: crop.maxY)]
            .map { $0.applying(transform) }
        #expect(abs(corners.map(\.x).min()! - bounds.minX) < 0.001)
        #expect(abs(corners.map(\.x).max()! - bounds.maxX) < 0.001)
        #expect(abs(corners.map(\.y).min()! - bounds.minY) < 0.001)
        #expect(abs(corners.map(\.y).max()! - bounds.maxY) < 0.001)
    }

    @Test func testCropBoxOriginIsHonoured() {
        let crop = CGRect(x: 50, y: 50, width: 300, height: 400)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let mapped = crop.origin.applying(PDFPageGeometry.drawingTransform(cropBox: crop, rotation: 0, in: bounds))
        #expect(abs(mapped.x - bounds.minX) < 0.001)
        #expect(abs(mapped.y - bounds.minY) < 0.001)
    }

    /// `/Rotate` turns the page clockwise. A bounding-box check can't tell a rotation from its mirror, so this
    /// follows the page's own top-left corner. In the transform's y-up space the displayed top is `maxY`.
    @Test(arguments: [
        (0, CGPoint(x: 0, y: 400)),
        (90, CGPoint(x: 400, y: 300)),
        (180, CGPoint(x: 300, y: 0)),
        (270, CGPoint(x: 0, y: 0))
    ])
    func testPageTopLeftLandsWhereTheRotationPutsIt(rotation: Int, expected: CGPoint) {
        let crop = CGRect(x: 10, y: 20, width: 300, height: 400)
        let displayed = PDFPageGeometry.displayedSize(cropBox: crop, rotation: rotation)
        let bounds = CGRect(origin: .zero, size: displayed)
        let transform = PDFPageGeometry.drawingTransform(cropBox: crop, rotation: rotation, in: bounds)
        let mapped = CGPoint(x: crop.minX, y: crop.maxY).applying(transform)
        #expect(abs(mapped.x - expected.x) < 0.001)
        #expect(abs(mapped.y - expected.y) < 0.001)
    }
}

@MainActor
struct PDFDocumentSessionTests {
    @Test func testOpensEachDocumentOnce() throws {
        let fixture = try makeFixture(pageCount: 20)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        var opens = 0
        let session = PDFDocumentSession { url in
            opens += 1
            return PDFDocument(url: url)
        }

        for page in 0..<20 {
            #expect(session.page(documentURL: fixture, pageIndex: page) != nil)
        }

        #expect(opens == 1)
    }

    @Test func testKeepsAtMostTwoDocuments() throws {
        let a = try makeFixture(pageCount: 1)
        let b = try makeFixture(pageCount: 1)
        let c = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: c.deletingLastPathComponent()) }
        var opens: [URL: Int] = [:]
        let session = PDFDocumentSession { url in
            opens[url, default: 0] += 1
            return PDFDocument(url: url)
        }

        #expect(session.page(documentURL: a, pageIndex: 0) != nil)
        #expect(session.page(documentURL: b, pageIndex: 0) != nil)
        #expect(session.page(documentURL: c, pageIndex: 0) != nil)
        #expect(session.page(documentURL: a, pageIndex: 0) != nil)
        #expect(opens[a] == 2)
        #expect(opens[b] == 1)
        #expect(opens[c] == 1)
    }

    @Test func testHolderKeepsTheDocumentAliveAfterEviction() throws {
        let a = try makeFixture(pageCount: 1)
        let b = try makeFixture(pageCount: 1)
        let c = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: a.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: c.deletingLastPathComponent()) }
        let trackedDocument = WeakPDFDocumentReference()
        let session = PDFDocumentSession { url in
            let document = PDFDocument(url: url)
            if url == a {
                trackedDocument.value = document
            }
            return document
        }
        var holder: PDFPageHolder?
        try autoreleasepool {
            var pageA: PDFDocumentPage? = try #require(session.page(documentURL: a, pageIndex: 0))
            holder = pageA.map(PDFPageHolder.init(_:))
            pageA = nil
            _ = session.page(documentURL: b, pageIndex: 0)
            _ = session.page(documentURL: c, pageIndex: 0)
        }
        #expect(trackedDocument.value != nil)
        holder = nil
        #expect(trackedDocument.value == nil)
    }

    @Test func testMissingPageIndexFails() throws {
        let url = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = PDFDocumentSession()
        #expect(session.page(documentURL: url, pageIndex: 1) == nil)
    }

    @Test func testUnreadableDocumentFails() throws {
        let directory = try makePDFCanvasTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not.pdf")
        try Data("not a PDF".utf8).write(to: url)
        #expect(PDFDocumentSession().page(documentURL: url, pageIndex: 0) == nil)
    }

    @Test func testLockedDocumentFails() throws {
        let url = try makeFixture(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        #expect(PDFFixtureWriter.write(document, to: url, options: [.ownerPasswordOption: "owner",
                                                                   .userPasswordOption: "user"]))
        #expect(PDFDocumentSession().page(documentURL: url, pageIndex: 0) == nil)
    }

    private func makeFixture(pageCount: Int) throws -> URL {
        let directory = try makePDFCanvasTestDirectory()
        let url = directory.appendingPathComponent(UUID().uuidString + ".pdf")
        let document = PDFDocument()
        for _ in 0..<pageCount {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 120))
            let data = renderer.pdfData { context in
                context.beginPage()
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 100, height: 120))
            }
            let pageDocument = try #require(PDFDocument(data: data))
            let page = try #require(pageDocument.page(at: 0))
            document.insert(page, at: document.pageCount)
        }
        #expect(PDFFixtureWriter.write(document, to: url))
        return url
    }
}

@MainActor
struct PDFPageCanvasTests {
    @Test func testTiledLayerRedrawsUpToFourTimes() throws {
        let view = PDFPageCanvasView(page: nil)
        let layer = try #require(view.layer as? CATiledLayer)
        #expect(pow(2.0, Double(layer.levelsOfDetailBias)) >= 4)
        #expect(layer.levelsOfDetail >= layer.levelsOfDetailBias + 1)
    }

    @Test func testCanvasIsNotAnAccessibilityElement() {
        let view = PDFPageCanvasView(page: nil)
        #expect(!view.isAccessibilityElement)
        #expect(view.accessibilityElementsHidden)
    }

    @Test func testDismantleReleasesThePage() throws {
        let directory = try makePDFCanvasTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("line.pdf")
        let document = try makeSinglePagePDF()
        #expect(PDFFixtureWriter.write(document, to: url))
        let reopened = try #require(PDFDocument(url: url))
        let pdfPage = try #require(reopened.page(at: 0))
        let documentPage = PDFDocumentPage(document: reopened, page: try #require(pdfPage.pageRef))
        var holder: PDFPageHolder? = PDFPageHolder(documentPage)
        let weakHolder = WeakPDFPageHolder(holder)
        let view = PDFPageCanvasView(page: documentPage)
        holder = nil
        PDFPageCanvas.dismantleUIView(view, coordinator: ())
        #expect(view.layer.contents == nil)
        #expect(view.pageHolder == nil)
        #expect(weakHolder.value == nil)
    }

    @Test func testDrawsTheRequestedPageWithCropBoxTransform() throws {
        let directory = try makePDFCanvasTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("rotated.pdf")
        let document = try makeSinglePagePDF(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        let pdfKitPage = try #require(document.page(at: 0))
        pdfKitPage.setBounds(CGRect(x: 100, y: 200, width: 300, height: 400), for: .cropBox)
        pdfKitPage.rotation = 90
        #expect(PDFFixtureWriter.write(document, to: output))
        let reopened = try #require(PDFDocument(url: output))
        let pdfPage = try #require(reopened.page(at: 0))
        let page = try #require(pdfPage.pageRef)
        let documentPage = PDFDocumentPage(document: reopened, page: page)
        let recorder = PDFPageRenderingRecorder()
        let view = PDFPageCanvasView(page: documentPage, renderer: recorder)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        view.draw(view.layer, in: context)
        let expected = PDFPageGeometry.drawingTransform(cropBox: page.getBoxRect(.cropBox),
                                                        rotation: Int(page.rotationAngle), in: view.bounds)
        let media = PDFPageGeometry.drawingTransform(cropBox: page.getBoxRect(.mediaBox),
                                                     rotation: Int(page.rotationAngle), in: view.bounds)
        #expect(recorder.pageNumber == 1)
        #expect(recorder.box == .cropBox)
        #expect(recorder.transform == expected)
        #expect(recorder.transform != media)
    }

    /// Draws through the production renderer, not a recorder, so the y-axis flip between PDF space
    /// (y up) and a layer's context (y down, like `UIGraphicsImageRenderer`'s) is under test. The
    /// fixture's band is at the top of the page as a reader sees it; drawn upside down it lands at
    /// the bottom.
    @Test func testPageDrawsRightSideUp() throws {
        let directory = try makePDFCanvasTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("top-band.pdf")
        let side: CGFloat = 100
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: side, height: side)).pdfData { context in
            context.beginPage()
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: 20))
        }
        let document = try #require(PDFDocument(data: data))
        #expect(PDFFixtureWriter.write(document, to: url))
        let reopened = try #require(PDFDocument(url: url))
        let page = try #require(reopened.page(at: 0)?.pageRef)
        let view = PDFPageCanvasView(page: PDFDocumentPage(document: reopened, page: page))
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.draw(view.layer, in: context.cgContext)
        }
        let pixels = try #require(RGBAPixels(image))

        #expect(pixels.isRed(x: 50, y: 10), "the band should be at the top")
        #expect(!pixels.isRed(x: 50, y: 90), "the bottom should be empty")
    }
}

/// An image redrawn into a known RGBA8 layout, top row first, so pixels can be read by point.
private struct RGBAPixels {
    let width: Int
    let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        bytes = buffer
    }

    func isRed(x: Int, y: Int) -> Bool {
        let offset = (y * width + x) * 4
        return bytes[offset] > 200 && bytes[offset + 1] < 60 && bytes[offset + 2] < 60 && bytes[offset + 3] > 200
    }
}

private func makeSinglePagePDF(bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) throws -> PDFDocument {
    let renderer = UIGraphicsPDFRenderer(bounds: bounds)
    let data = renderer.pdfData { context in context.beginPage() }
    return try #require(PDFDocument(data: data))
}

private func makePDFCanvasTestDirectory() throws -> URL {
    let directory = TestDirectory("PDFPageCanvasTests")
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    return directory.url
}

private final class WeakPDFPageHolder {
    weak var value: PDFPageHolder?

    init(_ value: PDFPageHolder?) {
        self.value = value
    }
}

@MainActor
private final class WeakPDFDocumentReference {
    weak var value: PDFDocument?
}

private final class PDFPageRenderingRecorder: PDFPageRendering, @unchecked Sendable {
    var pageNumber: Int?
    var box: CGPDFBox?
    var transform: CGAffineTransform?

    func draw(page: CGPDFPage, in context: CGContext, bounds: CGRect, box: CGPDFBox,
              transform: CGAffineTransform) {
        pageNumber = page.pageNumber
        self.box = box
        self.transform = transform
    }
}
