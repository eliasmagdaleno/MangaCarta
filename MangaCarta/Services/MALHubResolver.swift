import Foundation

struct MALHubChoice: Equatable {
    let manga: Manga
    let sourceName: String
    let kind: Kind
    enum Kind: Equatable { case exact, possible }
}

struct MALHubSourceGroup: Equatable {
    let sourceId: String
    let sourceName: String
    let choices: [MALHubChoice]
    let ambiguous: Bool
    let status: Status
    enum Status: Equatable { case choices, noMatch, couldNotCheckTimedOut, couldNotCheckFailed }
}

enum MALHubResolution: Equatable {
    case open(Manga)
    case chooser([MALHubSourceGroup])
    case notFound([MALHubSourceGroup])
}

/// Whether an interactive challenge is on screen, which suspends the tap-time deadlines
/// (design §5). Both presenters count: `WebViewService`'s and the extension browser's —
/// every remote Source is an extension now, so checking only the first exempted nothing.
enum MALHubChallenge {
    @Sendable static func isActive() async -> Bool {
        await MainActor.run {
            WebViewService.shared.isChallengeActive
                || ExtensionBrowserManager.shared.activeChallenge != nil
        }
    }
}

@MainActor
final class MALHubResolver {
    private let registry: SourceRegistry
    private let store: MALSourceChoiceStore
    private let showAdultContent: Bool
    private let matcher: MALTitleMatcher
    private let titleSearch: SourceTitleSearch
    private let alternativeTitles: @Sendable (Int) async throws -> [String]

    init(registry: SourceRegistry, store: MALSourceChoiceStore, showAdultContent: Bool,
         matcher: MALTitleMatcher = .init(),
         challengeActive: @escaping @Sendable () async -> Bool = MALHubChallenge.isActive,
         deadline: TimeInterval = 8, probeInterval: TimeInterval = 0.25,
         alternativeTitles: @escaping @Sendable (Int) async throws -> [String] = {
             try await MyAnimeListAPI.alternativeTitles(id: $0)
         }) {
        self.registry = registry
        self.store = store
        self.showAdultContent = showAdultContent
        self.matcher = matcher
        self.titleSearch = SourceTitleSearch(registry: registry, showAdultContent: showAdultContent,
                                             challengeActive: challengeActive, deadline: deadline,
                                             probeInterval: probeInterval)
        self.alternativeTitles = alternativeTitles
    }

    func confirm(_ choice: MALHubChoice, for candidate: MALDiscoveryCandidate) async {
        await store.confirm(malId: candidate.malId, sourceId: choice.manga.sourceId,
                            manga: choice.manga, title: candidate.title)
    }

    func resolve(candidate: MALDiscoveryCandidate, detail: MyAnimeListMangaDetail? = nil,
                 sourceIDs: Set<String>? = nil) async -> MALHubResolution {
        if let listing = candidate.resolvedListing { return .open(listing) }
        if let remembered = await store.choice(for: candidate.malId) {
            if let source = registry.source(id: remembered.sourceId), source.isBrowsable,
               !source.isNSFW || showAdultContent, registry.admitsForDiscovery(remembered.manga) {
                do {
                    let fetched = try await source.mangaDetail(id: remembered.manga.id)
                    let refreshed = remembered.manga.with(contentRating: fetched.contentRating)
                    guard registry.admitsForDiscovery(refreshed) else {
                        await store.remove(malId: candidate.malId)
                        return await search(candidate: candidate, detail: detail, sourceIDs: sourceIDs)
                    }
                    return .open(refreshed)
                } catch { }
            } else {
                await store.remove(malId: candidate.malId)
            }
        }
        return await search(candidate: candidate, detail: detail, sourceIDs: sourceIDs)
    }

    /// "Try again" on one Source: re-search it alone and put its answer in place of its old
    /// group, so the other Sources' answers stand and the one-exact-match rule still sees
    /// every Source — a retried Source's lone exact match must not open over others'.
    func retry(sourceID: String, candidate: MALDiscoveryCandidate, detail: MyAnimeListMangaDetail?,
               keeping groups: [MALHubSourceGroup]) async -> MALHubResolution {
        let fresh = await searchGroups(candidate: candidate, detail: detail, sourceIDs: [sourceID])
        guard let replacement = fresh.first else { return Self.classify(groups) }
        let merged = groups.map { $0.sourceId == sourceID ? replacement : $0 }
        return Self.classify(merged)
    }

    private static func classify(_ groups: [MALHubSourceGroup]) -> MALHubResolution {
        let exact = groups.flatMap(\.choices).filter { $0.kind == .exact }
        if exact.count == 1 { return .open(exact[0].manga) }
        return groups.contains { !$0.choices.isEmpty } ? .chooser(groups) : .notFound(groups)
    }

    private func search(candidate: MALDiscoveryCandidate, detail: MyAnimeListMangaDetail?,
                        sourceIDs: Set<String>?) async -> MALHubResolution {
        Self.classify(await searchGroups(candidate: candidate, detail: detail, sourceIDs: sourceIDs))
    }

    private func searchGroups(candidate: MALDiscoveryCandidate, detail: MyAnimeListMangaDetail?,
                              sourceIDs: Set<String>?) async -> [MALHubSourceGroup] {
        var spellings = [detail?.title ?? candidate.title]
        let alternates = detail?.allTitles.dropFirst() ?? []
        if !alternates.isEmpty {
            spellings += Array(alternates.prefix(2))
        } else if let fetched = try? await alternativeTitles(candidate.malId) {
            spellings += Array(fetched.dropFirst().prefix(2))
        }
        spellings = spellings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let outcomes = await titleSearch.search(spellings: spellings, sourceIDs: sourceIDs,
                                                stopWhen: { $0.contains { $0.malId == candidate.malId } })
        return outcomes.map { outcome in
            let source = registry.source(id: outcome.sourceId)!
            switch outcome.result {
            case .timedOut: return group(source, status: .couldNotCheckTimedOut)
            case .failed: return group(source, status: .couldNotCheckFailed)
            case .found(let results):
                return classify(source: source, results: results, candidate: candidate,
                                detail: detail, spellings: spellings)
            }
        }
    }

    private func classify(source: MangaSource, results: [Manga], candidate: MALDiscoveryCandidate,
                          detail: MyAnimeListMangaDetail?, spellings: [String]) -> MALHubSourceGroup {
        let exactFound = results.contains { $0.malId == candidate.malId }
        if exactFound {
            let choices = results.filter { $0.malId == candidate.malId }.map {
                MALHubChoice(manga: $0, sourceName: source.name, kind: .exact)
            }
            return group(source, choices: choices)
        }
        let titles = detail?.allTitles ?? spellings
        let candidates = results.map { (id: $0.id, titles: [$0.title] + ($0.altTitles ?? [])) }
        let scores = matcher.rankedScores(sourceTitles: titles, candidates: candidates)
        guard let top = scores.first, top.score >= matcher.acceptanceThreshold else {
            return group(source, status: .noMatch)
        }
        let ambiguous = scores.count > 1 && top.score - scores[1].score < matcher.ambiguityMargin
        let selected = scores.filter {
            ambiguous ? top.score - $0.score < matcher.ambiguityMargin : $0.id == top.id
        }
        let choices = selected.compactMap { score in
            results.first(where: { $0.id == score.id }).map {
                MALHubChoice(manga: $0, sourceName: source.name, kind: .possible)
            }
        }
        return group(source, choices: choices, ambiguous: ambiguous)
    }

    private func group(_ source: MangaSource, choices: [MALHubChoice] = [], ambiguous: Bool = false,
                       status: MALHubSourceGroup.Status = .choices) -> MALHubSourceGroup {
        MALHubSourceGroup(sourceId: source.id, sourceName: source.name, choices: choices,
                          ambiguous: ambiguous, status: status)
    }

}

private extension Manga {
    func with(contentRating: String?) -> Manga {
        Manga(id: id, sourceId: sourceId, title: title, description: description, status: status,
              year: year, coverURL: coverURL, malId: malId, altTitles: altTitles,
              contentRating: contentRating)
    }
}
