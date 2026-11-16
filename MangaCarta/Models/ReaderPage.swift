import Foundation

enum ReaderPage: Equatable, Sendable {
    case image(URL)
    case pdf(documentURL: URL, pageIndex: Int)
}

protocol VectorPageProviding {
    func pageReferences(chapterId: String) async throws -> [ReaderPage]
}
