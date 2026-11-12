//
//  CandidateProvider.swift
//  MangaCarta
//
//  Turns a TasteProfile into ranked recommendation candidates. The seam a future
//  MyAnimeList/Jikan provider slips behind. v1 scores by *query provenance*: a title
//  surfaced by several of the user's top-tag feeds sums several contributions, so
//  multi-tag overlap falls out without ever fetching a candidate's detail.
//

import Foundation

/// A ranked recommendation: the manga, its score, and a human reason ("More Action").
struct ScoredManga: Identifiable {
    let manga: Manga
    let score: Double
    let reason: String
    var reasonKind: ForYouReasonKind = .other
    var id: String { manga.id }
}

protocol CandidateProvider {
    /// Ranked candidates for a profile, already excluding `excluding`, capped at `limit`.
    func candidates(for profile: TasteProfile,
                    excluding: Set<String>,
                    limit: Int) async throws -> [ScoredManga]
}

/// v1 provider: fetch the top-K tag feeds and score by provenance.
struct TagCandidateProvider: CandidateProvider {
    let source: MangaSource
    var topK: Int = 6
    var perTagLimit: Int = 20

    func candidates(for profile: TasteProfile,
                    excluding: Set<String>,
                    limit: Int) async throws -> [ScoredManga] {
        let tagIds = Array(profile.orderedTagKeys.prefix(topK))
        guard !tagIds.isEmpty else { return [] }

        // Fetch each tag feed concurrently; a failing feed is skipped, not fatal.
        let lists: [(tagId: String, manga: [Manga])] =
            await withTaskGroup(of: (String, [Manga]).self) { group in
                for tid in tagIds {
                    let name = profile.tagName[tid] ?? ""
                    let src = source
                    let per = perTagLimit
                    group.addTask {
                        guard !name.isEmpty else { return (tid, []) }
                        let res = try? await src.mangaByTag(tag: name, limit: per, offset: 0)
                        return (tid, res ?? [])
                    }
                }
                var out: [(String, [Manga])] = []
                for await r in group { out.append(r) }
                return out
            }

        var scores: [String: Double] = [:]
        var mangaById: [String: Manga] = [:]
        var bestTag: [String: (weight: Double, name: String)] = [:]

        for (tid, list) in lists {
            let w = profile.weights[tid] ?? 0
            let name = profile.tagName[tid] ?? ""
            for (i, m) in list.enumerated() where !excluding.contains(m.id) {
                scores[m.id, default: 0] += w * (1.0 / Double(1 + i))   // rating-desc: earlier = better
                if mangaById[m.id] == nil { mangaById[m.id] = m }
                // Highest-weighted tag wins the reason string; equal weights break on name so
                // the reason doesn't depend on which task group task happened to finish first.
                if let best = bestTag[m.id] {
                    if w > best.weight || (w == best.weight && name < best.name) {
                        bestTag[m.id] = (w, name)
                    }
                } else {
                    bestTag[m.id] = (w, name)
                }
            }
        }

        // Secondary sort on id, matching CompositeCandidateProvider: Swift's sort is not stable,
        // so without this two exactly-tied candidates can swap between runs — and a tie
        // straddling `limit` can change which titles are in the pool at all.
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { id, score in
                guard let m = mangaById[id] else { return nil }
                let reason = bestTag[id].map { "More \($0.name)" } ?? "Recommended"
                return ScoredManga(manga: m, score: score, reason: reason, reasonKind: .tag)
            }
    }
}

/// Collaborative candidates: for each of the profile's seeds, fetch MAL "more like this"
/// (already reverse-resolved to openable MangaDex titles) and score each result by
/// position × the seed's engagement weight, summed across seeds. Network-tolerant — an
/// empty seed result just contributes nothing.
struct MALCandidateProvider: CandidateProvider {
    let similar: SimilarTitlesProviding
    var perSeedLimit: Int = 8

    func candidates(for profile: TasteProfile,
                    excluding: Set<String>,
                    limit: Int) async throws -> [ScoredManga] {
        let seeds = profile.seeds
        guard !seeds.isEmpty else { return [] }

        // Per-seed recommendation lists, concurrently (bounded by seed count, ≤5).
        let lists: [(seed: SeedManga, recs: [Manga])] =
            await withTaskGroup(of: (SeedManga, [Manga]).self) { group in
                for seed in seeds {
                    let provider = similar
                    let per = perSeedLimit
                    group.addTask {
                        let recs = await provider.recommendations(for: seed.manga, limit: per)
                        return (seed, recs)
                    }
                }
                var out: [(SeedManga, [Manga])] = []
                for await r in group { out.append(r) }
                return out
            }

        var scores: [String: Double] = [:]
        var mangaById: [String: Manga] = [:]
        var bestSeed: [String: (weight: Double, title: String)] = [:]

        for (seed, recs) in lists {
            for (i, m) in recs.enumerated() where !excluding.contains(m.id) {
                scores[m.id, default: 0] += seed.weight * (1.0 / Double(1 + i))
                if mangaById[m.id] == nil { mangaById[m.id] = m }
                // Same determinism fix as bestTag: equal seed weights break on title.
                let title = seed.manga.title
                if let best = bestSeed[m.id] {
                    if seed.weight > best.weight || (seed.weight == best.weight && title < best.title) {
                        bestSeed[m.id] = (seed.weight, title)
                    }
                } else {
                    bestSeed[m.id] = (seed.weight, title)
                }
            }
        }

        // Secondary sort on id, matching CompositeCandidateProvider: Swift's sort is not stable,
        // so without this two exactly-tied candidates can swap between runs — and a tie
        // straddling `limit` can change which titles are in the pool at all.
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { id, score in
                guard let m = mangaById[id] else { return nil }
                let reason = bestSeed[id].map { "Because you read \($0.title)" } ?? "Recommended"
                return ScoredManga(manga: m, score: score, reason: reason, reasonKind: .mal)
            }
    }
}

/// A candidate provider that returns nothing. The honest default for the `ani` slot on
/// paths that must not touch the network — previews, and tests about the blend rather than
/// the pool. Distinct from a failing provider: this degrades to a two-pool rail by design,
/// which `CompositeCandidateProvider` already handles as its graceful-degradation case.
struct EmptyCandidateProvider: CandidateProvider {
    func candidates(for profile: TasteProfile,
                    excluding: Set<String>, limit: Int) async throws -> [ScoredManga] { [] }
}

/// Blends three candidate pools (tag + AniList + MAL). Each pool is normalized to [0, 1]
/// (÷ its own max) so the signals are comparable, then combined
/// `W_TAG·tag + W_ANILIST·ani + W_MAL·mal` plus an agreement bonus of
/// `AGREEMENT_BONUS · (∏ contributing normalized scores)^(1/n)`. Any pool empty or failing
/// ⇒ the ranking the remaining pools produce (graceful degradation).
///
/// The agreement term is the geometric mean over the pools that scored the title, which
/// tracks the **weakest** contributing signal: pools agreeing at the top of each earn close
/// to the full bonus, while incidental co-occurrence deep in each earns almost nothing. A
/// pool omitting the title simply does not enter the product, so non-overlap needs no
/// special case.
///
/// This replaced a flat `+0.25` for any overlap at all. Under the flat bonus a title ranked
/// ~40% of top strength in *both* pools outranked the single best recommendation either
/// signal had, because 0.25 is large against scores that live in [0, 1]. The two rules are
/// both defensible — "agreement wins" vs "strength wins, agreement breaks ties" — but they
/// are different products, and the second is the one chosen. See
/// MangaCartaTests/__Goldens__/foryou-ranking.txt for the effect on a worked example.
struct CompositeCandidateProvider: CandidateProvider {
    let tag: CandidateProvider
    let mal: CandidateProvider
    /// The AniList pool (ADR-0011). Defaulted to an empty provider — **not** as a
    /// convenience, but because the paths that take the default genuinely should not do
    /// AniList network: SwiftUI previews and every test that is about the blend rather than
    /// the pool. The app's composition root passes the real one explicitly.
    /// `var`, not `let`: a `let` carrying a default value is excluded from the memberwise
    /// initializer entirely, which would make it unsettable.
    var ani: CandidateProvider = EmptyCandidateProvider()

    // Tuning constants. Non-private and injectable (the memberwise init defaults them, so
    // `CompositeCandidateProvider(tag:mal:)` still reads the same) for two reasons: the golden
    // harness in RecommendationGoldenTests reads them so its per-column breakdown stays correct
    // when they change, and an alternative weighting can be compared in a test without editing
    // this file. Defaults are the shipping values.
    var wTag = 1.0
    var wMal = 0.85
    /// Below `wMal` — not because the ranked axis is the weaker signal (ADR-0011 argues it
    /// is the best-evidenced of the three) but because it is the only one that has never
    /// faced a real device. The golden file is the instrument for raising it.
    var wAniList = 0.6
    /// Scales the geometric-mean agreement term. Deliberately left at the flat bonus's old
    /// value so the formula change could be evaluated on its own — note the geometric bonus is
    /// always ≤ the flat one it replaced, reaching 0.25 only when a title tops both pools, so
    /// this constant is a candidate for retuning *after* the shape change has been judged.
    var agreementBonus = 0.25

    func candidates(for profile: TasteProfile,
                    excluding: Set<String>,
                    limit: Int) async throws -> [ScoredManga] {
        async let tagPool = tag.candidates(for: profile, excluding: excluding, limit: limit)
        async let malPool = mal.candidates(for: profile, excluding: excluding, limit: limit)
        async let aniPool = ani.candidates(for: profile, excluding: excluding, limit: limit)
        // Any pool failing degrades to empty (MAL failing ⇒ tag-only rail).
        let tags = (try? await tagPool) ?? []
        let mals = (try? await malPool) ?? []
        let anis = (try? await aniPool) ?? []

        let tagNorm = Self.normalized(tags)
        let malNorm = Self.normalized(mals)
        let aniNorm = Self.normalized(anis)

        var score: [String: Double] = [:]
        var manga: [String: Manga] = [:]
        var reason: [String: String] = [:]
        var reasonKind: [String: ForYouReasonKind] = [:]

        // Reason precedence is tag < AniList < MAL, applied by assignment order (ADR-0011).
        // "Because you read Solo Leveling" names a book the user chose and beats any tag
        // phrasing; a two-tag conjunction is strictly more informative than the single broad
        // tag that surfaced the same title, so it overrides "More Action".
        for c in tags {
            manga[c.manga.id] = c.manga
            reason[c.manga.id] = c.reason
            reasonKind[c.manga.id] = c.reasonKind
            score[c.manga.id, default: 0] += wTag * (tagNorm[c.manga.id] ?? 0)
        }
        for c in anis {
            if manga[c.manga.id] == nil { manga[c.manga.id] = c.manga }
            reason[c.manga.id] = c.reason
            reasonKind[c.manga.id] = c.reasonKind
            score[c.manga.id, default: 0] += wAniList * (aniNorm[c.manga.id] ?? 0)
        }
        for c in mals {
            if manga[c.manga.id] == nil { manga[c.manga.id] = c.manga }
            reason[c.manga.id] = c.reason      // MAL reason preferred when MAL contributed
            reasonKind[c.manga.id] = c.reasonKind
            score[c.manga.id, default: 0] += wMal * (malNorm[c.manga.id] ?? 0)
        }

        // Agreement: the geometric mean over the pools that actually scored the title.
        //
        // Generalized from the two-pool `√(tag·mal)` when the AniList pool landed, and it
        // reduces to that expression exactly when only two pools contribute — so the change
        // is one the golden file can adjudicate as a diff. Three *pairwise* terms were
        // rejected: a title in all three would collect up to 3 × agreementBonus, which is
        // precisely the "agreement outranks strength" failure the geometric mean was adopted
        // to fix, and holding the balance would mean cutting agreementBonus to ~0.08 —
        // quietly weakening two-pool agreement as a side effect of adding a third pool.
        for id in manga.keys {
            let contributing = [tagNorm[id], aniNorm[id], malNorm[id]].compactMap { $0 }
                .filter { $0 > 0 }
            guard contributing.count >= 2 else { continue }
            let product = contributing.reduce(1.0, *)
            score[id, default: 0] += agreementBonus * pow(product, 1.0 / Double(contributing.count))
        }

        // Secondary sort on id keeps the order stable for exactly-tied scores, so the
        // "See all" grid (which uses the straight ranking) doesn't reshuffle between opens.
        return score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { id, value in
                guard let m = manga[id] else { return nil }
                return ScoredManga(manga: m, score: value, reason: reason[id] ?? "Recommended",
                                   reasonKind: reasonKind[id] ?? .other)
            }
    }

    /// id → score ÷ pool max, in [0, 1]. Empty/all-zero pool → empty map.
    private static func normalized(_ pool: [ScoredManga]) -> [String: Double] {
        guard let max = pool.map(\.score).max(), max > 0 else { return [:] }
        return Dictionary(pool.map { ($0.manga.id, $0.score / max) },
                          uniquingKeysWith: { first, _ in first })
    }
}
