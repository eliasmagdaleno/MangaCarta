import Foundation
import PDFKit
import UIKit

enum PDFRasterizationError: Error, Equatable {
    case unreadable
    case empty
    case pageUnreadable(Int)
}

/// Converts PDF pages into the same JPEG page files used by the local archive reader.
struct PDFPageRasterizer: Sendable {
    var longEdge: CGFloat = 2_600

    func rasterize(source: URL, to directory: URL) async throws -> [String] {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: source), !document.isEncrypted,
              document.pageCount > 0 else { throw PDFRasterizationError.unreadable }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw PDFRasterizationError.pageUnreadable(index)
            }
            let bounds = page.bounds(for: .mediaBox)
            let longest = max(bounds.width, bounds.height)
            guard longest > 0 else { throw PDFRasterizationError.pageUnreadable(index) }
            let scale = longEdge / longest
            let size = CGSize(width: max(1, ceil(bounds.width * scale)),
                              height: max(1, ceil(bounds.height * scale)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            guard let data = image.jpegData(compressionQuality: 0.9) else {
                throw PDFRasterizationError.pageUnreadable(index)
            }
            let name = String(format: "%04d.jpg", index + 1)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            files.append(name)
        }
        return files
    }
}
