import Foundation
import Combine

enum AddSourcePhase: Equatable { case idle, searching, loaded, noOtherSources }

enum AddSourceGroupStatus: Equatable {
    case results, noResults, couldNotCheckTimedOut, couldNotCheckFailed
}

enum AddSourceGrade: String, Equatable {
    case sameEntry, likely, differentEntry, ungraded

    fileprivate var rank: Int {
        switch self {
        case .sameEntry: return 0
        case .likely: return 1
        case .ungraded: return 2
        case .differentEntry: return 3
        }
    }

    /// The grade as the sheet shows and speaks it (design §2). An ungraded row has none.
    var label: String? {
        switch self {
        case .sameEntry: return "Same MyAnimeList entry"
        case .likely: return "Likely match"
        case .differentEntry: return "Different MyAnimeList entry"
        case .ungraded: return nil
        }
    }
}

struct AddSourceRow: Identifiable {
    let manga: Manga
    let sourceName: String
    let grade: AddSourceGrade
    let matchedAlternateTitle: String?
    let isAlreadyLinked: Bool
    let wasRemovedEarlier: Bool
    var chapterCount: Int?
    var countRequested: Bool = false

    var id: ListingKey { ListingKey(manga) }

    var accessibilityLabel: String {
        var value = "\(manga.title), \(sourceName)"
        if let grade = grade.label { value += ", \(grade)" }
        if let alternate = matchedAlternateTitle {
            value += ", also known as \(alternate)"
        }
        if countRequested, let count = chapterCount {
            value += ", \(count) chapters"
        } else if countRequested {
            value += ", chapter count unknown"
        }
        return value
    }
}

struct AddSourceGroup {
    let sourceId: String
    let sourceName: String
    var rows: [AddSourceRow]
    var status: AddSourceGroupStatus
}

enum AddSourceDecision: Equatable {
    case added
    case unavailable
    case confirmDifferentEntry(otherTitle: String)
    case confirmCombine(otherTitle: String)
    case confirmCombineOrMove(otherTitle: String)
    case failed(String)
}

@MainActor
final class AddSourceModel: ObservableObject {
    @Published var query: String
    @Published private(set) var phase: AddSourcePhase = .idle
    @Published private(set) var groups: [AddSourceGroup] = []
    @Published private(set) var emptyMessage: String?
    @Published var didAdd = false

    private let listing: Manga
    private let registry: SourceRegistry
    private let works: WorkStore
    private let coordinator: WorkSourcesCoordinator
    private let searcher: SourceTitleSearch
    private let counts: MALHubChapterCountLoader
    private let matcher: MALTitleMatcher
    private var lastSpellings: [String] = []
    /// The Work each row's add collided with, from `pick`. A collision can come from the other
    /// Work owning the copy's MAL id while not holding the copy itself, so it can't be
    /// recovered later by looking the copy up.
    private var conflicts: [ListingKey: WorkID] = [:]

    init(listing: Manga, registry: SourceRegistry, works: WorkStore,
         coordinator: WorkSourcesCoordinator, search: SourceTitleSearch,
         counts: MALHubChapterCountLoader, matcher: MALTitleMatcher = .init()) {
        self.listing = listing; self.registry = registry; self.works = works
        self.coordinator = coordinator; self.searcher = search; self.counts = counts; self.matcher = matcher
        let key = ListingKey(listing)
        query = works.workId(for: key).flatMap(works.work)?.displayTitle ?? listing.title
    }

    func start() async { await perform(spellings: spellingsForWork()) }

    func submit() async { await perform(spellings: [query]) }

    func retry(sourceId: String) async {
        guard !lastSpellings.isEmpty else { return }
        let outcomes = await searcher.search(spellings: lastSpellings, sourceIDs: [sourceId], excluding: excludedSourceIDs)
        guard let outcome = outcomes.first else { return }
        let replacement = makeGroup(outcome, spellings: lastSpellings)
        groups = groups.map { $0.sourceId == sourceId ? replacement : $0 }
        updateEmptyMessage()
        await loadCounts()
    }

    func pick(_ row: AddSourceRow) async -> AddSourceDecision {
        if row.isAlreadyLinked { return .unavailable }
        if row.grade == .differentEntry {
            return .confirmDifferentEntry(otherTitle: row.manga.title)
        }
        let work = coordinator.ensureWork(for: listing)
        let result = await coordinator.add(row.manga, to: work, recordExternalIds: true)
        return await decision(for: result, row: row, work: work)
    }

    func addAnyway(_ row: AddSourceRow) async -> AddSourceDecision {
        let work = coordinator.ensureWork(for: listing)
        let result = await coordinator.add(row.manga, to: work, recordExternalIds: false)
        guard case .added = result else { return .failed("Could not add this Source") }
        return added()
    }

    func combine(_ row: AddSourceRow) async -> AddSourceDecision {
        guard let other = conflicts[row.id] ?? works.workId(for: row.id) else {
            return .failed("Could not combine these Sources")
        }
        let work = coordinator.ensureWork(for: listing)
        await coordinator.combine(other, into: work)
        if works.work(work)?.listings.contains(ListingKey(row.manga)) != true {
            let result = await coordinator.add(row.manga, to: work, recordExternalIds: true)
            guard case .added = result else { return .failed("Could not add this Source") }
        }
        return added()
    }

    func moveJustThisCopy(_ row: AddSourceRow) async -> AddSourceDecision {
        guard let other = works.workId(for: row.id) else { return .failed("Could not move this Source") }
        let work = coordinator.ensureWork(for: listing)
        guard case .removed = await coordinator.move(ListingKey(row.manga), from: other, to: work) else {
            return .failed("Could not move this Source")
        }
        return added()
    }

    private var excludedSourceIDs: Set<String> {
        guard let id = works.workId(for: ListingKey(listing)), let work = works.work(id) else { return [] }
        return Set(work.listings.map(\.sourceId))
    }

    private func spellingsForWork() -> [String] {
        guard let id = works.workId(for: ListingKey(listing)), let work = works.work(id) else {
            return [listing.title] + (listing.altTitles ?? [])
        }
        return [work.displayTitle] + work.knownTitles.filter { $0 != work.displayTitle }
    }

    private func perform(spellings: [String]) async {
        lastSpellings = spellings
        emptyMessage = nil
        phase = .searching
        // The search picks the Sources (visible, non-Local, adult per the setting), so "no
        // other Sources" is its answer, not a second guess at the same filter.
        let outcomes = await searcher.search(spellings: spellings, excluding: excludedSourceIDs)
        guard !outcomes.isEmpty else {
            phase = .noOtherSources
            groups = []
            emptyMessage = "No other Sources to search"
            return
        }
        groups = outcomes.map { makeGroup($0, spellings: spellings) }
        phase = .loaded
        updateEmptyMessage()
        await loadCounts()
    }

    private func updateEmptyMessage() {
        guard !groups.contains(where: { !$0.rows.isEmpty }) else { emptyMessage = nil; return }
        let hasFailure = groups.contains {
            $0.status == .couldNotCheckTimedOut || $0.status == .couldNotCheckFailed
        }
        emptyMessage = hasFailure ? "No results on the Sources that answered" : "No results on your Sources"
    }

    private func makeGroup(_ outcome: SourceTitleSearch.SourceOutcome, spellings: [String]) -> AddSourceGroup {
        switch outcome.result {
        case .timedOut:
            return AddSourceGroup(sourceId: outcome.sourceId, sourceName: outcome.sourceName, rows: [], status: .couldNotCheckTimedOut)
        case .failed:
            return AddSourceGroup(sourceId: outcome.sourceId, sourceName: outcome.sourceName, rows: [], status: .couldNotCheckFailed)
        case .found(let results):
            let rows = results.map { makeRow($0, sourceName: outcome.sourceName, spellings: spellings) }
                .sorted { $0.grade.rank < $1.grade.rank }
            return AddSourceGroup(sourceId: outcome.sourceId, sourceName: outcome.sourceName, rows: rows,
                                  status: rows.isEmpty ? .noResults : .results)
        }
    }

    private func makeRow(_ manga: Manga, sourceName: String, spellings: [String]) -> AddSourceRow {
        let currentWork = works.workId(for: ListingKey(listing)).flatMap(works.work)
        let mal = currentWork?.externalIds.mal ?? listing.malId
        let grade: AddSourceGrade
        if let rowMal = manga.malId, let mal {
            grade = rowMal == mal ? .sameEntry : .differentEntry
        } else {
            let score = matcher.rankedScores(sourceTitles: spellings,
                                             candidates: [(id: manga.id, titles: [manga.title] + (manga.altTitles ?? []))]).first?.score ?? 0
            grade = score >= matcher.acceptanceThreshold ? .likely : .ungraded
        }
        let normalizedSpellings = Set(spellings.map(MALTitleMatcher.normalize))
        let alternate = manga.altTitles?.first {
            normalizedSpellings.contains(MALTitleMatcher.normalize($0)) &&
                MALTitleMatcher.normalize(manga.title) != MALTitleMatcher.normalize($0)
        }
        let key = ListingKey(manga)
        let linked = currentWork?.listings.contains(key) == true
        let removed = currentWork?.removedListings.contains(where: { $0.key == key }) == true
        return AddSourceRow(manga: manga, sourceName: sourceName, grade: grade,
                            matchedAlternateTitle: alternate, isAlreadyLinked: linked,
                            wasRemovedEarlier: removed, chapterCount: nil)
    }

    private func loadCounts() async {
        // Same-entry rows from every Source first, then likely ones, each in registry order.
        let graded = groups.flatMap(\.rows)
        let top = (graded.filter { $0.grade == .sameEntry } + graded.filter { $0.grade == .likely }).map(\.manga)
        let requested = Set(top.prefix(3).map(ListingKey.init))
        let loaded = await counts.load(Array(top.prefix(3)))
        groups = groups.map { group in
            var next = group
            next.rows = group.rows.map { row in
                var updated = row
                updated.countRequested = requested.contains(row.id)
                updated.chapterCount = loaded[row.id]
                return updated
            }
            return next
        }
    }

    private func decision(for result: WorkStore.AddListingResult, row: AddSourceRow, work: WorkID) async -> AddSourceDecision {
        switch result {
        case .added: return added()
        case .alreadyLinked: return .unavailable
        case .workNotFound: return .failed("Could not add this Source")
        case .belongsToOtherWork(let other):
            conflicts[row.id] = other
            let otherWork = works.work(other)
            guard let otherWork else { return .failed("Could not add this Source") }
            if otherWork.listings.contains(ListingKey(row.manga)) && otherWork.listings.count > 1 {
                return .confirmCombineOrMove(otherTitle: otherWork.displayTitle)
            }
            return .confirmCombine(otherTitle: otherWork.displayTitle)
        }
    }

    private func added() -> AddSourceDecision { didAdd = true; return .added }
}
