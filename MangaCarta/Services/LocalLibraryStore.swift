import CryptoKit
import Foundation
import UIKit

enum LocalImportResult: Equatable {
    case imported(LocalItemRecord)
    case duplicate(itemId: String)
}

enum LocalImportError: Error, Equatable {
    case noImages
    case unreadableArchive(ZipArchiveError)
    case unreadablePDF
    case passwordProtectedPDF
    case cancelled
    case insufficientSpace
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
        let staging = root.appendingPathComponent(".staging").appendingPathComponent(UUID().uuidString)
        let archive = staging.appendingPathComponent("archive")
        let item = staging.appendingPathComponent("item")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: archive)
            let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
            let digest = SHA256.hash(data: bytes)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let itemId = String(hash.prefix(32))
            let destination = root.appendingPathComponent(itemId)
            if fm.fileExists(atPath: destination.appendingPathComponent("item.json").path) {
                try? fm.removeItem(at: staging)
                return .duplicate(itemId: itemId)
            }
            let title = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            let isPDF = bytes.starts(with: Data("%PDF-".utf8))
            if isPDF {
                do {
                    let pageDir = item.appendingPathComponent("pages/1")
                    let files = try await PDFPageRasterizer().rasterize(source: archive, to: pageDir)
                    guard let firstFile = files.first else { throw PDFRasterizationError.unreadable }
                    try writeCover(from: pageDir.appendingPathComponent(firstFile), to: item.appendingPathComponent("cover.jpg"))
                    let chapter = LocalChapter(number: 1, title: title, pageCount: files.count, pageFiles: files)
                    let record = LocalItemRecord(itemId: itemId, title: title, sourceFilename: source.lastPathComponent,
                        sha256: hash, byteSize: bytes.count, importedAt: Date(), chapters: [chapter])
                    let encoded = try JSONEncoder().encode(record)
                    try encoded.write(to: item.appendingPathComponent("item.json"), options: .atomic)
                    try? fm.removeItem(at: archive)
                    if fm.fileExists(atPath: destination.appendingPathComponent("item.json").path) {
                        try? fm.removeItem(at: staging)
                        return .duplicate(itemId: itemId)
                    }
                    try fm.moveItem(at: item, to: destination)
                    try? fm.removeItem(at: staging)
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
            let reader: ZipArchiveReader
            do {
                reader = try ZipArchiveReader(url: archive)
            } catch let error as ZipArchiveError {
                throw LocalImportError.unreadableArchive(error)
            }
            let archiveChapters = try reader.chapters()
            guard !archiveChapters.isEmpty else { throw LocalImportError.noImages }
            let sortedArchive = archiveChapters.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let root = sortedArchive.first(where: { $0.name == "Root" })
            let folders = sortedArchive.filter { $0.name != "Root" }
            let groups: [(String, [ZipArchiveReader.Entry])]
            if folders.count <= 1 {
                if let folder = folders.first, let root {
                    groups = [("Root", root.pages), (folder.name, folder.pages)]
                } else if let folder = folders.first {
                    groups = [(title, folder.pages)]
                } else {
                    groups = [(title, root?.pages ?? [])]
                }
            } else {
                groups = (root.map { [("Root", $0.pages)] } ?? []) + folders.map { ($0.name, $0.pages) }
            }
            try fm.createDirectory(at: item, withIntermediateDirectories: true)
            var storedChapters: [LocalChapter] = []
            for (chapterIndex, group) in groups.enumerated() {
                let pageDir = item.appendingPathComponent("pages/\(chapterIndex + 1)")
                try fm.createDirectory(at: pageDir, withIntermediateDirectories: true)
                var files: [String] = []
                for (pageIndex, entry) in group.1.enumerated() {
                    let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
                    let file = String(format: "%04d.%@", pageIndex + 1, ext)
                    try reader.data(for: entry).write(to: pageDir.appendingPathComponent(file), options: .atomic)
                    files.append(file)
                }
                storedChapters.append(LocalChapter(number: chapterIndex + 1,
                    title: group.0 == "Root" ? title : group.0,
                    pageCount: files.count, pageFiles: files))
            }
            guard let first = storedChapters.first, let firstFile = first.pageFiles.first else { throw LocalImportError.noImages }
            let firstURL = item.appendingPathComponent("pages/1").appendingPathComponent(firstFile)
            guard let image = UIImage(contentsOfFile: firstURL.path),
                  let data = image.jpegData(compressionQuality: 0.9) else {
                throw LocalImportError.noImages
            }
            try data.write(to: item.appendingPathComponent("cover.jpg"), options: .atomic)
            let record = LocalItemRecord(itemId: itemId, title: title, sourceFilename: source.lastPathComponent,
                sha256: hash, byteSize: bytes.count, importedAt: Date(), chapters: storedChapters)
            let encoded = try JSONEncoder().encode(record)
            try encoded.write(to: item.appendingPathComponent("item.json"), options: .atomic)
            try? fm.removeItem(at: archive)
            try fm.moveItem(at: item, to: destination)
            try? fm.removeItem(at: staging)
            return .imported(record)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
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
}
