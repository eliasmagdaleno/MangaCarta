//
//  MALEntityResolver.swift
//  MangaCarta
//
//  Resolves a Manga (any source) to a canonical MyAnimeList id. Fast path: a Manga that
//  already carries `malId` (MangaDex) returns it for free. Otherwise consult the cache,
//  then fall back to a title search + pure MALTitleMatcher. Precision-biased and
//  non-throwing: an ordinary no-match returns nil (the caller omits the title); a
//  transient MAL error also returns nil but is NOT cached, so an outage can't poison the
//  cache for the full miss TTL.
//

import Foundation

@MainActor
final class MALEntityResolver {
    /// The MAL search, injected. `MyAnimeListAPI` is `static` all the way down onto
    /// `URLSession.shared`, so without a seam here nothing past the cache branch is
    /// testable. `AniListAPI` solved the same problem with an injectable `Transport`;
    /// this puts the seam at the resolver instead, to keep the change local.
    typealias Search = (String) async throws -> [MALCandidate]

    /// The MangaDex **bridge** search (ADR-0016), injected for the same reason `Search` is:
    /// `MangaDexAPI` is static onto `URLSession.shared`. Returns Listings rather than a
    /// reduced candidate type because the bridge needs three things off each one — the
    /// title, the alternates, and `malId` — and a purpose-built struct would carry exactly
    /// those and nothing else.
    typealias BridgeSearch = (String) async throws -> [Manga]

    /// What resolution learned about a Work: the id, if any, and every spelling picked up
    /// on the way there.
    ///
    /// The titles come back to the caller rather than being written here because this type
    /// has no `WorkStore` — and should not: it answers a question, it does not own Works.
    /// The caller harvests them (ADR-0016 Decision 5), which is also what lets it record an
    /// `.unmatched` fingerprint against the *post*-harvest title count.
    struct WorkResolution: Equatable {
        let malId: Int?
        let harvestedTitles: [String]

        static let unresolved = WorkResolution(malId: nil, harvestedTitles: [])
    }

    private let store: EntityResolutionStore
    private let matcher: MALTitleMatcher
    private let search: Search
    private let bridgeSearch: BridgeSearch
    /// How many of a Work's known titles get their own MAL search. Bounds the fan-out
    /// for a heavily-merged Work; in practice an unresolved Work has one or two titles,
    /// so this rarely binds (ADR-0009).
    private let titleSearchLimit: Int

    static let liveSearch: Search = { title in
        try await MyAnimeListAPI.searchManga(title: title)
            .map { MALCandidate(malId: $0.id, titles: $0.allTitles) }
    }

    /// A bridge that finds nothing, for tests about the MAL round.
    ///
    /// The default above is live, matching `search`'s existing precedent so the app is
    /// correct by construction rather than by remembering to wire something. The cost of
    /// that choice lands here: a Work-level test that reaches the bridge and does not inject
    /// one hits the network. **Every resolver test that can miss on MAL should pass this**,
    /// which is also how such a test states that the MAL round is what it is about.
    static let noBridge: BridgeSearch = { _ in [] }

    init(store: EntityResolutionStore,
         matcher: MALTitleMatcher = .init(),
         titleSearchLimit: Int = 3,
         search: @escaping Search = MALEntityResolver.liveSearch,
         bridgeSearch: BridgeSearch? = nil,
         source: @escaping () -> MangaSource?) {
        self.store = store
        self.matcher = matcher
        self.titleSearchLimit = titleSearchLimit
        self.search = search
        self.bridgeSearch = bridgeSearch ?? { title in
            guard let source = source() else { throw SourceError.unavailable("external id bridge") }
            return try await source.search(title: title, limit: 10, offset: 0)
        }
    }

#if DEBUG
    /// Test-only convenience for tests that stub both catalogue searches directly.
    convenience init(store: EntityResolutionStore,
                     matcher: MALTitleMatcher = .init(),
                     titleSearchLimit: Int = 3,
                     search: @escaping Search = MALEntityResolver.liveSearch,
                     bridgeSearch: BridgeSearch? = nil) {
        self.init(store: store, matcher: matcher, titleSearchLimit: titleSearchLimit,
                  search: search, bridgeSearch: bridgeSearch, source: { nil })
    }
#endif

    /// The canonical MAL id for a **Work**, or nil if nothing matched with confidence.
    ///
    /// Unlike `malId(for manga:)` this **throws**, because its caller writes attempt
    /// memory and ADR-0008 gives the two failures different records: a real miss is
    /// `.unmatched(knownTitlesCount)`, a transient failure is recorded as nothing at all.
    /// An `Int?` cannot carry that distinction, so `nil` means "searched, nothing cleared
    /// the threshold" and a throw means "don't remember this".
    ///
    /// Nothing is written to `EntityResolutionStore`: its cache is keyed
    /// `sourceId:mangaId`, and a Work-level answer has no single Listing to key on. It is
    /// still *read* below — a hit recorded by a detail-page open is a valid answer for any
    /// Work containing that Listing, and costs no request.
    func resolve(_ work: Work) async throws -> WorkResolution {
        if let known = work.externalIds.mal { return WorkResolution(malId: known, harvestedTitles: []) }

        for key in work.listings {
            if case .resolved(let id) = store.resolution(sourceId: key.sourceId,
                                                         mangaId: key.mangaId) {
                return WorkResolution(malId: id, harvestedTitles: [])
            }
        }

        // One search per known title, unioned into ONE candidate pool. Deliberately not
        // one match per title: a maximum across independent ranked lists has no runner-up,
        // so it would route around the ambiguity guard (ADR-0008).
        var pool: [Int: MALCandidate] = [:]
        var failure: Error?
        for title in work.knownTitles.prefix(titleSearchLimit) {
            do {
                // First spelling wins; MAL returns the same title set for a given id, so
                // later duplicates carry no new matcher fuel.
                for candidate in try await search(title) where pool[candidate.malId] == nil {
                    pool[candidate.malId] = candidate
                }
            } catch {
                failure = error
            }
        }

        // Sorted by id because dictionary iteration order is randomized per process, and
        // the matcher's sort is not stable — without this, tied candidates could resolve
        // differently between launches.
        let candidates = pool.values
            .sorted { $0.malId < $1.malId }
            .map { (id: $0.malId, titles: $0.titles) }

        // Matching is free, so it uses *every* known title even though only the first few
        // were searched.
        if let matched = matcher.bestMatch(sourceTitles: work.knownTitles,
                                           candidates: candidates) {
            return WorkResolution(malId: matched, harvestedTitles: [])
        }
        // A match stands on its own — the searches that failed could only have added
        // candidates, which the ambiguity guard would treat as evidence *against*. A miss
        // computed from incomplete evidence is not trustworthy, so it is not reported as
        // one: `.unmatched` is fingerprinted on title count and would otherwise sit stale
        // for the full TTL on the strength of one network blip.
        if let failure { throw failure }

        // MAL had its chance on every spelling this Work knows. Ask MangaDex — unless this
        // Work is already MangaDex's own (ADR-0019).
        guard Self.isBridgeable(work) else { return .unresolved }
        return try await bridged(sourceTitles: work.knownTitles)
    }

    // MARK: - The MangaDex bridge (ADR-0016, scoped by ADR-0019)

    /// Whether the bridge has anything to offer this Work.
    ///
    /// **The gate is the Work, not the source.** A Work that already carries an
    /// authoritative external id never gets here — `resolve` returned it at the top
    /// (ADR-0018) — so the only thing left to exclude is the circular case: a Work whose
    /// Listing MangaDex already serves. MangaDex publishes `links.mal` on that entry for
    /// free, and its absence is an *answer*, not a gap. Searching MangaDex for a title
    /// MangaDex already handed us cannot produce a link it declined to publish; it can only
    /// spend requests and, worse, match some *other* series' entry.
    ///
    /// Phrased against the Work rather than against a registry of sources on purpose: a new
    /// source needs no registration to be bridgeable, and this composes with ADR-0018
    /// instead of duplicating what it knows.
    private static func isBridgeable(_ work: Work) -> Bool {
        !work.listings.contains { $0.sourceId == LegacySourceID.unattributed }
    }

    /// Resolves through MangaDex: search it by title, and take `links.mal` off the entry
    /// that matches. Reached only after MyAnimeList's own search has produced no confident
    /// match, so its worst case is one wasted round of requests on a Work that is refused
    /// today either way (ADR-0016 Decision 2).
    ///
    /// Returns any id found **and** every spelling learned, including in the case where a
    /// series was identified but carries no MAL link — those titles are worth keeping
    /// regardless, because `knownTitles` growing is what reopens an `.unmatched` Work.
    private func bridged(sourceTitles: [String]) async throws -> WorkResolution {
        var pool: [String: Manga] = [:]
        var failure: Error?
        for title in sourceTitles.prefix(titleSearchLimit) {
            do {
                for listing in try await bridgeSearch(title) where pool[listing.id] == nil {
                    pool[listing.id] = listing
                }
            } catch {
                failure = error
            }
        }
        guard !pool.isEmpty else {
            // Nothing to reason about. A failure here is transient and must not be
            // remembered as an answer, same rule as the MAL round above.
            if let failure { throw failure }
            return .unresolved
        }

        // Sorted for the same reason the MAL pool is: dictionary order is randomized per
        // process and the matcher's sort is not stable, so ties would resolve differently
        // between launches.
        let ordered = pool.values.sorted { $0.id < $1.id }

        // **The partition** (ADR-0016 Decision 3). MangaDex carries variant entries whose
        // alt-title lists contain the canonical title verbatim — *Tower of God (Book
        // Version)* ties the real series at 1.000 — and measured against the live API those
        // variants carry no `mal` link at all. An entry with no id cannot answer the
        // question being asked, so it does not belong in the ranking that answers it.
        // Removing it is not loosening the ambiguity guard; it is declining to count a
        // non-answer as a competing answer.
        let idBearing = ordered.filter { $0.malId != nil }
        let idLess = ordered.filter { $0.malId == nil }

        // Within the id-bearing pool, collapsing by `malId` *is* right — two entries that
        // agree on the id are two spellings of one answer, not a doubt — and it is safe
        // here precisely because every key is non-nil. Titles union rather than first-wins:
        // matching is free and more spellings can only help.
        var byMalId: [Int: [String]] = [:]
        for listing in idBearing {
            byMalId[listing.malId!, default: []].append(contentsOf: Self.titles(of: listing))
        }
        let idCandidates = byMalId
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, titles: $0.value) }

        if let matched = matcher.bestMatch(sourceTitles: sourceTitles, candidates: idCandidates) {
            return WorkResolution(malId: matched, harvestedTitles: byMalId[matched] ?? [])
        }

        // Ordering is not an optimization: matching the id-less pool first would let a
        // variant win outright and hide a correct id sitting in the other pool.
        guard let matchedListingId = matcher.bestMatch(
                sourceTitles: sourceTitles,
                candidates: idLess.map { (id: $0.id, titles: Self.titles(of: $0)) }),
              let identified = pool[matchedListingId] else {
            if let failure { throw failure }
            return .unresolved
        }

        // The right series, no id. **Harvest the spellings; do not re-search MyAnimeList
        // with them** (ADR-0019).
        //
        // ADR-0016's Decision 6 did re-search here. Measured on WeebCentral it fired four
        // times, spent 10 of the pass's 26 requests, and recovered nothing — so ADR-0019
        // declines to carry it over. That is *lack of evidence*, not refutation: four
        // firings is a sample of four, and the round would be worth revisiting on a source
        // that actually publishes alt titles, where the fan-out it feeds has something to
        // work with.
        //
        // The harvest itself stays, and the two must not be confused. It costs nothing —
        // the spellings are already in the response — and it is what grows `knownTitles`,
        // which is what reopens an `.unmatched` fingerprint on a later pass. Cutting it
        // alongside the re-search would lose the one part of this branch that pays for
        // itself.
        return WorkResolution(malId: nil, harvestedTitles: Self.titles(of: identified))
    }

    /// Every spelling a Listing goes by: its display title first, then its alternates.
    private static func titles(of listing: Manga) -> [String] {
        [listing.title] + (listing.altTitles ?? [])
    }

    /// The canonical MAL id for `manga`, or nil if none can be found with confidence.
    func malId(for manga: Manga) async -> Int? {
        // 1. Fast path — the source already told us (MangaDex via links.mal). No caching
        //    needed: it's free on every call.
        if let known = manga.malId { return known }

        // 2. Cache — a live entry answers without network.
        if let cached = store.resolution(sourceId: manga.sourceId, mangaId: manga.id),
           cached.isFresh() {
            if case .resolved(let id) = cached { return id }
            return nil   // fresh miss — don't re-hit MAL yet
        }

        // 3. Fuzzy — search MAL by title and match. A thrown/absent result is a transient
        //    failure: return nil WITHOUT recording a miss (only a real "candidates but no
        //    match" is worth caching).
        let candidates: [MALCandidate]
        do {
            candidates = try await search(manga.title)
        } catch {
            return nil
        }

        switch matcher.decide(sourceTitle: manga.title, candidates: candidates) {
        case .matched(let id):
            store.record(sourceId: manga.sourceId, mangaId: manga.id, .resolved(malId: id))
            return id
        case .noMatch:
            // 4. Bridge — ADR-0016 Decision 7. Bridged here as well as at the Work level,
            //    because the 2026-08-08 device check established these two resolvers are
            //    independent and can disagree: a Work-level refusal does not imply a
            //    Listing-level one. Leaving one bridged and the other not would widen a gap
            //    that has already cost a session.
            //
            //    Harvested spellings are dropped on this path rather than stored: there is
            //    no Work here to append them to, and this cache is keyed by Listing. The
            //    Work-level path is where they persist.
            //
            //    Scoped by ADR-0019, mirroring `isBridgeable`: a MangaDex Listing does not
            //    get bridged through MangaDex. Step 1 above already returned if it carried
            //    `links.mal`, so reaching here means MangaDex published none — searching it
            //    again asks a question it has already answered.
            guard manga.sourceId != LegacySourceID.unattributed else {
                store.record(sourceId: manga.sourceId, mangaId: manga.id, .unresolved(checkedAt: Date()))
                return nil
            }
            do {
                if let bridgedId = try await bridged(sourceTitles: Self.titles(of: manga)).malId {
                    store.record(sourceId: manga.sourceId, mangaId: manga.id, .resolved(malId: bridgedId))
                    return bridgedId
                }
            } catch {
                // Transient bridge failure. Nothing recorded — the same rule that guards the
                // MAL search above, for the same reason: a blip must not occupy the cache
                // slot for the full miss TTL.
                return nil
            }
            store.record(sourceId: manga.sourceId, mangaId: manga.id, .unresolved(checkedAt: Date()))
            return nil
        }
    }
}
