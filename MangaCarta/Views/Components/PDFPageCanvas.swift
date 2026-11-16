import CoreGraphics
import PDFKit
import SwiftUI
import UIKit

protocol PDFPageRendering: Sendable {
    func draw(page: CGPDFPage, in context: CGContext, bounds: CGRect, box: CGPDFBox, transform: CGAffineTransform)
}

private struct CoreGraphicsPDFPageRenderer: PDFPageRendering {
    func draw(page: CGPDFPage, in context: CGContext, bounds: CGRect, box: CGPDFBox,
              transform: CGAffineTransform) {
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}

final class PDFPageHolder: @unchecked Sendable {
    let page: CGPDFPage

    init(page: CGPDFPage) {
        self.page = page
    }
}

private final class PDFPageCanvasDrawingState: @unchecked Sendable {
    private let lock = NSLock()
    private var holder: PDFPageHolder?
    private var renderer: any PDFPageRendering

    init(page: CGPDFPage?, renderer: any PDFPageRendering) {
        holder = page.map(PDFPageHolder.init(page:))
        self.renderer = renderer
    }

    func snapshot() -> (PDFPageHolder?, any PDFPageRendering) {
        lock.lock()
        defer { lock.unlock() }
        return (holder, renderer)
    }

    func update(page: CGPDFPage, renderer: any PDFPageRendering) {
        lock.lock()
        holder = PDFPageHolder(page: page)
        self.renderer = renderer
        lock.unlock()
    }

    func clear() {
        lock.lock()
        holder = nil
        lock.unlock()
    }
}

struct PDFPageCanvas: UIViewRepresentable {
    let page: CGPDFPage
    var renderer: any PDFPageRendering = CoreGraphicsPDFPageRenderer()

    func makeUIView(context: Context) -> PDFPageCanvasView {
        PDFPageCanvasView(page: page, renderer: renderer)
    }

    func updateUIView(_ view: PDFPageCanvasView, context: Context) {
        view.setPage(page, renderer: renderer)
    }

    static func dismantleUIView(_ view: PDFPageCanvasView, coordinator: ()) {
        view.releasePage()
    }
}

final class PDFPageCanvasView: UIView {
    override static var layerClass: AnyClass { CATiledLayer.self }

    nonisolated private let drawingState: PDFPageCanvasDrawingState

    var pageHolder: PDFPageHolder? {
        drawingState.snapshot().0
    }

    init(page: CGPDFPage?, renderer: any PDFPageRendering = CoreGraphicsPDFPageRenderer()) {
        drawingState = PDFPageCanvasDrawingState(page: page, renderer: renderer)
        super.init(frame: .zero)
        isOpaque = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        if let tiledLayer = layer as? CATiledLayer {
            tiledLayer.levelsOfDetail = 1
            tiledLayer.levelsOfDetailBias = 2
            tiledLayer.tileSize = CGSize(width: 512, height: 512)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPage(_ page: CGPDFPage, renderer: any PDFPageRendering) {
        drawingState.update(page: page, renderer: renderer)
        layer.setNeedsDisplay()
    }

    func releasePage() {
        drawingState.clear()
        layer.contents = nil
        layer.setNeedsDisplay()
    }

    nonisolated override func draw(_ layer: CALayer, in context: CGContext) {
        let (holder, renderer) = drawingState.snapshot()
        guard let page = holder?.page else { return }
        let bounds = layer.bounds
        let box = CGPDFBox.cropBox
        let transform = page.getDrawingTransform(box, rect: bounds, rotate: 0, preserveAspectRatio: true)
        renderer.draw(page: page, in: context, bounds: bounds, box: box, transform: transform)
    }
}
