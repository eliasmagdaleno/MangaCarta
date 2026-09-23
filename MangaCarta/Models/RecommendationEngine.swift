//
//  RecommendationEngine.swift
//  MangaCarta
//
//  Orchestrates the "For You" rail: builds a TasteProfile from reading history
//  resolved through the Work store, asks a CandidateProvider for ranked candidates,
//  and mixes in seeded exploration so the rail moves between sessions.
//
//  It no longer back-fills tags. That job — fetching metadata for Works that lack it —
//  belongs to the upgrade queue (ADR-0008), which owns the provider budget and can
//  serve non-MangaDex Works. The old `scheduleBackfill` could only ever have fetched
//  MangaDex ids anyway.
//

import SwiftUI

/// Small seedable PRNG (SplitMix64) so exploration is deterministic within a session
/// yet reshuffles when reseeded. SystemRandomNumberGenerator can't be seeded.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
final class RecommendationEngine: ObservableObject {
    /// How engagement weights reach the upgrade queue. A closure rather than a
    /// `MetadataUpgradeQueue` reference, because the dependency only ever runs one way:
    /// the recommender must not be able to start, stop, or inspect the queue (ADR-0010).
    typealias PriorityPush = ([WorkID: Double]) -> Void

    /// Whether the upgrade queue already holds an unexpired failure for this Work — i.e.
    /// tagging it is not merely pending but currently ruled out. Read-only by construction:
    /// ADR-0010's seam, narrowed by ADR-0015 from *no coupling* to *no control*.
    ///
    /// Takes the whole `Work`, not a `WorkID`, because `UpgradeAttemptMemory.suppresses`
    /// does — its `.unmatched(knownTitlesCount:)` branch needs `knownTitles.count`, and an
    /// id-keyed closure would force a store lookup at the composition root, re-creating the
    /// mispairing that signature exists to prevent (ADR-0015 amendment 1).
    typealias TagBlocked = (Work) -> Bool

    /// Why the rail is or isn't rendering. Modelled as state rather than an `errorMessage`
    /// string (ADR-0015): these differ in what the reader can do about them, and none of
    /// them is an error — the app is working and has nothing to recommend.
    enum RailState: Equatable {
        /// `load()` in flight, nothing decided yet.
        case building
        /// Not enough tagged Works, but Works still in play could get there.
        case needMoreReading(tagged: Int, needed: Int)
        /// Enough reading, and tagging everything still in play cannot open the gate.
        case noTaggableSignal
        /// The rail is rendering, built from `tagged` of the `of` titles the reader has
        /// read. The payload rides on the state rather than a second published property
        /// for the same reason the refusal reason does: the definition of "tagged" and
        /// the population it is drawn from must exist in exactly one place, beside the
        /// gate that applies them (ADR-0015, amended 2026-08-10).
        ///
        /// `of` counts **Works with history entries** — read titles. Saved-but-unread
        /// library items are excluded because they can never reach `tagged`, and two
        /// Listings of one series count once (ADR-0001).
        case ready(tagged: Int, of: Int)
    }

    @Published private(set) var recommendations: [ScoredManga] = []
    /// Two of the four cases render nothing today. They are carried for diagnosis: the
    /// 2026-08-04 device check spent a full cycle on an empty rail and reached two wrong
    /// hypotheses before finding this gate shut upstream (ADR-0015).
    @Published private(set) var railState: RailState = .building

    private let history: HistoryStore
    private let library: LibraryStore
    private let profileStore: TasteProfileStore
    /// Required, unlike `HistoryStore`'s and `LibraryStore`'s optional references: the
    /// profile is now *built* through the Work store, so an engine without one would
    /// silently recommend nothing rather than degrade.
    private let workStore: WorkStore
    private let source: () -> MangaSource?
    private let makeProvider: (MangaSource) -> CandidateProvider
    private let now: () -> Date
    private let pushPriority: PriorityPush
    private let tagBlocked: TagBlocked

    private let minTaggedManga = 3
    private let poolLimit = 40
    private let coreFraction = 0.8

    private var seed: UInt64
    private var loadTask: Task<Void, Never>?
    private var loadedOnce = false

    init(history: HistoryStore,
         library: LibraryStore,
         profileStore: TasteProfileStore,
         workStore: WorkStore,
         source: @escaping () -> MangaSource?,
         makeProvider: @escaping (MangaSource) -> CandidateProvider = { @MainActor source in
             CompositeCandidateProvider(
                 tag: TagCandidateProvider(source: source),
                 mal: MALCandidateProvider(similar: MoreLikeThisProvider()))
         },
         now: @escaping () -> Date = Date.init,
         seed: UInt64? = nil,
         // Defaulted to a no-op so every existing construction site — previews,
         // tests, the debug views — stays valid and stays silent.
         pushPriority: @escaping PriorityPush = { _ in },
         // Same defaulting rule as `pushPriority`: no existing construction site changes,
         // and an engine without the queue simply never reports `noTaggableSignal`.
         tagBlocked: @escaping TagBlocked = { _ in false }) {
        self.history = history
        self.library = library
        self.profileStore = profileStore
        self.workStore = workStore
        self.source = source
        self.makeProvider = makeProvider
        self.now = now
        self.pushPriority = pushPriority
        self.tagBlocked = tagBlocked
        self.seed = seed ?? UInt64.random(in: .min ... .max)
    }

    /// Build once per Home appearance (cheap no-op if already built this session).
    func load() {
        guard !loadedOnce else { return }
        loadedOnce = true
        loadTask?.cancel()
        loadTask = Task { await rebuild() }
    }

    /// Pull-to-refresh: reseed exploration and rebuild.
    func refresh() async {
        seed = UInt64.random(in: .min ... .max)
        loadTask?.cancel()
        await rebuild()
    }

    func markNotInterested(_ manga: Manga) {
        // Minted so the dismissal can eventually suppress this manga on *every*
        // source, not just the one it was dismissed from (ADR-0007).
        _ = workStore.mint(from: manga)
        profileStore.markNotInterested(mangaId: manga.id)
        recommendations.removeAll { $0.manga.id == manga.id }
    }

    func markMoreLikeThis(_ manga: Manga) {
        _ = workStore.mint(from: manga)
        profileStore.markMoreLikeThis(mangaId: manga.id)
        Task { await rebuild() }
    }

    private func rebuild() async {
        // `railState` is published on both paths BEFORE the cancellation check below, or a
        // cancelled rebuild strands the UI on a stale explanation (ADR-0015).
        let profile: TasteProfile, excluding: Set<String>
        switch profileAndExclusions() {
        case .refused(let state):
            railState = state
            recommendations = []
            return
        case .ready(let p, let ex, let state):
            railState = state
            (profile, excluding) = (p, ex)
        }
        guard let source = source() else {
            recommendations = []
            return
        }
        let pool = (try? await makeProvider(source)
            .candidates(for: profile, excluding: excluding, limit: poolLimit)) ?? []
        guard !Task.isCancelled else { return }
        recommendations = compose(pool: pool)
    }

    /// The full ranked recommendation pool as plain `Manga`, WITHOUT the rail's
    /// exploration reshuffle — the "See all" grid wants the straight ranking. Empty
    /// during cold-start, exactly like the rail.
    func rankedRecommendations(limit: Int = 100) async -> [Manga] {
        // The grid ignores the refusal reason: it is only reachable from a rail that is
        // already rendering, so a refusal here means the profile changed underneath it.
        guard case .ready(let profile, let excluding, _) = profileAndExclusions() else { return [] }
        guard let source = source() else { return [] }
        let pool = (try? await makeProvider(source)
            .candidates(for: profile, excluding: excluding, limit: limit)) ?? []
        return pool.map(\.manga)
    }

    /// Either the profile and exclusion set, or the reason the gate is shut.
    private enum ProfileOutcome {
        /// Carries the `.ready` state fully formed, not just the profile: its basis count
        /// is drawn from the same `signals` the gate is applied to, and recomputing it in
        /// `rebuild()` would need that array published or rebuilt — the drift this
        /// function's doc comment already rejects for the refusal reason.
        case ready(TasteProfile, Set<String>, RailState)
        case refused(RailState)
    }

    /// Builds the taste profile and the exclusion set (read ∪ saved ∪ not-interested),
    /// or the reason there isn't enough signal. Shared by the rail and the grid.
    ///
    /// The reason is returned rather than recomputed by the caller because this function
    /// already knows it: computing `railState` beside the gate would put the threshold and
    /// the definition of "tagged" in two places that drift the first time either is tuned
    /// (ADR-0015).
    private func profileAndExclusions() -> ProfileOutcome {
        let savedIds = Set(library.items.map(\.id))
        // LibraryItem carries no malId/description/status/year — synthesize a minimal
        // Manga per saved item so TasteProfile.build can materialize seeds for it.
        let libraryManga = library.items.map { item in
            Manga(id: item.id, sourceId: item.sourceId ?? LegacySourceID.unattributed, title: item.title,
                 description: "", status: "unknown", year: nil, coverURL: item.coverURL, malId: nil)
        }
        // Bound to a local rather than passed inline: the ceiling test below reuses it,
        // and `resolveSignals()` mints, so calling it twice is a side effect twice.
        let signals = resolveSignals()
        let profile = TasteProfile.build(signals: signals,
                                         savedIds: savedIds,
                                         moreLikeThis: Set(profileStore.moreLikeThis),
                                         now: now(),
                                         libraryItems: libraryManga)
        guard profile.taggedMangaCount >= minTaggedManga, !profile.isEmpty else {
            return .refused(refusalReason(signals: signals, profile: profile))
        }
        // AFTER the gate, deliberately: a rejected profile carries no ordering, and
        // pushing its empty map would replace whatever the queue is already draining
        // against with a cold-start blank (ADR-0010). Here rather than in `rebuild`
        // because "See all" builds the same profile and is the same signal.
        pushPriority(profile.workWeights)
        let readIds = Set(history.entries.map(\.mangaId))
        // The denominator: Works the reader has actually read. Same `entries` filter
        // `TasteProfile.build` counts `taggedMangaCount` under, or the two halves of
        // "3 of 5" would be drawn from different populations.
        //
        // **The filter is vacuous today and no test can catch its removal** — verified by
        // mutation, not assumed: `resolveSignals()` builds every signal from a history
        // entry, so `entries` is non-empty by construction. It is kept as the written
        // form of the alignment with `TasteProfile.build`, which would otherwise be an
        // undocumented coincidence the moment either side gains a second signal source.
        // Recorded rather than deleted or silently trusted, because ADR-0015's recurring
        // failure is exactly a claim that reads as checked and is not.
        let readTitles = signals.filter { !$0.entries.isEmpty }.count
        return .ready(profile,
                      readIds.union(savedIds).union(profileStore.notInterested),
                      .ready(tagged: profile.taggedMangaCount, of: readTitles))
    }

    /// A **ceiling test**, not a universal quantifier (ADR-0015 amendment 3):
    ///
    ///     noTaggableSignal ⟺ taggedMangaCount + (untagged, not blocked).count < minTaggedManga
    ///
    /// Read as "even if every Work still in play got tagged, the gate cannot open". The
    /// original "every untagged Work is blocked" never holds when one Work fails
    /// transiently on every drain pass, because transient failures record nothing — so a
    /// single such Work would suppress the notice forever, by the one route no test catches.
    ///
    /// Monotone toward silence: a Work getting tagged or a TTL expiring can only move the
    /// state back to `needMoreReading`, never falsely to the notice. A Work missing from the
    /// store counts as in play for the same reason — an unanswerable question is not a no.
    ///
    /// **Guarded by a reading precondition (ADR-0015 amendment 8).** The ceiling test alone
    /// says "even tagging everything cannot open the gate", which is trivially true of a
    /// reader who has read nothing — and on 2026-08-10 the simulator rendered the dead-end
    /// notice on a device with no `history.entries` at all. Amendment 3 claimed the ceiling
    /// test *subsumed* the original "enough read Works to clear the threshold if they were
    /// tagged" clause. It does not subsume it; it deletes it. Both halves are required:
    ///
    ///     noTaggableSignal ⟺ readWorks ≥ minTaggedManga
    ///                       ∧ taggedMangaCount + (untagged, not blocked).count < minTaggedManga
    ///
    /// The first half is what makes the state's own name true — *enough reading*, nothing
    /// identifiable. Without it, cold start and a permanent dead end render identically,
    /// which is the exact defect this ADR was written to fix.
    private func refusalReason(signals: [TasteProfile.WorkSignal], profile: TasteProfile) -> RailState {
        let readWorks = signals.filter { !$0.entries.isEmpty }.count
        guard readWorks >= minTaggedManga else {
            return .needMoreReading(tagged: profile.taggedMangaCount, needed: minTaggedManga)
        }

        let stillInPlay = signals.filter { signal in
            // Same `entries` filter TasteProfile.build counts under, or the two disagree.
            guard !signal.entries.isEmpty, signal.tags.isEmpty else { return false }
            guard let work = workStore.work(signal.workId) else { return true }
            return !tagBlocked(work)
        }.count

        guard profile.taggedMangaCount + stillInPlay < minTaggedManga else {
            return .needMoreReading(tagged: profile.taggedMangaCount, needed: minTaggedManga)
        }
        return .noTaggableSignal
    }

    /// Whether a Work has been *refused* a catalog match, rather than merely not answered
    /// yet — the per-title half of what `railState` says about the library as a whole.
    ///
    /// Lives here rather than reaching into `UpgradeAttemptMemory` from a view, because
    /// ADR-0010 keeps that memory out of the environment: it publishes nothing, so a view
    /// that could reach it could only misuse it. The engine already holds this predicate
    /// and is already an `EnvironmentObject`, and "is this title shaping my
    /// recommendations" is a recommender question — a second way to ask it is a second
    /// thing that can drift.
    ///
    /// **Deliberately not published.** The value is a settled refusal reopened on a
    /// fourteen-day TTL, not something that changes while a screen is open. A title opened
    /// mid-drain shows nothing and gains the notice on the next visit; making a store
    /// publish to close that gap would put a publisher on the drain's hot path to move one
    /// label a few seconds earlier.
    func isUnmatchable(_ work: Work) -> Bool { tagBlocked(work) }

    /// Groups reading history by Work — the seam where Listing-keyed edges meet Work
    /// identity (ADR-0007). **This mutates the store**, deliberately, in two ways:
    ///
    /// 1. It mints for entries that have none. All history written before slice 3
    ///    predates minting, so without this an existing user's profile would come back
    ///    empty on first launch after the update. Reading *is* a commitment, so minting
    ///    here is the same rule applied retroactively — and `mint` is idempotent and,
    ///    since it only marks the store dirty when it learns something, cheap to repeat.
    /// 2. It seeds a Work that has no snapshot from the pre-slice-3 tag cache. That is
    ///    the migration which makes retiring `taste.tagCache` safe (step 4); until this
    ///    runs, those tags exist only in a Listing-keyed cache no one will read.
    private func resolveSignals() -> [TasteProfile.WorkSignal] {
        var entriesByWork: [WorkID: [ReadingEntry]] = [:]
        var order: [WorkID] = []                       // newest-read first, as history is

        for entry in history.entries {
            let listing = Manga(id: entry.mangaId, sourceId: entry.sourceId ?? LegacySourceID.unattributed,
                                title: entry.mangaTitle, description: "", status: "unknown",
                                // Not `nil`: an id the source published is carried on the
                                // entry, and `mint` absorbs it so the Work is never a
                                // resolution question (ADR-0018).
                                year: nil, coverURL: entry.coverURL, malId: entry.malId)
            let id = workStore.mint(from: listing)
            if entriesByWork[id] == nil { order.append(id) }
            entriesByWork[id, default: []].append(entry)

            if workStore.work(id)?.snapshot == nil,
               let cached = profileStore.legacyTagCache[entry.mangaId], !cached.isEmpty {
                workStore.applyProvisionalSnapshot(tags: cached, to: id)
            }
        }

        return order.map { id in
            TasteProfile.WorkSignal(workId: id,
                                    malId: workStore.work(id)?.externalIds.mal,
                                    entries: entriesByWork[id] ?? [],
                                    tags: workStore.work(id)?.snapshot?.genres ?? [])
        }
    }

    /// Mostly top matches, plus a seeded sample from the lower-ranked tail (adjacent
    /// interests), then a seeded shuffle — stable within a session, fresh across them.
    func compose(pool: [ScoredManga], railSize: Int = 20) -> [ScoredManga] {
        guard pool.count > railSize else { return pool }
        var rng = SeededRNG(seed: seed)
        let coreCount = Int(Double(railSize) * coreFraction)
        let core = Array(pool.prefix(coreCount))
        let tail = Array(pool.suffix(from: coreCount))
        let explore = Array(tail.shuffled(using: &rng).prefix(railSize - coreCount))
        var combined = core + explore
        combined.shuffle(using: &rng)
        return combined
    }

}
