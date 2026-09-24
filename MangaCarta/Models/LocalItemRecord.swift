import Foundation

struct LocalChapter: Codable, Equatable, Sendable {
    let number: Int
    let title: String
    let pageCount: Int
    let pageFiles: [String]
}

struct LocalItemRecord: Codable, Equatable, Sendable {
    let itemId: String
    let title: String
    let sourceFilename: String
    let sha256: String
    let byteSize: Int
    let importedAt: Date
    let chapters: [LocalChapter]
}
