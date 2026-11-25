import PDFKit

struct PDFDocumentPage: @unchecked Sendable {
    let document: PDFDocument
    let page: CGPDFPage
}

/// Lazily opens PDF documents and retains only the two most recently used documents.
@MainActor
final class PDFDocumentSession {
    typealias Opener = (URL) -> PDFDocument?

    private struct Entry {
        let document: PDFDocument
        var lastUsed: UInt64
    }

    private let openDocument: Opener
    private var entries: [URL: Entry] = [:]
    private var accessClock: UInt64 = 0

    init(opener: @escaping Opener = { PDFDocument(url: $0) }) {
        openDocument = opener
    }

    func page(documentURL: URL, pageIndex: Int) -> PDFDocumentPage? {
        let key = documentURL.standardizedFileURL
        accessClock &+= 1
        var entry: Entry
        if var cached = entries[key] {
            cached.lastUsed = accessClock
            entry = cached
        } else {
            guard let document = openDocument(key), !document.isLocked else { return nil }
            entry = Entry(document: document, lastUsed: accessClock)
        }
        guard pageIndex >= 0, pageIndex < entry.document.pageCount,
              let page = entry.document.page(at: pageIndex)?.pageRef,
              PDFPageGeometry.isDrawable(cropBox: page.getBoxRect(.cropBox)) else { return nil }
        entries[key] = entry
        evictIfNeeded()
        return PDFDocumentPage(document: entry.document, page: page)
    }

    private func evictIfNeeded() {
        while entries.count > 2 {
            guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return }
            entries.removeValue(forKey: oldest)
        }
    }
}
