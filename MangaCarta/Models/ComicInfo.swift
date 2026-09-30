import Foundation

struct ComicInfo: Codable, Equatable, Sendable {
    let series: String?
    let title: String?
    let number: String?
    let volume: String?
    let summary: String?
    let writer: String?
    let genres: [String]
    let frontCoverPageIndex: Int?
    let manga: String?

    init(series: String?, title: String?, number: String?, volume: String?, summary: String?,
         writer: String?, genres: [String], frontCoverPageIndex: Int?, manga: String? = nil) {
        self.series = series; self.title = title; self.number = number; self.volume = volume
        self.summary = summary; self.writer = writer; self.genres = genres
        self.frontCoverPageIndex = frontCoverPageIndex; self.manga = manga
    }

    static func parse(_ data: Data) -> ComicInfo? {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.rootIsComicInfo else { return nil }
        func value(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let genres = (delegate.values["Genre"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ComicInfo(series: value(delegate.values["Series"]), title: value(delegate.values["Title"]),
                         number: value(delegate.values["Number"]), volume: value(delegate.values["Volume"]),
                         summary: value(delegate.values["Summary"]), writer: value(delegate.values["Writer"]),
                         genres: genres, frontCoverPageIndex: delegate.frontCoverPageIndex,
                         manga: value(delegate.values["Manga"]))
    }

    /// `Manga=YesAndRightToLeft` reads right to left; `Manga=No` is a Western comic, left to
    /// right. `Yes` says manga but not which way, so it — like `Unknown` — gives nothing
    /// (ADR-0026).
    var readingMode: ReadingMode? {
        switch manga?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yesandrighttoleft": return .rightToLeft
        case "no": return .leftToRight
        default: return nil
        }
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var rootIsComicInfo = false
        var values: [String: String] = [:]
        var frontCoverPageIndex: Int?
        private var current = ""
        private var buffer = ""
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            if depth == 1 { rootIsComicInfo = name.caseInsensitiveCompare("ComicInfo") == .orderedSame }
            current = name
            buffer = ""
            if name.caseInsensitiveCompare("Page") == .orderedSame,
               attributeDict["Type"]?.caseInsensitiveCompare("FrontCover") == .orderedSame,
               let image = Int(attributeDict["Image"] ?? "") { frontCoverPageIndex = image }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if depth == 2, ["Series", "Title", "Number", "Volume", "Summary", "Writer", "Genre", "Manga"].contains(name) {
                values[name, default: ""] += buffer
            }
            depth -= 1
            current = ""
            buffer = ""
        }
    }
}
