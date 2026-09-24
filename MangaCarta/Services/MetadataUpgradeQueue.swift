//
//  MetadataUpgradeQueue.swift
//  MangaCarta
//
//  ADR-0008 (policy), ADR-0009 (construction), ADR-0010 (the loop and its wiring).
//

import Foundation
import os

@MainActor
final class MetadataUpgradeQueue: ObservableObject {
    typealias Sleep = (TimeInterval) async throws -> Void

    // MARK: - Observability
    //
    // The queue has no UI and produces no user-visible output until a snapshot happens to
    // change a recommendation, so without this its only observable artifact is
    // `works.json` on disk. Filter with `subsystem:Elias-Magdaleno.Manga-Reader
    // category:UpgradeQueue` in Console.app, or watch the Xcode console.
    private static let log = Logger(subsystem: "Elias-Magdaleno.Manga-Reader",
                                    category: "UpgradeQueue")

    /// What to call a Work in the log. Titles are the user's reading history, so they are
    /// only interpolated in DEBUG — where the log is being read off a development machine
    /// by its owner. Release builds get the id prefix, which is meaningless outside the
    /// store but still lets you follow one Work across several lines.
    private func label(_ work: Work) -> String {
        #if DEBUG
        return work.displayTitle
        #else
        return String(work.id.raw.uuidString.prefix(8))
        #endif
    }

    /// What one turn of the loop did. `run` branches only on `.idle`.
    enum DrainStep: Equatable {
        case upgraded(WorkID)
        case failed(WorkID)
        case idle
    }

    private let works: WorkStore
    private let anilist: AniListAPI
    private let rateLimiter: AniListRateLimiter
    private let resolver: MALEntityResolver
    private let memory: UpgradeAttemptMemory
    private let idleInterval: TimeInterval
    private let now: () -> Date
    private let sleep: Sleep
    /// Announced after a Work learns external ids, carrying the id that survived — writing
    /// ids may merge two Works, and the caller needs the survivor. Default no-op: the queue
    /// owns metadata and must not grow a dependency on whoever is listening (ADR-0010).
    private let workMetadataChanged: (WorkID) -> Void

    init(works: WorkStore,
         anilist: AniListAPI = AniListAPI(),
         rateLimiter: AniListRateLimiter = AniListRateLimiter(),
         resolver: MALEntityResolver,
         memory: UpgradeAttemptMemory? = nil,
         idleInterval: TimeInterval = 60,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         workMetadataChanged: @escaping (WorkID) -> Void = { _ in }) {
        self.works = works
        self.anilist = anilist
        self.rateLimiter = rateLimiter
        self.resolver = resolver
        self.memory = memory ?? UpgradeAttemptMemory()
        self.idleInterval = idleInterval
        self.now = now
        self.sleep = sleep
        self.workMetadataChanged = workMetadataChanged
    }

    /// The last engagement-weight map the recommender pushed (ADR-0009). **Replaces**
    /// rather than merges: the map is complete for every Work with reading history, so a
    /// Work dropping out of it means its history is gone and it belongs in the tail.
    private var priority: [WorkID: Double] = [:]

    func setPriority(_ weights: [WorkID: Double]) { priority = weights }

    // MARK: - Lifecycle

    /// `internal` so tests can await the loop's completion; nothing in the app reads it.
    private(set) var loopTask: Task<Void, Never>?

    /// Idempotent, because `.active` recurs without an intervening `.background` — a
    /// dismissed notification banner is enough. Without the guard every one of those
    /// leaks another loop and the queue stops being serial by construction (ADR-0010).
    func start() {
        guard loopTask == nil else {
            Self.log.debug("start() ignored — loop already running")
            return
        }
        Self.log.info("loop started")
        loopTask = Task { [weak self] in await self?.run() }
    }

    /// Cancels without awaiting: blocking a `scenePhase` handler on an in-flight network
    /// request would be a far worse trade than losing at most one attempt record.
    func stop() {
        if loopTask != nil { Self.log.info("loop stopped") }
        loopTask?.cancel()
        loopTask = nil
    }

    func flush() { memory.flush() }

    /// One branch. A tripped breaker returns `.idle` exactly as an empty scan does, so the
    /// loop never needs to know *why* it is idling (ADR-0010).
    private func run() async {
        while !Task.isCancelled {
            if await drainOnce(now: now()) == .idle {
                Self.log.debug("idle — sleeping \(self.idleInterval, format: .fixed(precision: 0))s")
                // `Task.sleep` throws only on cancellation, so a throw here means stop.
                do { try await sleep(idleInterval) } catch { return }
            }
        }
    }

    // MARK: - One turn of the loop

    /// Upgrades at most one Work. No sleeps of its own — the only pacing is the rate
    /// limiter's — so the whole of the queue's behaviour is testable without wall clock.
    ///
    /// `internal` rather than `private` purely so tests can call it; the app calls
    /// `start()`/`stop()`/`flush()`.
    func drainOnce(now: Date) async -> DrainStep {
        guard let work = nextCandidate(now: now) else {
            // Nothing left that this pass hasn't already tried. Ending the pass here is
            // what reopens the transiently-failed Works: they are skipped for the
            // remainder of a pass, not for the session.
            endPass()
            return .idle
        }

        let resolved: MALEntityResolver.WorkResolution
        do {
            resolved = try await resolver.resolve(work)
        } catch let error where permanentStatus(of: error) != nil {
            // An *answer*, not an outage. Recorded as `.unmatched` because that is exactly
            // the reopen condition wanted: a new synonym changes the query, and nothing
            // else will. See `permanentStatus` for why this branch has to exist at all.
            Self.log.info("""
                unsearchable "\(self.label(work), privacy: .public)" — \
                HTTP \(self.permanentStatus(of: error) ?? 0, privacy: .public), \
                recorded rather than retried
                """)
            memory.record(.unmatched(knownTitlesCount: work.knownTitles.count), for: work.id, now: now)
            return progress(work.id)
        } catch {
            // Transient: record NOTHING (ADR-0008). An outage must not suppress the Work
            // for the fourteen-day TTL.
            Self.log.error("""
                resolve failed (transient) "\(self.label(work), privacy: .public)": \
                \(error.localizedDescription, privacy: .public)
                """)
            return fail(work.id)
        }
        // Harvest before recording anything (ADR-0016 Decision 5). `knownTitles` is
        // monotonic, and `.unmatched` is fingerprinted on its count, so the post-harvest
        // count is the only correct one to record: writing the stale pre-harvest count would
        // reopen this Work on the very next pass and re-run the searches that just failed
        // with these exact titles.
        var knownTitlesCount = work.knownTitles.count
        if !resolved.harvestedTitles.isEmpty,
           let grown = works.noteTitles(resolved.harvestedTitles, on: work.id) {
            Self.log.debug("""
                harvested \(resolved.harvestedTitles.count, privacy: .public) spelling(s) for \
                "\(self.label(work), privacy: .public)" — \(knownTitlesCount, privacy: .public) \
                → \(grown, privacy: .public) known titles
                """)
            knownTitlesCount = grown
        }

        guard let malId = resolved.malId else {
            // Neither MAL nor the MangaDex bridge produced a confident match. That is an
            // answer, and it is fingerprinted on the title count so a new synonym reopens
            // it at once — against the harvested count, per the note above.
            //
            // This is the common outcome for anything MAL does not carry — doujinshi,
            // scanlation-only releases — and it is why a library can sit permanently
            // below ADR-0011's three-resolved-Works gate.
            Self.log.info("""
                unmatched "\(self.label(work), privacy: .public)" — nothing cleared the \
                threshold (\(knownTitlesCount, privacy: .public) known titles)
                """)
            memory.record(.unmatched(knownTitlesCount: knownTitlesCount), for: work.id, now: now)
            return progress(work.id)
        }

        // Written BEFORE the fetch (ADR-0009): a transient AniList failure must not
        // rewind the Work to a resolution case. This may merge, which is intended and
        // is safe precisely because no snapshot exists yet to lose.
        works.setExternalIds(ExternalIDs(mal: malId, anilist: nil), on: work.id)

        // Resolve before you remember (ADR-0010). The line above may have merged this
        // Work away; `work(_:)` follows the alias, so `live.id` is the survivor.
        guard let live = works.work(work.id) else { return .idle }

        // The Work now carries a MAL id. Anything waiting on that — the progress outbox's
        // deferred table — is told here, and told about the survivor of any merge above.
        workMetadataChanged(live.id)

        // The merge may have answered the question already. Fetching now would spend a
        // paced request to overwrite good data with the same data.
        guard live.snapshot == nil || live.snapshot?.isStale(now: now) == true else {
            Self.log.debug("""
                skip "\(self.label(live), privacy: .public)" — a merge already left it fresh
                """)
            memory.forget(live.id)
            return progress(live.id)
        }

        let api = anilist
        let result: AniListWork
        do {
            Self.log.debug("""
                fetching AniList for "\(self.label(live), privacy: .public)" (mal \(malId, privacy: .public))
                """)
            result = try await rateLimiter.run { try await api.work(malId: malId) }
        } catch AniListError.notFound {
            // The one terminal AniListError. Only the TTL reopens it — re-matching yields
            // the same id forever — and it is an answer, so it does not feed the breaker.
            Self.log.info("""
                absent from AniList "\(self.label(live), privacy: .public)" (mal \(malId, privacy: .public))
                """)
            memory.record(.absentFromProvider(malId: malId), for: live.id, now: now)
            return progress(live.id)
        } catch {
            Self.log.error("""
                AniList fetch failed (transient) "\(self.label(live), privacy: .public)": \
                \(error.localizedDescription, privacy: .public)
                """)
            return fail(live.id)
        }

        // Applied either way: the AniList id and canonical titles are worth keeping even
        // when the metadata is not.
        works.apply(result, to: live.id, now: now)

        guard result.hasContent else {
            // `apply` declined to replace the snapshot, so the Work is still provisional
            // and still unconditionally stale. Same reopen condition as a missing entry,
            // so the same outcome carries it (ADR-0010).
            Self.log.info("""
                empty AniList record "\(self.label(live), privacy: .public)" \
                (anilist \(result.anilistId, privacy: .public)) — snapshot left provisional
                """)
            memory.record(.absentFromProvider(malId: malId), for: live.id, now: now)
            return progress(live.id)
        }

        // The line worth watching. A non-zero ranked count is the only proof the ranked
        // axis arrived: MangaDex has no rank, and provisional snapshots write `tags: []`.
        Self.log.info("""
            upgraded "\(self.label(live), privacy: .public)" — anilist \(result.anilistId, privacy: .public), \
            \(result.genres.count, privacy: .public) genres, \
            \(result.tags.count, privacy: .public) ranked tags
            """)
        memory.forget(live.id)
        return progress(live.id)
    }

    /// The HTTP status behind `error` when it is a **permanent** client error, else nil.
    ///
    /// ADR-0008 splits failures into "answers" (remembered) and "outages" (recorded
    /// nowhere, retried). A 4xx is neither obviously — but it is a statement about the
    /// *request*, and reissuing it unchanged returns the same status forever, so it
    /// behaves as an answer and must be remembered as one.
    ///
    /// Treating it as an outage instead is a livelock, observed in production 2026-07-28:
    /// three Works with titles over MAL's 64-character `q` limit each 400'd, recorded
    /// nothing, and tripped the breaker on the third. `endPass` then cleared the skip set,
    /// so the following pass replayed the identical three — every 60 seconds, forever,
    /// while the Works behind them were never reached.
    ///
    /// 429 is the one 4xx that genuinely means "later": `MyAnimeListAPI.request` already
    /// retries it once and surfaces `.rateLimited` when it persists, which stays transient.
    private func permanentStatus(of error: Error) -> Int? {
        let code: Int
        switch error {
        case MyAnimeListError.httpStatus(let status): code = status
        case AniListError.httpStatus(let status): code = status
        default: return nil
        }
        guard (400..<500).contains(code), code != 429 else { return nil }
        return code
    }

    // MARK: - Pass bookkeeping

    /// Works that failed *transiently* this pass. In memory, never persisted: attempt
    /// memory is for semantic answers, and a network blip is not an answer about a Work
    /// (ADR-0010). Cancel-on-background already gives every foregrounding a clean slate.
    private var failedThisPass: Set<WorkID> = []
    private var consecutiveFailures = 0

    private func progress(_ id: WorkID) -> DrainStep {
        consecutiveFailures = 0
        return .upgraded(id)
    }

    /// Skipping for the rest of the pass is what makes forward progress structural: every
    /// turn either upgrades a Work or shrinks the eligible list, so a pass terminates.
    private func fail(_ id: WorkID) -> DrainStep {
        failedThisPass.insert(id)
        consecutiveFailures += 1
        // Three in a row means the network, not the Work. Idle now rather than spending
        // another paced request to learn the same thing.
        guard consecutiveFailures < 3 else {
            Self.log.error("breaker tripped — 3 consecutive failures, ending the pass")
            endPass()
            return .idle
        }
        return .failed(id)
    }

    private func endPass() {
        failedThisPass.removeAll()
        consecutiveFailures = 0
    }

    // MARK: - Scanning

    /// The eligible Work that should be upgraded next, or nil when there is nothing to
    /// do. A full scan per request is deliberate (ADR-0009): it is a dictionary key copy
    /// and a filter against a 2-second request floor, and re-scanning is what lets a Work
    /// minted mid-read, or a freshly pushed weight, take effect at the next request
    /// rather than the next pass (ADR-0010).
    private func nextCandidate(now: Date) -> Work? {
        let all = works.allWorkIds()
        let eligible = all
            .filter { !failedThisPass.contains($0) }
            .compactMap { works.work($0) }
            // Staleness AND attempt memory. The store can only ever apply the first half,
            // which is why the whole predicate lives here (ADR-0009).
            .filter { $0.snapshot == nil || $0.snapshot?.isStale(now: now) == true }
            .filter { !memory.suppresses($0, now: now) }

        let picked = eligible.min { orders($0, before: $1) }
        // Answers "why is nothing happening?" — an empty eligible list against a non-empty
        // store is the normal quiet state, not a fault: everything is either fresh or
        // suppressed by attempt memory.
        Self.log.debug("""
            scan: \(all.count, privacy: .public) works, \
            \(eligible.count, privacy: .public) eligible, \
            \(self.failedThisPass.count, privacy: .public) skipped this pass \
            → \(picked.map { self.label($0) } ?? "nothing", privacy: .public)
            """)
        return picked
    }

    /// Engagement weight descending, then Works with no weight at all — which means no
    /// reading history (ADR-0009's amended tail). Ties and the whole tail break on the
    /// Work id, because `allWorkIds()` order is randomized per process and an arbitrary
    /// order still has to be a *stable* one.
    private func orders(_ lhs: Work, before rhs: Work) -> Bool {
        switch (priority[lhs.id], priority[rhs.id]) {
        case let (left?, right?):
            return left == right ? lhs.id.raw.uuidString < rhs.id.raw.uuidString : left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return lhs.id.raw.uuidString < rhs.id.raw.uuidString
        }
    }
}
