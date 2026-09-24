import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let mangaCartaCBZ = UTType(exportedAs: "com.mangacarta.cbz", conformingTo: .zip)
}

@MainActor
final class LocalImportViewModel: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var current: LocalImportProgress?
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles = 0
    @Published private(set) var errors: [String] = []

    private var task: Task<Void, Never>?
    private var local: LocalLibraryStore = .shared
    private weak var library: LibraryStore?
    private weak var works: WorkStore?

    func configure(registry: SourceRegistry, library: LibraryStore, works: WorkStore) {
        if let source = registry.source(id: LocalSource.sourceID) as? LocalSource {
            local = source.store
        }
        self.library = library
        self.works = works
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        current = nil
        errors = []
        completedFiles = 0
        totalFiles = urls.count
        let local = self.local
        task = Task { [weak self] in
            for url in urls {
                guard !Task.isCancelled else { break }
                let accessing = url.startAccessingSecurityScopedResource()
                do {
                    let result = try await local.importArchive(at: url) { progress in
                        Task { @MainActor [weak self] in self?.current = progress }
                    }
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    if case .imported(let record) = result {
                        let cover = await local.coverURL(itemId: record.itemId)
                        await MainActor.run {
                            guard let self, let library = self.library else { return }
                            let manga = Manga(id: record.itemId, sourceId: LocalSource.sourceID,
                                              title: record.title, description: "", status: "completed",
                                              year: nil, coverURL: cover, malId: nil)
                            library.toggle(manga)
                            library.setChapterNumbers(record.chapters.map { "\($0.number)" }, for: record.itemId)
                            _ = self.works
                        }
                    } else if case .duplicate = result {
                        await MainActor.run { self?.errors.append("\(url.lastPathComponent): Already in your library") }
                    }
                } catch {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    await MainActor.run { self?.errors.append("\(url.lastPathComponent): \(Self.message(for: error))") }
                }
                await MainActor.run { self?.completedFiles += 1 }
            }
            await MainActor.run {
                self?.isImporting = false
                self?.current = nil
            }
        }
    }

    func cancel() { task?.cancel() }

    private static func message(for error: Error) -> String {
        if case LocalImportError.noImages = error { return "No images found" }
        if case LocalImportError.unreadableArchive = error { return "Not a supported archive" }
        return error.localizedDescription
    }
}
