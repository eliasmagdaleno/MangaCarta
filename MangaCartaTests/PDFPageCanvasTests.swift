import CoreGraphics
import PDFKit
import SwiftUI
import Testing
import UIKit
@testable import MangaCarta

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
        let page = try #require(reopened.page(at: 0)?.pageRef)
        var holder: PDFPageHolder? = PDFPageHolder(page: page)
        let weakHolder = WeakPDFPageHolder(holder)
        let view = PDFPageCanvasView(page: try #require(holder).page)
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
        let page = try #require(reopened.page(at: 0)?.pageRef)
        let recorder = PDFPageRenderingRecorder()
        let view = PDFPageCanvasView(page: page, renderer: recorder)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        view.draw(view.layer, in: context)
        let expected = page.getDrawingTransform(.cropBox, rect: view.bounds, rotate: 0, preserveAspectRatio: true)
        let media = page.getDrawingTransform(.mediaBox, rect: view.bounds, rotate: 0, preserveAspectRatio: true)
        #expect(recorder.pageNumber == 1)
        #expect(recorder.box == .cropBox)
        #expect(recorder.transform == expected)
        #expect(recorder.transform != media)
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
