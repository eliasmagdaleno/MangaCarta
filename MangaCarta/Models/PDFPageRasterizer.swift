import Foundation
import PDFKit
import UIKit

enum PDFRasterizationError: Error, Equatable {
    case unreadable
    case passwordProtected
    case pageUnreadable(Int)
}

/// Converts PDF pages into the same JPEG page files used by the local archive reader.
struct PDFPageRasterizer: Sendable {
    var longEdge: CGFloat = 2_600

    func rasterize(source: URL, to directory: URL) async throws -> [String] {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: source) else { throw PDFRasterizationError.unreadable }
        if document.isLocked { throw PDFRasterizationError.passwordProtected }
        guard document.pageCount > 0 else { throw PDFRasterizationError.unreadable }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw PDFRasterizationError.pageUnreadable(index)
            }
            let bounds = page.bounds(for: .cropBox)
            let longest = max(bounds.width, bounds.height)
            guard longest > 0 else { throw PDFRasterizationError.pageUnreadable(index) }
            let scale = longEdge / longest
            let isQuarterTurn = page.rotation % 180 != 0
            let size = CGSize(width: max(1, ceil((isQuarterTurn ? bounds.height : bounds.width) * scale)),
                              height: max(1, ceil((isQuarterTurn ? bounds.width : bounds.height) * scale)))
            let name = String(format: "%04d.jpg", index + 1)
            let file = directory.appendingPathComponent(name)
            try autoreleasepool {
                let thumbnail = page.thumbnail(of: size, for: .cropBox)
                guard let data = thumbnail.jpegData(compressionQuality: 0.9) else {
                    throw PDFRasterizationError.pageUnreadable(index)
                }
                try data.write(to: file, options: .atomic)
            }
            files.append(name)
        }
        return files
    }
}
