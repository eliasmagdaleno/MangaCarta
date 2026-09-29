import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let mangaCartaCBZ = UTType(importedAs: "com.mangacarta.cbz", conformingTo: .zip)
}

@MainActor
final class LocalImportViewModel: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var current: LocalImportProgress?
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles = 0
    @Published private(set) var errors: [String] = []

    private var task: Task<Void, Never>?
    private var pendingURLs: [URL] = []
    private var openedURLs: Set<URL> = []
    private var local: LocalLibraryStore = .shared
    private weak var library: LibraryStore?
    private weak var works: WorkStore?

    private let containerRoot: URL

    init(containerRoot: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.containerRoot = containerRoot.standardizedFileURL
    }

    func configure(registry: SourceRegistry, library: LibraryStore, works: WorkStore) {
        if let source = registry.source(id: LocalSource.sourceID) as? LocalSource {
            local = source.store
        }
        self.library = library
        self.works = works
    }

    // Each branch keeps one file's outcome adjacent to its cleanup and progress update.
    // swiftlint:disable:next cyclomatic_complexity
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingURLs.append(contentsOf: urls)
        if isImporting { totalFiles += urls.count; return }
        isImporting = true
        current = nil
        errors = []
        completedFiles = 0
        totalFiles = pendingURLs.count
        let local = self.local
        task = Task { [weak self] in
            while true {
                guard let self else { break }
                guard !self.pendingURLs.isEmpty else { break }
                let url = self.pendingURLs.removeFirst()
                let shouldDelete = self.openedURLs.remove(url.standardizedFileURL) != nil
                if Task.isCancelled {
                    if shouldDelete { Self.deleteIfOwned(url, by: self.containerRoot) }
                    break
                }
                let accessing = url.startAccessingSecurityScopedResource()
                do {
                    let result = try await local.importArchive(at: url) { [weak self] progress in
                        Task { @MainActor [weak self] in self?.current = progress }
                    }
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    if case .imported(let record) = result {
                        let cover = await local.coverURL(itemId: record.itemId)
                        await MainActor.run {
                            guard let library = self.library else { return }
                            let manga = Manga(id: record.itemId, sourceId: LocalSource.sourceID,
                                              title: record.title, description: record.comicInfo?.summary ?? "", status: "completed",
                                              year: nil, coverURL: cover, malId: nil)
                            library.toggle(manga)
                            library.setChapterNumbers(record.chapters.map { "\($0.number)" }, for: record.itemId)
                        }
                    } else if case .duplicate = result {
                        await MainActor.run { self.errors.append("\(url.lastPathComponent): Already in your library") }
                    }
                } catch {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    if case LocalImportError.cancelled = error {
                        // User cancellation is intentionally silent.
                    } else {
                        await MainActor.run { self.errors.append("\(url.lastPathComponent): \(Self.message(for: error))") }
                    }
                }
                if shouldDelete { Self.deleteIfOwned(url, by: self.containerRoot) }
                await MainActor.run { self.completedFiles += 1 }
            }
            await MainActor.run {
                self?.isImporting = false
                self?.current = nil
            }
        }
    }

    func importOpenedURL(_ url: URL) {
        guard url.isFileURL else { return }
        openedURLs.insert(url.standardizedFileURL)
        importFiles([url])
    }

    private static func deleteIfOwned(_ url: URL, by root: URL) {
        let candidate = url.standardizedFileURL
        let container = root.standardizedFileURL
        let prefix = container.path.hasSuffix("/") ? container.path : container.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    /// Synchronous facade for deterministic launch fixtures; it still executes the exact
    /// asynchronous importer used by the Files picker and waits for every result.
    func importFilesAndWait(_ urls: [URL]) async {
        importFiles(urls)
        await task?.value
    }

    func cancel() {
        task?.cancel()
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued where openedURLs.remove(url.standardizedFileURL) != nil {
            Self.deleteIfOwned(url, by: containerRoot)
        }
    }

    private static func message(for error: Error) -> String {
        if case LocalImportError.noImages = error { return "No images found" }
        if case LocalImportError.unreadableArchive = error { return "Not a supported archive" }
        if case LocalImportError.unreadablePDF = error { return "Could not read this PDF" }
        if case LocalImportError.passwordProtectedPDF = error { return "This PDF is password-protected" }
        if case LocalImportError.cancelled = error { return "Import cancelled" }
        if case LocalImportError.insufficientSpace = error { return "Not enough storage available" }
        return error.localizedDescription
    }
}
