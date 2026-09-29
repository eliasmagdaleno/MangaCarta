import CryptoKit
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
    let comicInfo: ComicInfo?

    init(itemId: String, title: String, sourceFilename: String, sha256: String, byteSize: Int,
         importedAt: Date, chapters: [LocalChapter], comicInfo: ComicInfo? = nil) {
        self.itemId = itemId; self.title = title; self.sourceFilename = sourceFilename
        self.sha256 = sha256; self.byteSize = byteSize; self.importedAt = importedAt
        self.chapters = chapters; self.comicInfo = comicInfo
    }

}

enum LocalSeriesIdentity {
    static func normalizedSeries(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func seriesID(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "series-" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}
