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

    func importArchive(at source: URL) throws -> LocalImportResult {
        try importArchive(at: source, progress: nil)
    }

    func importArchive(at source: URL, progress: (@Sendable (LocalImportProgress) -> Void)?) throws -> LocalImportResult {
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
            let reader: ZipArchiveReader
            do {
                reader = try ZipArchiveReader(url: archive)
            } catch let error as ZipArchiveError {
                throw LocalImportError.unreadableArchive(error)
            }
            let archiveChapters = try reader.chapters()
            guard !archiveChapters.isEmpty else { throw LocalImportError.noImages }
            let title = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            let groups = chapterGroups(from: archiveChapters, title: title)
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
                    progress?(LocalImportProgress(fileName: source.lastPathComponent,
                                                  completed: pageIndex + 1,
                                                  total: group.1.count))
                }
                storedChapters.append(LocalChapter(number: chapterIndex + 1,
                    title: group.0 == "Root" ? title : group.0,
                    pageCount: files.count, pageFiles: files))
            }
            for chapter in storedChapters {
                for pageFile in chapter.pageFiles {
                    let pageURL = item.appendingPathComponent("pages/\(chapter.number)").appendingPathComponent(pageFile)
                    guard let image = UIImage(contentsOfFile: pageURL.path),
                          let data = image.jpegData(compressionQuality: 0.9) else { continue }
                    try data.write(to: item.appendingPathComponent("cover.jpg"), options: .atomic)
                    break
                }
                if fm.fileExists(atPath: item.appendingPathComponent("cover.jpg").path) { break }
            }
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

    func itemSize(itemId: String) -> Int {
        let item = root.appendingPathComponent(itemId)
        return (fm.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { value in
            guard let url = value as? URL else { return nil }
            return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)) ?? 0
    }

    func delete(itemId: String) throws {
        try fm.removeItem(at: root.appendingPathComponent(itemId))
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
}
