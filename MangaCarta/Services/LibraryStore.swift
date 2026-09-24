//
//  LibraryStore.swift
//  MangaCarta
//
//  A lightweight, persisted "Library" of saved manga with multi-collection support.
//  Stores item metadata and collection assignments, backed by UserDefaults.
//

import SwiftUI

/// A saved manga snapshot. Kept small and Codable for on-device persistence.
struct LibraryItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let coverURL: URL?
    var chapterNumbers: [String]? = nil   // deduped chapter numbers from last refresh; nil = never refreshed
    var sourceId: String? = nil   // nil = saved before multi-source; treat as MangaDex
    var collectionIds: Set<String> = [LibraryCollection.readingID]

    enum CodingKeys: String, CodingKey {
        case id, title, coverURL, chapterNumbers, sourceId, collectionIds
    }

    init(
        id: String,
        title: String,
        coverURL: URL?,
        chapterNumbers: [String]? = nil,
        sourceId: String? = nil,
        collectionIds: Set<String> = [LibraryCollection.readingID]
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.chapterNumbers = chapterNumbers
        self.sourceId = sourceId
        self.collectionIds = collectionIds.isEmpty ? [LibraryCollection.readingID] : collectionIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        coverURL = try container.decodeIfPresent(URL.self, forKey: .coverURL)
        chapterNumbers = try container.decodeIfPresent([String].self, forKey: .chapterNumbers)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId)

        if let decodedCollectionIds = try container.decodeIfPresent(Set<String>.self, forKey: .collectionIds),
           !decodedCollectionIds.isEmpty {
            collectionIds = decodedCollectionIds
        } else {
            // Default legacy items without collectionIds to the primary "reading" collection
            collectionIds = [LibraryCollection.readingID]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(coverURL, forKey: .coverURL)
        try container.encodeIfPresent(chapterNumbers, forKey: .chapterNumbers)
        try container.encodeIfPresent(sourceId, forKey: .sourceId)
        try container.encode(collectionIds, forKey: .collectionIds)
    }
}

extension LibraryItem {
    /// Chapters not yet read, given this manga's read chapter numbers from `HistoryStore`.
    /// Returns 0 until the first successful refresh populates `chapterNumbers`.
    func unreadCount(readNumbers: Set<String>) -> Int {
        guard let chapterNumbers else { return 0 }
        return chapterNumbers.filter { !readNumbers.contains($0) }.count
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var collections: [LibraryCollection] = []
    @Published private(set) var isRefreshing = false

    private let itemsKey = "library.items"
    private let collectionsKey = "library.collections"
    private let defaults: UserDefaults
    /// Saving is a commitment, so it mints a Work (ADR-0007). Optional because the
    /// library predates the Work store and most tests have no interest in it; the
    /// app wires it in `MangaCartaApp`.
    private let works: WorkStore?
    /// Resolves each saved item's own source during `refresh()`. Injectable so tests can
    /// register stub sources; the app uses the shared registry.
    private let registryOverride: SourceRegistry?
    private weak var refreshCoordinator: LibraryRefreshCoordinator?
    private var registry: SourceRegistry { registryOverride ?? .shared }

    init(defaults: UserDefaults = .standard, works: WorkStore? = nil, registry: SourceRegistry? = nil) {
        self.defaults = defaults
        self.works = works
        self.registryOverride = registry
        loadCollections()
        loadItems()
    }

    // MARK: - Querying Items & Collections

    func contains(_ id: String) -> Bool {
        items.contains { $0.id == id }
    }

    func item(for id: String) -> LibraryItem? {
        items.first { $0.id == id }
    }

    /// Active enabled collections sorted by `sortOrder`.
    var enabledCollections: [LibraryCollection] {
        collections.filter(\.isEnabled).sorted(by: { $0.sortOrder < $1.sortOrder })
    }

    /// Returns saved items filtered by collection ID.
    /// If `collectionId` is nil or "all", returns all saved items.
    func items(in collectionId: String?) -> [LibraryItem] {
        guard let collectionId, collectionId != "all" else { return items }
        return items.filter { $0.collectionIds.contains(collectionId) }
    }

    /// Returns whether a manga belongs to a specific collection ID.
    func isManga(_ mangaId: String, in collectionId: String) -> Bool {
        item(for: mangaId)?.collectionIds.contains(collectionId) ?? false
    }

    /// Returns the collection IDs assigned to a given manga.
    func collectionIds(for mangaId: String) -> Set<String> {
        item(for: mangaId)?.collectionIds ?? []
    }

    // MARK: - Managing Items & Collection Membership

    /// Toggle manga in/out of library: if present, removes from all collections; if absent, adds to default primary collection.
    func toggle(_ manga: Manga) {
        if contains(manga.id) {
            // Unsaving is not an anti-commitment: the Work stays (ADR-0007).
            items.removeAll { $0.id == manga.id }
        } else {
            _ = works?.mint(from: manga)
            let primaryCollectionId = enabledCollections.first?.id ?? LibraryCollection.readingID
            items.insert(
                LibraryItem(
                    id: manga.id,
                    title: manga.title,
                    coverURL: manga.coverURL,
                    sourceId: manga.sourceId,
                    collectionIds: [primaryCollectionId]
                ),
                at: 0
            )
        }
        saveItems()
    }

    /// Toggle a specific collection membership for a manga.
    func toggleCollection(for manga: Manga, collectionId: String) {
        if let idx = items.firstIndex(where: { $0.id == manga.id }) {
            var updated = items[idx]
            if updated.collectionIds.contains(collectionId) {
                updated.collectionIds.remove(collectionId)
                if updated.collectionIds.isEmpty {
                    items.remove(at: idx)
                } else {
                    items[idx] = updated
                }
            } else {
                _ = works?.mint(from: manga)
                updated.collectionIds.insert(collectionId)
                items[idx] = updated
            }
        } else {
            _ = works?.mint(from: manga)
            items.insert(
                LibraryItem(
                    id: manga.id,
                    title: manga.title,
                    coverURL: manga.coverURL,
                    sourceId: manga.sourceId,
                    collectionIds: [collectionId]
                ),
                at: 0
            )
        }
        saveItems()
    }

    /// Explicitly update the set of collection IDs for a manga.
    func setCollections(for manga: Manga, collectionIds: Set<String>) {
        if collectionIds.isEmpty {
            // Clearing every collection is a removal — nothing to mint.
            items.removeAll { $0.id == manga.id }
            saveItems()
            return
        }
        _ = works?.mint(from: manga)
        if let idx = items.firstIndex(where: { $0.id == manga.id }) {
            items[idx].collectionIds = collectionIds
        } else {
            items.insert(
                LibraryItem(
                    id: manga.id,
                    title: manga.title,
                    coverURL: manga.coverURL,
                    sourceId: manga.sourceId,
                    collectionIds: collectionIds
                ),
                at: 0
            )
        }
        saveItems()
    }

    // MARK: - Managing Collections CRUD

    func addCustomCollection(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let maxOrder = collections.map(\.sortOrder).max() ?? -1
        let newCollection = LibraryCollection(
            id: UUID().uuidString,
            name: trimmed,
            isSystem: false,
            isEnabled: true,
            sortOrder: maxOrder + 1
        )
        collections.append(newCollection)
        saveCollections()
    }

    func renameCustomCollection(id: String, newName: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id && !$0.isSystem }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collections[idx].name = trimmed
        saveCollections()
    }

    func setCollectionEnabled(id: String, isEnabled: Bool) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].isEnabled = isEnabled
        saveCollections()
    }

    func deleteCustomCollection(id: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id && !$0.isSystem }) else { return }
        collections.remove(at: idx)
        saveCollections()

        // Clean up items that belonged to the deleted custom collection
        var updatedItems: [LibraryItem] = []
        for var item in items {
            item.collectionIds.remove(id)
            if !item.collectionIds.isEmpty {
                updatedItems.append(item)
            }
        }
        items = updatedItems
        saveItems()
    }

    func moveCollection(fromOffsets source: IndexSet, toOffset destination: Int) {
        collections.move(fromOffsets: source, toOffset: destination)
        for idx in collections.indices {
            collections[idx].sortOrder = idx
        }
        saveCollections()
    }

    // MARK: - Refreshing

    func configureRefreshCoordinator(_ coordinator: LibraryRefreshCoordinator) {
        refreshCoordinator = coordinator
    }

    /// Refresh every saved manga's full chapter-number list concurrently. Best-effort:
    /// per-item failures leave that item's existing `chapterNumbers` untouched.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if let refreshCoordinator {
            await refreshCoordinator.refreshLibrary()
            return
        }

        // Pair each item with the source it was saved from, up front on the main actor:
        // asking the active browse source for every id sends e.g. a WeebCentral slug to
        // MangaDex. A nil `sourceId` predates multi-source and means MangaDex (as everywhere
        // else); an item whose source is not registered is skipped, not refreshed elsewhere.
        let registry = self.registry
        let current: [(item: LibraryItem, source: MangaSource)] = items.compactMap { item in
            guard let source = registry.sourceForRefresh(sourceId: item.sourceId) else { return nil }
            guard source.participatesInUpdates else { return nil }
            return (item, source)
        }
        let maxConcurrent = 4
        let results: [(String, [String])] = await withTaskGroup(
            of: (String, [String])?.self
        ) { group in
            var iterator = current.makeIterator()

            func addNext() {
                guard let next = iterator.next() else { return }
                let (item, source) = next
                group.addTask {
                    guard let chapters = try? await source.chapters(mangaId: item.id) else { return nil }
                    return (item.id, chapters.map(\.number))
                }
            }

            for _ in 0..<maxConcurrent { addNext() }

            var out: [(String, [String])] = []
            while let result = await group.next() {
                if let result { out.append(result) }
                addNext()
            }
            return out
        }

        var updated = items
        for (id, numbers) in results {
            guard let idx = updated.firstIndex(where: { $0.id == id }) else { continue }
            updated[idx].chapterNumbers = numbers
        }
        items = updated
        saveItems()
    }

    func applyRefreshedChapterNumbers(_ numbers: [ListingKey: [String]]) {
        var updated = items
        for index in updated.indices {
            let key = ListingKey(sourceId: updated[index].sourceId ?? LegacySourceID.unattributed,
                                 mangaId: updated[index].id)
            if let chapterNumbers = numbers[key] { updated[index].chapterNumbers = chapterNumbers }
        }
        items = updated
        saveItems()
    }

    // MARK: - Persistence

    private func saveItems() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: itemsKey)
    }

    private func loadItems() {
        guard let data = defaults.data(forKey: itemsKey),
              let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data)
        else { return }
        items = decoded
    }

    private func saveCollections() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        defaults.set(data, forKey: collectionsKey)
    }

    private func loadCollections() {
        if let data = defaults.data(forKey: collectionsKey),
           let decoded = try? JSONDecoder().decode([LibraryCollection].self, from: data) {
            var merged = decoded
            // Ensure any missing system collection exists
            for sys in LibraryCollection.defaultCollections
            where !merged.contains(where: { $0.id == sys.id }) {
                merged.append(sys)
            }
            collections = merged.sorted(by: { $0.sortOrder < $1.sortOrder })
        } else {
            collections = LibraryCollection.defaultCollections
        }
    }
}
