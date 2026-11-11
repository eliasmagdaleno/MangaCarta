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
    private let detailStore: MALDetailStore
    private let fetchDetail: @Sendable (Int) async throws -> MyAnimeListMangaDetail

    init(store: EntityResolutionStore = .shared,
         resolver: MALEntityResolver? = nil,
         reverse: MALReverseResolver? = nil,
         detailStore: MALDetailStore,
         fetchDetail: @escaping @Sendable (Int) async throws -> MyAnimeListMangaDetail = {
             try await MyAnimeListAPI.mangaDetail(id: $0)
         },
         source: @escaping () -> MangaSource?) {
        self.resolver = resolver ?? MALEntityResolver(store: store, source: source)
        self.reverse = reverse ?? MALReverseResolver(store: store, source: source)
        self.detailStore = detailStore
        self.fetchDetail = fetchDetail
    }

    /// The top `limit` recommendations by weight (descending). Pure — no network. Marked
    /// `nonisolated` so it's callable synchronously without hopping to the main actor
    /// (it touches no actor-isolated state); tests call it directly.
    nonisolated static func topRecommendations(_ recs: [MyAnimeListMangaDetail.Recommendation],
                                               limit: Int) -> [MyAnimeListMangaDetail.Recommendation] {
        Array(recs.enumerated().sorted { lhs, rhs in
            lhs.element.numRecommendations != rhs.element.numRecommendations
                ? lhs.element.numRecommendations > rhs.element.numRecommendations
                : lhs.offset < rhs.offset
        }.map(\.element).prefix(limit))
    }

    /// How many recommendations the detail page's More Like This rail draws from.
    static let detailRecommendationLimit = 8

    /// Both detail-page MAL-native rails from ONE cached MAL detail and ONE reverse-resolution pass
    /// over their union. A separate API from `recommendations(for:limit:)`, which the home rail
    /// consumes and which keeps returning resolved Listings only. Nil when there is no MAL identity
    /// or no detail — the caller hides both rails.
    func detailDiscovery(for manga: Manga, showAdultContent: Bool,
                         admits: (Manga) -> Bool) async -> MALDetailDiscovery? {
        guard let malId = await resolver.malId(for: manga) else { return nil }
        guard let detail = await detailStore.detail(for: malId, fetch: fetchDetail) else { return nil }
        var targets: [MALReverseResolver.ReverseTarget] = []
        var seen = Set<Int>()
        for relation in detail.relatedManga ?? [] where seen.insert(relation.node.id).inserted {
            targets.append(.init(malId: relation.node.id, title: relation.node.title))
        }
        let recommendations = Self.topRecommendations(detail.recommendations ?? [],
                                                      limit: Self.detailRecommendationLimit)
        for recommendation in recommendations where seen.insert(recommendation.node.id).inserted {
            targets.append(.init(malId: recommendation.node.id, title: recommendation.node.title))
        }
        let resolved = await reverse.resolve(targets)
        return MALDiscoveryProjection.project(detail: detail, parentMALID: malId, parentListingID: manga.id,
                                              resolutions: resolved, showAdultContent: showAdultContent,
                                              admits: admits,
                                              recommendationLimit: Self.detailRecommendationLimit)
    }

    /// Up to `limit` openable MangaDex titles similar to `manga`, in MAL-recommendation
    /// order. Empty when `manga` has no MAL match, MAL returns no recommendations, or none
    /// reverse-resolve. Never throws — network failures degrade to fewer/zero cards.
    func recommendations(for manga: Manga, limit: Int = 8) async -> [Manga] {
        guard let malId = await resolver.malId(for: manga) else { return [] }
        guard let detail = await detailStore.detail(for: malId, fetch: fetchDetail) else { return [] }
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
