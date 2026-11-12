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

    fileprivate var spoken: String {
        switch self {
        case .sameEntry: return "same entry"
        case .likely: return "likely"
        case .differentEntry: return "different entry"
        case .ungraded: return "ungraded"
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

    var id: ListingKey { ListingKey(manga) }

    var accessibilityLabel: String {
        var value = "\(manga.title), \(sourceName), \(grade.spoken)"
        if let alternate = matchedAlternateTitle {
            value += ", also known as \(alternate)"
        }
        if let count = chapterCount {
            value += ", \(count) chapters"
        } else {
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
        guard let other = works.workId(for: ListingKey(row.manga)),
              let work = works.workId(for: ListingKey(listing)) ?? Optional(coordinator.ensureWork(for: listing)) else {
            return .failed("Could not combine these Sources")
        }
        await coordinator.combine(other, into: work)
        if works.work(work)?.listings.contains(ListingKey(row.manga)) != true {
            let result = await coordinator.add(row.manga, to: work, recordExternalIds: true)
            guard case .added = result else { return .failed("Could not add this Source") }
        }
        return added()
    }

    func moveJustThisCopy(_ row: AddSourceRow) async -> AddSourceDecision {
        guard let other = works.workId(for: ListingKey(row.manga)) else { return .failed("Could not move this Source") }
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
        let available = registry.visibleSources(includeAdult: true).filter {
            $0.id != LocalSource.sourceID && !excludedSourceIDs.contains($0.id)
        }
        lastSpellings = spellings
        emptyMessage = nil
        guard !available.isEmpty else {
            phase = .noOtherSources
            groups = []
            emptyMessage = "No other Sources to search"
            return
        }
        phase = .searching
        let outcomes = await searcher.search(spellings: spellings, excluding: excludedSourceIDs)
        groups = outcomes.map { makeGroup($0, spellings: spellings) }
        phase = .loaded
        let hasFailure = groups.contains {
            $0.status == .couldNotCheckTimedOut || $0.status == .couldNotCheckFailed
        }
        emptyMessage = hasFailure ? "No results on the Sources that answered" :
            (groups.contains(where: { !$0.rows.isEmpty }) ? nil : "No results on your Sources")
        await loadCounts()
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
        var top: [Manga] = []
        for group in groups {
            top.append(contentsOf: group.rows.filter { $0.grade == .sameEntry || $0.grade == .likely }.map(\.manga))
        }
        let loaded = await counts.load(top)
        groups = groups.map { group in
            var next = group
            next.rows = group.rows.map { row in
                var updated = row; updated.chapterCount = loaded[row.id]; return updated
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
