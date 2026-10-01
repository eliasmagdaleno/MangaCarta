//
//  AniListCandidateProvider.swift
//  MangaCarta
//
//  Slice 3 of ADR-0011: the third pool, generated on AniList's ranked axis.
//
//  The I/O shell around `AniListPool.swift`'s pure core. Everything here is either a
//  network hop or a policy about when not to make one; every scoring decision lives in the
//  core, where it is testable without a transport.
//
//  This provider takes an injected `Resolve` closure so its policies are testable without
//  live network — the `MetadataUpgradeQueue.Sleep` pattern,
//  this codebase's answer to a dependency worth faking without a protocol. A `Resolve`
//  returning short exercises the no-floor rule, one returning nothing exercises the
//  24-hour empty TTL, and a transport throwing on query 3 exercises the abort.
//
//  **This lands unreferenced.** `RecommendationEngine` still builds the composite with
//  `tag:` and `mal:` only. The moment the provider is reachable the AniList pool
//  contributes to `foryou-ranking.txt`, and slice 4's golden diff can no longer answer the
//  one question it exists for.
//

import Foundation

struct AniListCandidateProvider: CandidateProvider {
    /// AniList ids are useless to MangaDex; `idMal` is the bridge, exactly as
    /// `MoreLikeThisProvider` already reverse-resolves. Returns only what it resolved,
    /// keyed by `malId` — a short return is the normal case, not an error.
    ///
    /// Takes whole `AniListWork`s, **not bare `malId`s**. Reverse-resolution is title
    /// matching: `MoreLikeThis.pickMatch` needs a title to search a Source with, and its
    /// `search(title:)` is the only way to get candidates at all. Passing
    /// ids alone would mean re-fetching titles we held one line earlier — one
    /// `MyAnimeListAPI.mangaDetail` per unresolved id, up to `resolveLimit` per refresh,
    /// against a budget this ADR never costed. `knownTitles` is also a *better* left-hand
    /// side than MAL's single title (`AniListAPI.swift:77-80`).
    typealias Resolve = @Sendable ([AniListWork]) async -> [Int: Manga]

    /// One pair's query, and how many results to ask for. Injected at this level rather
    /// than as an `AniListAPI` so tests can throw on a chosen call without a transport
    /// double.
    ///
    /// The limit is a **parameter, not something the closure decides**: it is the per-pair
    /// half of ADR-0011's fan-out budget, and a closure that chose its own would put that
    /// budget outside the type that documents it.
    typealias Query = @Sendable (TagPair, Int) async throws -> [AniListWork]

    /// The Works to seed from. A closure because `WorkStore` is `@MainActor` and this
    /// provider deliberately is not — the same one-way shape as
    /// `RecommendationEngine.PriorityPush`.
    typealias LoadWorks = @Sendable () async -> [Work]

    let loadWorks: LoadWorks
    let vocabularyStore: TagVocabularyStore
    let poolStore: AniListPoolStore
    let query: Query
    let resolve: Resolve

    /// Reused from `RecommendationEngine.minTaggedManga` rather than introducing a second
    /// number. See `gateIsOpen` for what it counts.
    var minimumContributingWorks: Int = 3
    var perPairLimit: Int = poolPerPairLimit
    var resolveLimit: Int = poolResolveLimit
    var excludeAdultTags: Bool = true

    func candidates(for profile: TasteProfile,
                    excluding: Set<String>,
                    limit: Int) async throws -> [ScoredManga] {

        // Absence, not staleness, is what disqualifies the vocabulary. A 40-day-old copy is
        // a non-event — categories move on the order of years and an unknown tag stays
        // seedable by the deny-list rule — but seeding with categories *unknown* is
        // specifically the "recommend me webtoons and Male Protagonist" failure, so a
        // missing one skips generation entirely (ADR-0011's skip-rather-than-degrade).
        guard let vocabulary = await vocabularyStore.cachedVocabulary() else {
            await vocabularyStore.refreshIfNeeded()
            return []
        }
        await vocabularyStore.refreshIfNeeded()

        let works = await loadWorks()
        let seeded = seedPairs(works: works,
                               weights: profile.workWeights,
                               vocabulary: vocabulary,
                               excludeAdultTags: excludeAdultTags)
        guard gateIsOpen(seeded) else { return [] }

        let pairs = seeded.map(\.pair)
        let weights = Dictionary(seeded.map { ($0.pair, $0.weight) },
                                 uniquingKeysWith: { first, _ in first })

        // Read first, then kick. The refresh is a no-op when what we hold is fresh, and
        // returning before it completes is the entire point.
        let record = await poolStore.pool(seeds: pairs)
        await poolStore.refreshIfNeeded(seeds: pairs) { seeds in
            await Self.buildRecord(seeds: seeded.filter { seeds.contains($0.pair) },
                                   query: query,
                                   resolve: resolve,
                                   perPairLimit: perPairLimit,
                                   resolveLimit: resolveLimit)
        }
        guard let record else { return [] }

        // Exclusions are applied *here*, never baked into the cache: `read ∪ saved ∪
        // notInterested` changes every time a chapter is opened, the pool changes every
        // two weeks, and baking them in would resurrect titles the user just read.
        return record.candidates
            .filter { !excluding.contains($0.manga.id) }
            .map { candidate in
                ScoredManga(manga: candidate.manga,
                            score: withinPoolScore(candidate.contributions, weights: weights),
                            reason: poolReason(for: candidate.contributions,
                                               weights: weights,
                                               vocabulary: vocabulary))
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.manga.id < $1.manga.id }
            .prefix(limit)
            .map { $0 }
    }

    /// The pool runs only above 3 AniList-resolved Works, counted on the Works that
    /// **contributed** to a seed pair.
    ///
    /// Counting Works with a non-empty ranked axis is the obvious reading and is subtly
    /// wrong: a Work can carry ranked tags where none clears `minimumSeedTagRank`, or where
    /// every one that does sits in an excluded category. Those contribute nothing, so
    /// counting them opens the gate on a store that then produces zero pairs — an empty
    /// pool, cached for 24 hours. The gate would be doing the opposite of its job.
    ///
    /// It lives here rather than in `RecommendationEngine` because putting it there would
    /// make the engine know what a ranked axis is and how to count one, to serve one of its
    /// three pools — the knowledge accumulation ADR-0010's one-way closure exists to
    /// prevent. A provider returning `[]` is already fully supported.
    private func gateIsOpen(_ seeded: [SeededTagPair]) -> Bool {
        Set(seeded.flatMap(\.contributingWorks)).count >= minimumContributingWorks
    }

    /// Five queries, the pure core, then a resolution budget spent on the head.
    ///
    /// Returns `nil` — write nothing — if **any** pair query throws. The record's identity
    /// *is* the seed-pair set, so an entry keyed on five pairs but built from three is
    /// lying about its own key, and slice 4's golden would show a thin pool with no way to
    /// attribute it. Aborting is nearly free: the previous entry stands and the next Home
    /// appearance retries seconds later.
    ///
    /// **A query returning zero results is not a failure.** Under AND semantics that is a
    /// normal outcome, and treating it as an error would abort refreshes for precisely the
    /// sparse-taste reader — and prevent the 24-hour empty record from ever being written.
    static func buildRecord(seeds: [SeededTagPair],
                            query: @escaping Query,
                            resolve: @escaping Resolve,
                            perPairLimit: Int = poolPerPairLimit,
                            resolveLimit: Int,
                            now: Date = Date()) async -> AniListPoolRecord? {

        var results: [(pair: SeededTagPair, works: [AniListWork])] = []
        for seeded in seeds {
            // Sequential: these already queue behind `AniListRateLimiter`'s 2s spacing, so
            // concurrency would buy nothing but a harder abort to reason about.
            guard let works = try? await query(seeded.pair, perPairLimit) else { return nil }
            results.append((seeded, works))
        }

        let ranked = rankPoolCandidates(results: results)

        // Score first, resolve second. `withinPool` is computable from the AniList response
        // alone, so the whole pool is ranked for free and the real fan-out — one live
        // MangaDex title search per `idMal` without a fresh cache hit — is spent only on
        // the head.
        let head = Array(ranked.prefix(resolveLimit))
        // Only works carrying a `malId` are resolvable at all — the bridge is `idMal`, so
        // one without it cannot be searched for by any route and must not consume a slot
        // in the resolve batch.
        let resolved = await resolve(head.map(\.work).filter { $0.malId != nil })

        // No floor and no backfill. A title failing to resolve is the *normal* case —
        // AniList's catalogue and MangaDex's are different sets — and topping the head back
        // up to 12 would turn a bounded fan-out into a loop whose length depends on network
        // luck, spending the most budget exactly when MangaDex is least healthy.
        let candidates: [PooledCandidate] = head.compactMap { candidate in
            guard let malId = candidate.work.malId, let manga = resolved[malId] else { return nil }
            return PooledCandidate(manga: manga, contributions: candidate.contributions)
        }

        return AniListPoolRecord(seeds: seeds.map(\.pair),
                                 fetchedAt: now,
                                 candidates: candidates)
    }
}
