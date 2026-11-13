import CryptoKit
import Foundation

enum LocalPageStorage: Codable, Equatable, Sendable {
    case images([String])
    case pdf(documentFilename: String)

    private enum CodingKeys: String, CodingKey { case kind, files, documentFilename }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "images": self = .images(try container.decode([String].self, forKey: .files))
        case "pdf": self = .pdf(documentFilename: try container.decode(String.self, forKey: .documentFilename))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown page storage")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .images(let files):
            try container.encode("images", forKey: .kind)
            try container.encode(files, forKey: .files)
        case .pdf(let filename):
            try container.encode("pdf", forKey: .kind)
            try container.encode(filename, forKey: .documentFilename)
        }
    }
}

struct LocalChapter: Codable, Equatable, Sendable {
    let number: Int
    let title: String
    let pageCount: Int
    let pageFiles: [String]
    let pageStorage: LocalPageStorage

    init(number: Int, title: String, pageCount: Int, pageFiles: [String]) {
        self.number = number
        self.title = title
        self.pageCount = pageCount
        self.pageFiles = pageFiles
        self.pageStorage = .images(pageFiles)
    }

    init(number: Int, title: String, pageCount: Int, documentFilename: String) {
        self.number = number
        self.title = title
        self.pageCount = pageCount
        self.pageFiles = []
        self.pageStorage = .pdf(documentFilename: documentFilename)
    }

    private enum CodingKeys: String, CodingKey { case number, title, pageCount, pageFiles, pageStorage }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        pageFiles = try container.decode([String].self, forKey: .pageFiles)
        pageStorage = try container.decodeIfPresent(LocalPageStorage.self, forKey: .pageStorage) ?? .images(pageFiles)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encode(pageFiles, forKey: .pageFiles)
        try container.encode(pageStorage, forKey: .pageStorage)
    }
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
