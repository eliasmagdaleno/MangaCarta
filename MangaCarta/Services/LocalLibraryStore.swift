import CryptoKit
import Foundation
import UIKit

enum LocalImportResult: Equatable {
    case imported(LocalItemRecord)
    case duplicate(itemId: String)
}

struct LocalImportProgress: Sendable, Equatable {
    let fileName: String
    let completed: Int
    let total: Int
}

enum LocalImportError: Error, Equatable {
    case noImages
    case unreadableArchive(ZipArchiveError)
    case unreadablePDF
    case passwordProtectedPDF
    case cancelled
    case insufficientSpace
}

private struct PDFImportRequest {
    let source: URL
    let archive: URL
    let item: URL
    let destination: URL
    let staging: URL
    let itemId: String
    let hash: String
    let byteSize: Int
    let title: String
}

actor LocalLibraryStore {
    static let shared = LocalLibraryStore(root: WorkStore.applicationSupportDirectory().appendingPathComponent("LocalLibrary"))
    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging")
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    func importArchive(at source: URL) async throws -> LocalImportResult {
        try await importArchive(at: source, progress: nil)
    }

    func importArchive(at source: URL, progress: (@Sendable (LocalImportProgress) -> Void)?) async throws -> LocalImportResult {
        let staging = root.appendingPathComponent(".staging").appendingPathComponent(UUID().uuidString)
        let archive = staging.appendingPathComponent("archive")
        let item = staging.appendingPathComponent("item")
        do {
            try Task.checkCancellation()
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: archive)
            try Task.checkCancellation()
            let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
            try Task.checkCancellation()
            let digest = SHA256.hash(data: bytes)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let itemId = String(hash.prefix(32))
            let destination = root.appendingPathComponent(itemId)
            if fm.fileExists(atPath: destination.appendingPathComponent("item.json").path) {
                try? fm.removeItem(at: staging)
                return .duplicate(itemId: itemId)
            }
            let filenameTitle = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            let isPDF = bytes.starts(with: Data("%PDF-".utf8))
                || source.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
            if isPDF {
                let request = PDFImportRequest(source: source, archive: archive, item: item, destination: destination,
                                               staging: staging, itemId: itemId, hash: hash, byteSize: bytes.count,
                                               title: filenameTitle)
                return try await importPDF(request, progress: progress)
            }
            let reader = try openArchive(at: archive)
            let archiveChapters = try reader.chapters()
            guard !archiveChapters.isEmpty else { throw LocalImportError.noImages }
            let comicInfo = try readComicInfo(from: reader)
            let title = comicInfo?.series ?? comicInfo?.title ?? filenameTitle
            let groups = chapterGroups(from: archiveChapters, title: title)
            try fm.createDirectory(at: item, withIntermediateDirectories: true)
            var storedChapters: [LocalChapter] = []
            for (chapterIndex, group) in groups.enumerated() {
                try Task.checkCancellation()
                let pageDir = item.appendingPathComponent("pages/\(chapterIndex + 1)")
                try fm.createDirectory(at: pageDir, withIntermediateDirectories: true)
                var files: [String] = []
                for (pageIndex, entry) in group.1.enumerated() {
                    try Task.checkCancellation()
                    let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
                    let file = String(format: "%04d.%@", pageIndex + 1, ext)
                    let page = try reader.data(for: entry)
                    try Task.checkCancellation()
                    try page.write(to: pageDir.appendingPathComponent(file), options: .atomic)
                    files.append(file)
                    progress?(LocalImportProgress(fileName: source.lastPathComponent,
                                                  completed: pageIndex + 1,
                                                  total: group.1.count))
                    try Task.checkCancellation()
                }
                let chapterTitle = Self.chapterLabel(for: comicInfo, fallback: group.0 == "Root" ? title : group.0,
                                                     isSingleChapter: groups.count == 1)
                storedChapters.append(LocalChapter(number: chapterIndex + 1,
                    title: chapterTitle,
                    pageCount: files.count, pageFiles: files))
            }
            var pageURLs: [URL] = []
            for chapter in storedChapters {
                try Task.checkCancellation()
                for pageFile in chapter.pageFiles {
                    try Task.checkCancellation()
                    let pageURL = item.appendingPathComponent("pages/\(chapter.number)").appendingPathComponent(pageFile)
                    pageURLs.append(pageURL)
                }
            }
            if let cover = Self.coverPage(pageURLs: pageURLs, frontCoverPageIndex: comicInfo?.frontCoverPageIndex,
                                          isDecodable: { UIImage(contentsOfFile: $0.path) != nil }) {
                try writeCover(from: cover, to: item.appendingPathComponent("cover.jpg"))
            }
            let record = LocalItemRecord(itemId: itemId, title: title, sourceFilename: source.lastPathComponent,
                sha256: hash, byteSize: bytes.count, importedAt: Date(), chapters: storedChapters, comicInfo: comicInfo)
            let encoded = try JSONEncoder().encode(record)
            try encoded.write(to: item.appendingPathComponent("item.json"), options: .atomic)
            try? fm.removeItem(at: archive)
            try Task.checkCancellation()
            try fm.moveItem(at: item, to: destination)
            try? fm.removeItem(at: staging)
            return .imported(record)
        } catch {
            try? fm.removeItem(at: staging)
            if error is CancellationError { throw LocalImportError.cancelled }
            throw error
        }
    }

    private func readComicInfo(from reader: ZipArchiveReader) throws -> ComicInfo? {
        guard let entry = reader.listEntries().first(where: {
            !$0.isDirectory && !$0.name.contains("/") && $0.name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame
        }) else { return nil }
        return try? ComicInfo.parse(reader.data(for: entry))
    }

    private func openArchive(at url: URL) throws -> ZipArchiveReader {
        do { return try ZipArchiveReader(url: url) } catch let error as ZipArchiveError {
            throw LocalImportError.unreadableArchive(error)
        }
    }

    private func importPDF(_ request: PDFImportRequest,
                           progress: (@Sendable (LocalImportProgress) -> Void)?) async throws -> LocalImportResult {
        do {
            let pageDir = request.item.appendingPathComponent("pages/1")
            let files = try await PDFPageRasterizer().rasterize(source: request.archive, to: pageDir) { completed, total in
                progress?(LocalImportProgress(fileName: request.source.lastPathComponent, completed: completed, total: total))
            }
            try Task.checkCancellation()
            guard let firstFile = files.first else { throw PDFRasterizationError.unreadable }
            try writeCover(from: pageDir.appendingPathComponent(firstFile), to: request.item.appendingPathComponent("cover.jpg"))
            let chapter = LocalChapter(number: 1, title: request.title, pageCount: files.count, pageFiles: files)
            let record = LocalItemRecord(itemId: request.itemId, title: request.title, sourceFilename: request.source.lastPathComponent,
                                         sha256: request.hash, byteSize: request.byteSize, importedAt: Date(), chapters: [chapter])
            let encoded = try JSONEncoder().encode(record)
            try encoded.write(to: request.item.appendingPathComponent("item.json"), options: .atomic)
            try? fm.removeItem(at: request.archive)
            try Task.checkCancellation()
            if fm.fileExists(atPath: request.destination.appendingPathComponent("item.json").path) {
                try? fm.removeItem(at: request.staging)
                return .duplicate(itemId: request.itemId)
            }
            try fm.moveItem(at: request.item, to: request.destination)
            try? fm.removeItem(at: request.staging)
            return .imported(record)
        } catch is CancellationError {
            throw LocalImportError.cancelled
        } catch let error as PDFRasterizationError {
            if error == .passwordProtected { throw LocalImportError.passwordProtectedPDF }
            throw LocalImportError.unreadablePDF
        } catch {
            throw isOutOfSpace(error) ? LocalImportError.insufficientSpace : LocalImportError.unreadablePDF
        }
    }

    func record(itemId: String) -> LocalItemRecord? {
        let url = root.appendingPathComponent(itemId).appendingPathComponent("item.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalItemRecord.self, from: data)
    }

    func allRecords() -> [LocalItemRecord] {
        guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.lastPathComponent != ".staging" }
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("item.json")) }
            .compactMap { try? JSONDecoder().decode(LocalItemRecord.self, from: $0) }
    }

    func pageURLs(itemId: String, chapter: Int) -> [URL] {
        guard let record = record(itemId: itemId),
              let chapterRecord = record.chapters.first(where: { $0.number == chapter }) else { return [] }
        return chapterRecord.pageFiles.map { root.appendingPathComponent(itemId).appendingPathComponent("pages/\(chapter)/\($0)") }
    }

    func coverURL(itemId: String) -> URL? {
        let url = root.appendingPathComponent(itemId).appendingPathComponent("cover.jpg")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func itemSize(itemId: String) -> Int {
        let item = root.appendingPathComponent(itemId)
        return (fm.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { value in
            guard let url = value as? URL else { return nil }
            return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)) ?? 0
    }

    func usage() -> (count: Int, bytes: Int) {
        let records = allRecords()
        return (records.count, records.reduce(0) { $0 + itemSize(itemId: $1.itemId) })
    }

    func delete(itemId: String) throws {
        try fm.removeItem(at: root.appendingPathComponent(itemId))
    }

    private func writeCover(from source: URL, to destination: URL) throws {
        guard let image = UIImage(contentsOfFile: source.path), let cgImage = image.cgImage else {
            throw PDFRasterizationError.pageUnreadable(0)
        }
        let scale = min(1, 512 / max(CGFloat(cgImage.width), CGFloat(cgImage.height)))
        let size = CGSize(width: max(1, floor(CGFloat(cgImage.width) * scale)),
                          height: max(1, floor(CGFloat(cgImage.height) * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = thumbnail.jpegData(compressionQuality: 0.9) else { throw PDFRasterizationError.pageUnreadable(0) }
        try data.write(to: destination, options: .atomic)
    }

    private func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError
    }

    private func chapterGroups(from chapters: [ZipArchiveReader.Chapter], title: String) -> [(String, [ZipArchiveReader.Entry])] {
        let sorted = chapters.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let root = sorted.first(where: { $0.name == "Root" })
        let folders = sorted.filter { $0.name != "Root" }
        guard folders.count > 1 else {
            guard let folder = folders.first else { return [(title, root?.pages ?? [])] }
            return root.map { [("Root", $0.pages), (folder.name, folder.pages)] } ?? [(title, folder.pages)]
        }
        return (root.map { [("Root", $0.pages)] } ?? []) + folders.map { ($0.name, $0.pages) }
    }

    static func chapterLabel(for comicInfo: ComicInfo?, fallback: String, isSingleChapter: Bool = true) -> String {
        guard isSingleChapter else { return fallback }
        if let volume = comicInfo?.volume, let number = comicInfo?.number { return "Vol. \(volume) · Ch. \(number)" }
        if let number = comicInfo?.number { return "Ch. \(number)" }
        if let volume = comicInfo?.volume { return "Vol. \(volume)" }
        return comicInfo?.title ?? fallback
    }

    static func coverPage(pageURLs: [URL], frontCoverPageIndex: Int?, isDecodable: (URL) -> Bool) -> URL? {
        if let index = frontCoverPageIndex, pageURLs.indices.contains(index), isDecodable(pageURLs[index]) {
            return pageURLs[index]
        }
        for pageURL in pageURLs where isDecodable(pageURL) { return pageURL }
        return nil
    }
}
