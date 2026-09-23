//
//  MoreLikeThisProvider.swift
//  MangaCarta
//
//  Turns a Manga into a list of openable MangaDex "More Like This" titles, sourced from
//  MyAnimeList's per-title recommendations. Orchestration only: forward-resolve → MAL
//  detail → top-N recommendations → reverse-resolve each back to a MangaDex Manga, in
//  recommendation-weight order. The decision logic lives in pure helpers (MoreLikeThis,
//  MALTitleMatcher) and the reverse resolution in MALReverseResolver; what is left here
//  is the MAL-specific part — which recommendations to take, and what order to return
//  them in. Non-throwing: any failure degrades to fewer/zero cards.
//

import Foundation

@MainActor
final class MoreLikeThisProvider {
    private let resolver: MALEntityResolver
    private let reverse: MALReverseResolver

    init(store: EntityResolutionStore = .shared,
         resolver: MALEntityResolver? = nil,
         reverse: MALReverseResolver? = nil,
         source: @escaping () -> MangaSource? = { nil }) {
        self.resolver = resolver ?? MALEntityResolver(store: store, source: source)
        self.reverse = reverse ?? MALReverseResolver(store: store, source: source)
    }

    /// The top `limit` recommendations by weight (descending). Pure — no network. Marked
    /// `nonisolated` so it's callable synchronously without hopping to the main actor
    /// (it touches no actor-isolated state); tests call it directly.
    nonisolated static func topRecommendations(_ recs: [MyAnimeListMangaDetail.Recommendation],
                                               limit: Int) -> [MyAnimeListMangaDetail.Recommendation] {
        Array(recs.sorted { $0.numRecommendations > $1.numRecommendations }.prefix(limit))
    }

    /// Up to `limit` openable MangaDex titles similar to `manga`, in MAL-recommendation
    /// order. Empty when `manga` has no MAL match, MAL returns no recommendations, or none
    /// reverse-resolve. Never throws — network failures degrade to fewer/zero cards.
    func recommendations(for manga: Manga, limit: Int = 8) async -> [Manga] {
        guard let malId = await resolver.malId(for: manga) else { return [] }
        guard let detail = try? await MyAnimeListAPI.mangaDetail(id: malId) else { return [] }
        let recs = Self.topRecommendations(detail.recommendations ?? [], limit: limit)
        guard !recs.isEmpty else { return [] }

        let resolved = await reverse.resolve(
            recs.map { .init(malId: $0.node.id, title: $0.node.title) })

        // Reassemble in recommendation (weight) order; drop self; de-dupe by id. This is
        // the part that stayed here: the resolver returns an unordered map because the
        // AniList pool carries its own ranking, so the MAL ordering belongs to this caller.
        var out: [Manga] = []
        var seen = Set<String>()
        for rec in recs {
            guard let match = resolved[rec.node.id],
                  match.id != manga.id,
                  seen.insert(match.id).inserted else { continue }
            out.append(match)
        }
        return out
    }
}

/// The one capability MALCandidateProvider needs — injectable so tests can stub it.
@MainActor
protocol SimilarTitlesProviding {
    func recommendations(for manga: Manga, limit: Int) async -> [Manga]
}

extension MoreLikeThisProvider: SimilarTitlesProviding {}
