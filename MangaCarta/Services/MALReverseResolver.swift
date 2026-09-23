//
//  MALReverseResolver.swift
//  MangaCarta
//
//  The one implementation of MAL-id → openable MangaDex `Manga` reverse resolution.
//  Two callers need it — `MoreLikeThisProvider.recommendations(for:)` (MAL's per-title
//  recommendations) and the AniList ranked pool (ADR-0011) — and they must not each own
//  a copy, because the *cache-write discipline* below is the kind of rule a second
//  implementation gets subtly wrong:
//
//      confident match      → record .resolved
//      searched, no match   → record .unresolved(checkedAt:)
//      search THREW         → record NOTHING
//
//  That last line is the load-bearing one. A transient network failure recorded as
//  `.unresolved` would poison `EntityResolutionStore` against that title for the whole
//  miss TTL, for a reason that had nothing to do with the title.
//
//  Ordering is deliberately NOT here. The two callers order their results differently —
//  MAL-recommendation order with self dropped, versus the pool's own ranking — so this
//  returns an unordered `[malId: Manga]` map and each caller arranges it. Folding the
//  orderings in would mean a flag parameter (ADR-0011).
//
//  ADR-0020 widened what gets *searched*: up to three spellings per target instead of
//  one, but only on rows the first spelling missed, and the extra spellings feed the
//  exact-`malId` arm only. See `searchWidening` for why that asymmetry is the decision.
//
//  Network reaches this type through three injected closures rather than direct
//  `MangaDexAPI` statics — the `MetadataUpgradeQueue.Sleep` / `AniListCandidateProvider
//  .Resolve` pattern. The defaults are the real endpoints, so no call site changes; the
//  point is that the cache-write discipline above is finally testable without a network.
//

import Foundation

@MainActor
final class MALReverseResolver {
    /// MangaDex title search — the fan-out. One call per target, plus up to
    /// `searchLimit - 1` more for a target whose first spelling missed (ADR-0020).
    typealias Search = @Sendable (String) async throws -> [Manga]
    /// Batch id fetch, covers included — one call for every cache hit combined.
    typealias FetchByIds = @Sendable ([String]) async throws -> [Manga]
    /// Every spelling MAL knows a title by. Called **only** for a target that missed on
    /// its baseline search and arrived carrying nothing to widen with (ADR-0020).
    typealias FetchTitles = @Sendable (Int) async throws -> [String]

    /// What reverse resolution actually needs: a MAL id to confirm against, and the
    /// spellings to search MangaDex with. Not `MyAnimeListManga` — the AniList pool's
    /// candidates arrive from AniList and only ever carried an `idMal`.
    ///
    /// **`titles` is ordered and the head is privileged** (ADR-0020): `titles[0]` is the
    /// baseline query *and* the only left-hand side the fuzzy matcher ever sees. The rest
    /// are reach, and reach only.
    struct ReverseTarget: Sendable, Equatable {
        let malId: Int
        let titles: [String]

        /// The primary spelling. Non-optional because a target with no title cannot be
        /// searched at all, and both construction sites drop such rows before they get here.
        var title: String { titles.first ?? "" }

        init(malId: Int, titles: [String]) {
            self.malId = malId
            self.titles = titles
        }

        init(malId: Int, title: String) {
            self.init(malId: malId, titles: [title])
        }
    }

    /// How many spellings one target may spend on MangaDex searches, **including** the
    /// baseline (ADR-0020 Decision 1). Measured, not inherited: query 2 recovers 86% of
    /// everything available and query 3 takes it to 94%, while queries 4 and 5 together
    /// buy 5 cards out of 84. Matches `MALEntityResolver.titleSearchLimit`, so the app
    /// has one fan-out number rather than two.
    static let searchLimit = 3

    private let store: EntityResolutionStore
    private let matcher: MALTitleMatcher
    private let search: Search
    private let fetchByIds: FetchByIds
    private let fetchTitles: FetchTitles

    init(store: EntityResolutionStore = .shared,
         matcher: MALTitleMatcher = .init(),
         search: Search? = nil,
         fetchByIds: FetchByIds? = nil,
         fetchTitles: @escaping FetchTitles = {
             try await MyAnimeListAPI.alternativeTitles(id: $0)
         },
         source: @escaping () -> MangaSource? = { nil }) {
        self.store = store
        self.matcher = matcher
        self.search = search ?? { title in
            guard let source = source() else { return [] }
            return try await source.search(title: title, limit: 10, offset: 0)
        }
        self.fetchByIds = fetchByIds ?? { ids in
            guard let source = source() else { return [] }
            return await Self.fetch(ids: ids, from: source)
        }
        self.fetchTitles = fetchTitles
    }

    private static func fetch(ids: [String], from source: MangaSource) async -> [Manga] {
        await withTaskGroup(of: Manga?.self, returning: [Manga].self) { group in
            var iterator = ids.makeIterator()
            var output: [Manga] = []
            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask { try? await source.manga(id: id) }
            }
            for _ in 0..<min(4, ids.count) { addNext() }
            while let manga = await group.next() {
                if let manga { output.append(manga) }
                addNext()
            }
            return output
        }
    }

    /// Reverse-resolve `targets` to openable MangaDex titles, keyed by `malId`. Never
    /// throws — a failure degrades to fewer entries, never to an error the caller has to
    /// surface. Absent keys mean "not resolved", which is the *normal* case: AniList's and
    /// MAL's catalogues are both wider than MangaDex's.
    func resolve(_ targets: [ReverseTarget]) async -> [Int: Manga] {
        // Partition: fresh cache hits (one batch fetch later) versus misses (live search).
        var resolvedIds: [Int: String] = [:]     // malId -> MangaDex id, from fresh hits
        var toSearch: [ReverseTarget] = []
        for target in targets {
            if let cached = store.reverseResolution(malId: target.malId), cached.isFresh() {
                if case .resolved(let mdId) = cached { resolvedIds[target.malId] = mdId }
                // A fresh .unresolved miss: skip entirely (don't re-search yet).
            } else {
                toSearch.append(target)
            }
        }

        var out = await searchAndRecord(toSearch)

        // Batch-fetch the ids we know but hold no full `Manga` for — the cache hits, plus
        // nothing else, since a live search already returned full values.
        let searchedIds = Set(out.values.map(\.id))
        let idsNeedingFetch = Array(Set(resolvedIds.values.filter { !searchedIds.contains($0) }))
        if !idsNeedingFetch.isEmpty, let fetched = try? await fetchByIds(idsNeedingFetch) {
            let byId = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (malId, mdId) in resolvedIds where out[malId] == nil {
                if let manga = byId[mdId] { out[malId] = manga }
            }
        }
        return out
    }

    /// The AniList pool's shape (ADR-0011): take the head `limit` Works that carry both a
    /// MAL id and a title, and resolve those. Works missing either are dropped here rather
    /// than at the call site, so "which titles get searched" stays one decision in one
    /// place.
    ///
    /// **`knownTitles` is passed whole (ADR-0020).** It carries romaji/english/native/
    /// synonyms, already in hand from a request already made, and this method used to
    /// discard all but the first — so the AniList arm gets its widened search for **zero**
    /// extra requests. The MAL arm is not so lucky; see `titlesForSearch`.
    ///
    /// The ADR-0011 residual this replaces was about *matcher* width, which stays parked:
    /// the extra spellings are search input only, and the fuzzy matcher still sees just
    /// `titles[0]`.
    func resolve(works: [AniListWork], limit: Int) async -> [Int: Manga] {
        await resolve(works.prefix(limit).compactMap { work in
            guard let malId = work.malId, !work.knownTitles.isEmpty else { return nil }
            return ReverseTarget(malId: malId, titles: work.knownTitles)
        })
    }

    /// Search MangaDex for each target's title, pick a confident match, and record the
    /// outcome (bounded concurrency, cap 4 — the pattern established for
    /// `LibraryStore.refresh`). See the cache-write discipline in the file header.
    private func searchAndRecord(_ targets: [ReverseTarget]) async -> [Int: Manga] {
        guard !targets.isEmpty else { return [:] }
        let matcher = self.matcher
        let search = self.search
        let fetchTitles = self.fetchTitles
        let maxConcurrent = 4

        // (malId, resolved Manga?, didSearch) — didSearch == false means the search threw.
        let results: [(Int, Manga?, Bool)] = await withTaskGroup(
            of: (Int, Manga?, Bool).self
        ) { group in
            var iterator = targets.makeIterator()

            func addNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    do {
                        return (target.malId,
                                try await Self.searchWidening(target,
                                                              search: search,
                                                              fetchTitles: fetchTitles,
                                                              matcher: matcher),
                                true)
                    } catch {
                        return (target.malId, nil, false)   // transient — cache nothing
                    }
                }
            }

            for _ in 0..<maxConcurrent { addNext() }

            var out: [(Int, Manga?, Bool)] = []
            while let result = await group.next() {
                out.append(result)
                addNext()
            }
            return out
        }

        var resolved: [Int: Manga] = [:]
        for (malId, manga, didSearch) in results {
            if let manga {
                store.recordReverse(malId: malId, .resolved(mangaDexId: manga.id))
                resolved[malId] = manga
            } else if didSearch {
                store.recordReverse(malId: malId, .unresolved(checkedAt: Date()))
            }   // !didSearch → record nothing
        }
        return resolved
    }

    /// One target's search, widened per ADR-0020.
    ///
    /// The baseline query runs both of `pickMatch`'s arms, exactly as it always has. The
    /// **widened queries feed the strong arm only** — a candidate they surface can resolve
    /// the row only by publishing the target `malId` (Decision 4).
    ///
    /// That asymmetry is the whole decision, so it is worth saying why in the one place a
    /// reader will change it: 83 of the 84 recoveries measured came through the strong arm,
    /// and the single fuzzy recovery on a widened pool was **wrong** — it matched an entry
    /// whose `links.mal` named a different series, which ADR-0018 treats as authoritative
    /// contradiction. Widening the fuzzy arm is not refuted, it is simply unevidenced; this
    /// ships the half that was measured. A false link is worse than a refusal (ADR-0019).
    ///
    /// A throw on the baseline query propagates — the caller records nothing, because a
    /// dropped connection says nothing about the title. A throw on a *widened* query is
    /// swallowed: the baseline already completed, so the row genuinely was searched and a
    /// miss is real information. Recording nothing there would forfeit a cache write the
    /// app had already paid for.
    private static func searchWidening(_ target: ReverseTarget,
                                       search: Search,
                                       fetchTitles: FetchTitles,
                                       matcher: MALTitleMatcher) async throws -> Manga? {
        guard let primary = target.titles.first else { return nil }
        let baseline = try await search(primary)
        if let match = MoreLikeThis.pickMatch(targetMalId: target.malId,
                                              malTitle: target.title,
                                              candidates: baseline,
                                              matcher: matcher) {
            return match
        }

        // Missed. Only now is it worth discovering spellings we do not already hold — and
        // only a target that holds none, which in practice means the MAL arm.
        var spellings = target.titles
        if spellings.count < 2, let fetched = try? await fetchTitles(target.malId) {
            var seenTitle = Set(spellings)
            spellings += fetched.filter { seenTitle.insert($0).inserted }
        }

        var seen = Set(baseline.map(\.id))
        for spelling in spellings.prefix(searchLimit).dropFirst() {
            guard let more = try? await search(spelling) else { continue }
            let added = more.filter { seen.insert($0.id).inserted }
            if let exact = added.first(where: { $0.malId == target.malId }) {
                return exact
            }
        }
        return nil
    }

}
