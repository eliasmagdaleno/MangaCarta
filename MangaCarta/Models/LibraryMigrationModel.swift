import Foundation
import Combine

enum LibraryMigrationStatus: Equatable {
    case ready, needsPick, notFound, couldNotCheck, notSearched
}

struct LibraryMigrationSourceOption: Identifiable, Equatable {
    let sourceId: String
    let name: String
    let savedCount: Int
    let isInstalled: Bool
    var id: String { sourceId }
}

struct LibraryMigrationRow: Identifiable {
    let id: ListingKey
    let item: LibraryItem
    let workId: WorkID?
    let fromSourceId: String
    var status: LibraryMigrationStatus
    var choices: [AddSourceRow]
    var choiceDetails: [LibraryMigrationChoice]
    var chosen: AddSourceRow?
    var isTicked: Bool
    var alreadyOnTarget: ListingKey?
}

struct LibraryMigrationChoice {
    let row: AddSourceRow
    let otherWorkId: WorkID?
    let otherWorkTitle: String?
}

struct LibraryMigrationSummary {
    let migratedCount: Int
    let skipped: [(title: String, reason: MigrationSkipReason)]
}

enum LibraryMigrationPickDecision: Equatable {
    case picked
    case confirmDifferentEntry(otherTitle: String)
    case refusedOwnedByOtherWork
    case unavailable
}

@MainActor
final class LibraryMigrationModel: ObservableObject {
    @Published private(set) var fromOptions: [LibraryMigrationSourceOption] = []
    @Published private(set) var toOptions: [MangaSource] = []
    @Published private(set) var rows: [LibraryMigrationRow] = []
    @Published private(set) var searchedCount = 0
    @Published private(set) var totalToSearch = 0
    @Published private(set) var isSearching = false

    private let library: LibraryStore
    private let works: WorkStore
    private let coordinator: WorkSourcesCoordinator
    private let registry: SourceRegistry
    private let searcher: SourceTitleSearch
    private let counts: MALHubChapterCountLoader
    private let matcher: MALTitleMatcher
    private let sourceName: (String) -> String?
    private let requestRefresh: () async -> Void
    private let concurrency: Int
    private let includeAdult: Bool
    private var cancelled = false
    private var cancelSearch: (() -> Void)?

    init(library: LibraryStore, works: WorkStore, coordinator: WorkSourcesCoordinator,
         registry: SourceRegistry, search: SourceTitleSearch, counts: MALHubChapterCountLoader,
         matcher: MALTitleMatcher = .init(), sourceName: @escaping (String) -> String? = { _ in nil },
         requestRefresh: @escaping () async -> Void = {}, includeAdult: Bool = false,
         concurrency: Int = 4) {
        self.library = library; self.works = works; self.coordinator = coordinator; self.registry = registry
        self.searcher = search; self.counts = counts; self.matcher = matcher; self.sourceName = sourceName
        self.requestRefresh = requestRefresh; self.includeAdult = includeAdult; self.concurrency = max(1, concurrency)
        refreshFromOptions()
    }

    func refreshFromOptions() {
        let items = library.items(in: nil)
        let remote = items.compactMap { $0.sourceId }.filter {
            $0 != LocalSource.sourceID && !InstalledSourceIDMigration.legacyIDs.contains($0)
        }
        let workListings = works.allWorkIds().compactMap(works.work).flatMap { $0.listings }
        let ids = Set(remote + workListings.map(\.sourceId).filter {
            $0 != LocalSource.sourceID && !InstalledSourceIDMigration.legacyIDs.contains($0)
        })
        fromOptions = ids.compactMap { id in
            let count = items.filter { item in
                if item.sourceId == id { return true }
                guard let workId = works.workId(for: ListingKey(sourceId: item.sourceId ?? LegacySourceID.unattributed, mangaId: item.id)),
                      let work = works.work(workId) else { return false }
                return work.listings.contains { $0.sourceId == id }
            }.count
            guard count > 0 else { return nil }
            return LibraryMigrationSourceOption(sourceId: id, name: registry.source(id: id)?.name ?? sourceName(id) ?? id,
                                                savedCount: count, isInstalled: registry.source(id: id) != nil)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func toOptions(from sourceId: String) -> [MangaSource] {
        registry.visibleSources(includeAdult: includeAdult).filter { $0.id != LocalSource.sourceID && $0.id != sourceId }
    }

    func candidates(from sourceId: String, to targetId: String) {
        rows = library.items(in: nil).compactMap { item in
            let ownKey = ListingKey(sourceId: item.sourceId ?? LegacySourceID.unattributed, mangaId: item.id)
            let workId = works.workId(for: ownKey)
            let work = workId.flatMap(works.work)
            guard item.sourceId == sourceId || work?.listings.contains(where: { $0.sourceId == sourceId }) == true else { return nil }
            let targetKey = work?.listings.first(where: { $0.sourceId == targetId })
            let ready = targetKey != nil
            return LibraryMigrationRow(id: ownKey, item: item, workId: workId, fromSourceId: sourceId,
                                       status: ready ? .ready : .notSearched, choices: [], choiceDetails: [], chosen: nil,
                                       isTicked: ready, alreadyOnTarget: targetKey)
        }
        totalToSearch = rows.filter { $0.status == .notSearched }.count
        searchedCount = 0; cancelled = false
    }

    func start(from sourceId: String, to targetId: String) async {
        candidates(from: sourceId, to: targetId); await searchRemaining(targetId: targetId)
    }

    func cancel() {
        cancelled = true
        cancelSearch?()
    }

    private func searchRemaining(targetId: String) async {
        isSearching = true; defer { isSearching = false }
        let indexes = rows.indices.filter { rows[$0].status == .notSearched }
        await withTaskGroup(of: (Int, [SourceTitleSearch.SourceOutcome]?).self) { group in
            let tasks = MigrationSearchTasks()
            cancelSearch = { tasks.cancelAll() }
            defer { cancelSearch = nil }
            var next = indexes.makeIterator()
            func add() {
                if let index = next.next() {
                    let task = Task { [self] in
                        await self.search(row: self.rows[index], targetId: targetId)
                    }
                    tasks.append(task)
                    group.addTask { (index, await task.value) }
                }
            }
            for _ in 0..<concurrency { add() }
            while let (index, outcome) = await group.next() {
                if cancelled { rows[index].status = .notSearched; continue }
                apply(outcome ?? [], at: index, targetId: targetId)
                searchedCount += 1
                if !cancelled { add() }
            }
        }
        guard !cancelled else { return }
        await countReadyRows()
    }

    private func search(row: LibraryMigrationRow, targetId: String) async -> [SourceTitleSearch.SourceOutcome] {
        let work = row.workId.flatMap(works.work)
        let spellings = spellings(for: row)
        return await searcher.search(spellings: spellings, sourceIDs: [targetId]) { mangas in
            mangas.contains {
                SourceMatchGrader.grade(referenceMALID: work?.externalIds.mal,
                                        spellings: spellings, candidate: $0, matcher: self.matcher) == .sameEntry
            }
        }
    }

    private func spellings(for row: LibraryMigrationRow) -> [String] {
        guard let work = row.workId.flatMap(works.work) else { return [row.item.title] }
        return [work.displayTitle] + work.knownTitles.filter { $0 != work.displayTitle }
    }

    private func apply(_ outcomes: [SourceTitleSearch.SourceOutcome], at index: Int, targetId: String) {
        guard let outcome = outcomes.first(where: { $0.sourceId == targetId }) else { rows[index].status = .couldNotCheck; return }
        guard case .found(let mangas) = outcome.result else { rows[index].status = .couldNotCheck; return }
        guard !mangas.isEmpty else { rows[index].status = .notFound; return }
        let work = rows[index].workId.flatMap(works.work)
        let spellings = spellings(for: rows[index])
        var choices: [AddSourceRow] = []
        var details: [LibraryMigrationChoice] = []
        for manga in mangas {
            let grade = SourceMatchGrader.grade(referenceMALID: work?.externalIds.mal,
                                                spellings: spellings, candidate: manga, matcher: matcher)
            let key = ListingKey(manga)
            let owner = works.workId(for: key) ?? (manga.malId.flatMap { works.workId(externalId: ExternalIDs(mal: $0, anilist: nil)) })
            let other = owner.flatMap { id in work?.id == id ? nil : id }
            let row = AddSourceRow(manga: manga, sourceName: outcome.sourceName, grade: grade,
                                        matchedAlternateTitle: nil, isAlreadyLinked: owner == work?.id,
                                        wasRemovedEarlier: work?.removedListings.contains { $0.key == key } == true,
                                        chapterCount: nil)
            choices.append(row)
            details.append(LibraryMigrationChoice(row: row, otherWorkId: other,
                                                  otherWorkTitle: other.flatMap { works.work($0)?.displayTitle }))
        }
        rows[index].choices = choices
        rows[index].choiceDetails = details
        let usable = details.filter { choice in
            choice.row.grade != .ungraded && choice.row.grade != .differentEntry &&
                !choice.row.wasRemovedEarlier && choice.otherWorkId == nil
        }
        let oneLikely = usable.count == 1 && usable[0].row.grade == .likely &&
            details.filter { $0.row.grade == .differentEntry }.isEmpty
        if usable.count == 1 && (usable[0].row.grade == .sameEntry || oneLikely) {
            rows[index].status = .ready; rows[index].chosen = usable[0].row; rows[index].isTicked = true
        } else { rows[index].status = .needsPick; rows[index].isTicked = false }
    }

    private func countReadyRows() async {
        let indexes = Array(rows.indices).filter { index in
            guard rows[index].status == .ready, rows[index].chosen != nil else { return false }
            return rows[index].alreadyOnTarget == nil
        }
        let workItems = indexes.compactMap { index -> (Int, Manga)? in
            guard let manga = rows[index].chosen?.manga else { return nil }
            return (index, manga)
        }
        await withTaskGroup(of: (Int, [ListingKey: Int]).self) { group in
            var next = workItems.makeIterator()
            func add() {
                if let (i, manga) = next.next() {
                    let loader = self.counts
                    group.addTask { (i, await loader.load([manga])) }
                }
            }
            for _ in 0..<min(concurrency, indexes.count) { add() }
            while let (i, values) = await group.next() {
                if let chosen = rows[i].chosen {
                    rows[i].chosen?.chapterCount = values[chosen.id]
                    rows[i].chosen?.countRequested = true
                }
                add()
            }
        }
    }

    private func countReadyRow(_ index: Int) async {
        guard let chosen = rows[index].chosen else { return }
        let values = await counts.load([chosen.manga])
        rows[index].chosen?.chapterCount = values[chosen.id]
        rows[index].chosen?.countRequested = true
    }

    func toggle(_ id: ListingKey) {
        if let i = rows.firstIndex(where: { $0.id == id }),
           rows[i].chosen != nil || rows[i].alreadyOnTarget != nil {
            rows[i].isTicked.toggle()
        }
    }

    func pick(_ id: ListingKey, choice: AddSourceRow, confirmDifferentEntry: Bool = false) -> LibraryMigrationPickDecision {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return .unavailable }
        let work = rows[i].workId.flatMap(works.work)
        let owner = works.workId(for: choice.id) ?? choice.manga.malId.flatMap { works.workId(externalId: ExternalIDs(mal: $0, anilist: nil)) }
        if let owner, owner != work?.id { return .refusedOwnedByOtherWork }
        if choice.grade == .differentEntry && !confirmDifferentEntry { return .confirmDifferentEntry(otherTitle: choice.manga.title) }
        rows[i].chosen = choice; rows[i].isTicked = true; rows[i].status = .needsPick; return .picked
    }

    func retry(_ id: ListingKey, to targetId: String) async {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].status == .couldNotCheck else { return }
        let outcome = await search(row: rows[i], targetId: targetId)
        apply(outcome, at: i, targetId: targetId)
        if rows[i].status == .ready { await countReadyRow(i) }
    }

    func apply(removingOld: Bool) async -> LibraryMigrationSummary {
        var migrated = 0; var skipped: [(String, MigrationSkipReason)] = []
        for row in rows where row.isTicked {
            var workId = row.workId
            if workId == nil {
                let manga = Manga(id: row.item.id, sourceId: row.item.sourceId ?? row.fromSourceId,
                                  title: row.item.title, description: "", status: "unknown", year: nil,
                                  coverURL: row.item.coverURL, malId: nil, altTitles: nil, contentRating: nil)
                workId = coordinator.ensureWork(for: manga)
            }
            guard let workId else { continue }
            let chosen = row.chosen
            let target: Manga
            if let chosen { target = chosen.manga } else if let key = row.alreadyOnTarget {
                target = Manga(id: key.mangaId, sourceId: key.sourceId,
                               title: works.work(workId)?.displayTitle ?? row.item.title,
                               description: "", status: "unknown", year: nil, coverURL: nil,
                               malId: nil, altTitles: nil, contentRating: nil)
            } else { continue }
            let outcome = await coordinator.migrate(workId, to: target, from: row.fromSourceId, removingOld: removingOld)
            switch outcome {
            case .migrated: migrated += 1
            case .skipped(let reason): skipped.append((row.item.title, reason))
            }
        }
        works.flush(); await requestRefresh(); return LibraryMigrationSummary(migratedCount: migrated, skipped: skipped)
    }
}

private final class MigrationSearchTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<[SourceTitleSearch.SourceOutcome], Never>] = []

    func append(_ task: Task<[SourceTitleSearch.SourceOutcome], Never>) {
        lock.lock(); tasks.append(task); lock.unlock()
    }

    func cancelAll() {
        lock.lock(); let pending = tasks; lock.unlock()
        pending.forEach { $0.cancel() }
    }
}
