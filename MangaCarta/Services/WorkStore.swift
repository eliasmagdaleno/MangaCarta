//
//  WorkStore.swift
//  MangaCarta
//
//  The local, app-owned catalog of Works (ADR-0002, shaped by ADR-0007).
//
//  Deliberately unlike every other store in this app: there is **no public
//  dictionary**. `EntityResolutionStore` and `TasteProfileStore` both expose
//  `@Published private(set) var cache`, but Work lookups have to follow merge
//  aliases, and an accessor callers can bypass is an accessor callers will bypass.
//

import Foundation

@MainActor
final class WorkStore: ObservableObject {
    private var works: [WorkID: Work] = [:]
    private var listingIndex: [ListingKey: WorkID] = [:]
    /// External id → Work. Keyed by a `"provider:value"` string so one flat index
    /// covers every provider. Because the Work id is opaque, **this index — not the
    /// id's spelling — is what makes arriving at the same Work twice converge.**
    private var externalIdIndex: [String: WorkID] = [:]
    /// Merged-away Work id → its survivor. Grows by one entry per merge and is never
    /// pruned: that is the point.
    private var aliases: [WorkID: WorkID] = [:]
    /// Tags seen on a detail screen for a Listing with no Work yet. **In-memory and
    /// session-scoped on purpose** — browsing must not write to the store (ADR-0007),
    /// so these are staged, not persisted, and only survive as far as a mint.
    private var pendingTags: [ListingKey: [Tag]] = [:]

    private let directory: URL
    private let saveDebounce: TimeInterval
    private var loaded = false
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    /// The store's own file. Application Support, not `Caches/`: this is
    /// authoritative user data, and losing it orphans history and manual links.
    /// (Chapter counts are the opposite — disposable, and live in their own cache.)
    /// `nonisolated` so it can be used as a default argument, which is evaluated
    /// outside the actor.
    nonisolated static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var fileURL: URL { directory.appendingPathComponent("works.json") }

    init(directory: URL = WorkStore.applicationSupportDirectory(),
         saveDebounce: TimeInterval = 1.0) {
        self.directory = directory
        self.saveDebounce = saveDebounce
    }

    // MARK: - Lookup

    /// The only way to get a Work. Follows merge aliases, so a stale id returns the
    /// Work it was merged into rather than nil. There is deliberately no public
    /// dictionary to read around this.
    func work(_ id: WorkID) -> Work? {
        loadIfNeeded()
        return resolve(id).flatMap { works[$0] }
    }

    /// Follows the alias chain to the live Work id.
    private func resolve(_ id: WorkID) -> WorkID? {
        var current = id
        // Chains are short in practice, but the walk is bounded anyway: this runs on
        // every lookup on the main actor, so a cycle would hang the UI rather than
        // merely return a wrong answer.
        for _ in 0...32 {
            if works[current] != nil { return current }
            guard let next = aliases[current] else { return nil }
            current = next
        }
        return nil
    }

    func workId(for listing: ListingKey) -> WorkID? {
        loadIfNeeded()
        return listingIndex[listing]
    }

    /// Removes one source Listing; a Work with no remaining Listings is deleted.
    func removeListing(_ listing: ListingKey) {
        loadIfNeeded()
        guard let id = listingIndex[listing], let resolved = resolve(id), var work = works[resolved] else { return }
        listingIndex[listing] = nil
        work.listings.removeAll { $0 == listing }
        if work.listings.isEmpty {
            works[resolved] = nil
            externalIdIndex = externalIdIndex.filter { $0.value != resolved }
        } else {
            works[resolved] = work
        }
        markDirty()
    }

    func workId(externalId ids: ExternalIDs) -> WorkID? {
        loadIfNeeded()
        return Self.indexKeys(for: ids).lazy.compactMap { self.externalIdIndex[$0] }.first
    }

    /// Every live Work id. The upgrade queue scans these; it applies its **own**
    /// eligibility predicate, because half of that predicate — the attempt memory — lives
    /// in a file the store knows nothing about, so a filter here could only ever be
    /// re-filtered (ADR-0009).
    ///
    /// This does not weaken the no-public-dictionary rule above: that rule exists so
    /// every lookup follows merge aliases, and merged-away losers are removed from
    /// `works`, so every id returned is already resolved. **Order is unspecified** —
    /// dictionary key order is randomized per process, and ordering is the caller's job.
    func allWorkIds() -> [WorkID] {
        loadIfNeeded()
        return Array(works.keys)
    }

    // MARK: - Minting

    /// Creates a Work from a Listing, or returns the existing one.
    ///
    /// **Synchronous, local, network-free** — this sits on the path where the user
    /// just opened a chapter, so it cannot block the reader and must work offline.
    /// It also never *guesses*: two Listings converge only on an external id both
    /// already carry, never on a similar title. Title matching is resolution's job,
    /// and it is precision-biased for a reason (ADR-0005).
    func mint(from listing: Manga) -> WorkID {
        loadIfNeeded()
        let key = ListingKey(listing)
        let ids = ExternalIDs(mal: listing.malId, anilist: nil)

        // Already minted from this exact Listing. **Only a mint that actually learns
        // something marks the store dirty** — this runs on every page turn, and
        // re-arming the debounce each time would defer the write for as long as the
        // user keeps reading.
        if let existing = listingIndex[key] {
            if absorb(ids, into: existing, title: listing.title) { markDirty() }
            applyPendingTags(for: key, to: existing)
            return existing
        }
        // Known under an external id this Listing publishes — the free dedupe path.
        if let existing = workId(externalId: ids) {
            let linked = link(key, to: existing, title: listing.title)
            let absorbed = absorb(ids, into: existing, title: listing.title)
            if linked || absorbed { markDirty() }
            applyPendingTags(for: key, to: existing)
            return existing
        }
        markDirty()

        var work = Work(id: WorkID(),
                        displayTitle: listing.title,
                        knownTitles: [],
                        externalIds: ids,
                        listings: [key],
                        snapshot: nil)
        work.noteTitle(listing.title)
        works[work.id] = work
        listingIndex[key] = work.id
        reindexExternalIds(of: work.id)
        applyPendingTags(for: key, to: work.id)
        return work.id
    }

    // MARK: - Metadata snapshots

    /// Records the tags a detail screen just loaded. Every source has tags, so this
    /// is where non-MangaDex reading stops being invisible (ADR-0001's bug).
    ///
    /// **Viewing a detail page is not a commitment**, so this never mints. When the
    /// Work doesn't exist yet the tags are staged in memory instead: the real flow is
    /// open-the-page-then-tap-a-chapter, and dropping them would leave the *first*
    /// read of every manga with no signal until the user happened to come back.
    func noteListingTags(_ tags: [Tag], for listing: Manga, now: Date = Date()) {
        guard !tags.isEmpty else { return }
        loadIfNeeded()
        let key = ListingKey(listing)
        if let existing = listingIndex[key] {
            applyProvisionalSnapshot(tags: tags, to: existing, now: now)
        } else {
            pendingTags[key] = tags
        }
    }

    /// Applies and **consumes** tags staged before the Work existed. One-shot by
    /// construction: `mint` runs on every page turn, and re-applying would re-arm
    /// the debounced save every time.
    private func applyPendingTags(for key: ListingKey, to id: WorkID) {
        guard let tags = pendingTags.removeValue(forKey: key) else { return }
        applyProvisionalSnapshot(tags: tags, to: id)
    }

    /// The provisional tier: a snapshot built from the Listing's own tags. Costs no
    /// request — MangaDex's tags arrive with the detail fetch the UI already makes —
    /// so the recommender has signal from launch, before any provider is queried.
    func applyProvisionalSnapshot(tags: [Tag], to id: WorkID, now: Date = Date()) {
        loadIfNeeded()
        guard let resolved = resolve(id), var work = works[resolved] else { return }
        // The provisional tier is a **floor, not an overwrite**. A real provider's
        // snapshot outranks the Listing's own tags, so re-opening a detail page for
        // an already-resolved Work must not drag it back down — that would undo a
        // fetch and make a Work's provider depend on which screen was last visited.
        guard work.snapshot == nil || work.snapshot?.provider == .mangadex else { return }
        defer { markDirty() }
        work.snapshot = MetadataSnapshot(
            provider: .mangadex,
            fetchedAt: now,
            genres: tags.map { QueryableTag(name: $0.name, group: $0.group) },
            tags: [],                       // MangaDex publishes no per-title rank.
            publicationStatus: .unknown,
            chapterTotal: nil)
        works[resolved] = work
    }

    /// Upgrades a Work to a provider snapshot, **replacing** whatever was there.
    /// One authority per Work; external ids and known titles are the exceptions and
    /// accumulate.
    func apply(_ provider: AniListWork, to id: WorkID, now: Date = Date()) {
        loadIfNeeded()
        defer { markDirty() }
        guard let resolved = resolve(id), var work = works[resolved] else { return }

        // Replacement is wholesale, which can lose information -- so a snapshot with
        // nothing on the searchable axis doesn't get to discard one that has content.
        // The ids below still accumulate: learning the AniList id is worth keeping
        // even when the metadata behind it isn't.
        if provider.hasContent || work.snapshot == nil {
            work.snapshot = MetadataSnapshot(
                provider: .anilist,
                fetchedAt: now,
                genres: provider.genres.map { QueryableTag(name: $0) },
                tags: provider.tags,
                publicationStatus: provider.publicationStatus,
                chapterTotal: provider.chapterTotal)
        }
        work.externalIds.absorb(ExternalIDs(mal: provider.malId, anilist: provider.anilistId))
        for title in provider.knownTitles { work.noteTitle(title) }
        works[resolved] = work
        reindexExternalIds(of: resolved)
    }

    // MARK: - Linking and merging

    /// Records external ids on a Work, unioning with what's already there.
    /// Called when resolution learns an id the Listing didn't publish.
    func setExternalIds(_ ids: ExternalIDs, on id: WorkID) {
        loadIfNeeded()
        defer { markDirty() }
        guard let resolved = resolve(id) else { return }
        absorb(ids, into: resolved, title: "")
    }

    /// Adds spellings to a Work's `knownTitles`, unioning with what's already there.
    /// Returns the Work's title count **after** the addition, or nil if the id resolves
    /// to nothing.
    ///
    /// The count is returned rather than left to the caller to re-read because the caller
    /// that needs it — the upgrade queue, fingerprinting an `.unmatched` outcome on
    /// `knownTitlesCount` — would otherwise be holding the pre-harvest `Work` value and
    /// record a count that is already stale. Recording the old count reopens the Work on
    /// the very next pass, re-running searches that just failed with these exact titles
    /// (ADR-0016 Decision 5).
    ///
    /// `knownTitles` only ever grows (ADR-0009), and `noteTitle` de-duplicates, so this is
    /// idempotent: harvesting the same alternates twice is a no-op with the same count.
    @discardableResult
    func noteTitles(_ titles: [String], on id: WorkID) -> Int? {
        loadIfNeeded()
        guard let resolved = resolve(id), var work = works[resolved] else { return nil }
        let before = work.knownTitles.count
        for title in titles { work.noteTitle(title) }
        guard work.knownTitles.count != before else { return before }
        works[resolved] = work
        markDirty()
        return work.knownTitles.count
    }

    /// Collapses `loser` into `winner`, which happens whenever an external id or a
    /// manual link arrives after both Works already exist.
    ///
    /// The loser is **aliased, never erased**: its id keeps resolving to the winner
    /// forever. Cost is two ids in a dictionary; merges are rare, and the
    /// alternative — a dangling id that resolves to nil — fails silently.
    func merge(_ loser: WorkID, into winner: WorkID) {
        loadIfNeeded()
        defer { markDirty() }
        guard let loserId = resolve(loser), let winnerId = resolve(winner),
              loserId != winnerId,
              let losing = works[loserId], var surviving = works[winnerId] else { return }

        // The surviving Work keeps its own displayTitle; the loser's becomes a known
        // title. Arbitrary, but stable — and stability is the property that matters.
        surviving.noteTitle(losing.displayTitle)
        for title in losing.knownTitles { surviving.noteTitle(title) }
        surviving.externalIds.absorb(losing.externalIds)
        for key in losing.listings where !surviving.listings.contains(key) {
            surviving.listings.append(key)
        }
        // Identity and metadata are decided by different rules (ADR-0009). Identity goes
        // to the incumbent, but the snapshot goes to whichever ranks higher — otherwise
        // the WeebCentral Work the user actually read loses its provisional tags to a
        // MangaDex mint carrying nothing, which is the concrete case ADR-0008's own trace
        // produces.
        if Self.rank(losing.snapshot) > Self.rank(surviving.snapshot) {
            surviving.snapshot = losing.snapshot
        }

        works[winnerId] = surviving
        works[loserId] = nil
        aliases[loserId] = winnerId

        for key in losing.listings { listingIndex[key] = winnerId }
        reindexExternalIds(of: winnerId)
    }

    // MARK: - Private

    /// Returns whether anything changed, so callers on the hot path can skip
    /// re-arming the debounced save.
    @discardableResult
    private func link(_ key: ListingKey, to id: WorkID, title: String) -> Bool {
        guard var work = works[id] else { return false }
        let titleCount = work.knownTitles.count
        var changed = false
        if !work.listings.contains(key) {
            work.listings.append(key)
            changed = true
        }
        work.noteTitle(title)
        changed = changed || work.knownTitles.count != titleCount
        guard changed else { return false }
        works[id] = work
        listingIndex[key] = id
        return true
    }

    /// Returns whether anything changed. See `link`.
    @discardableResult
    private func absorb(_ ids: ExternalIDs, into id: WorkID, title: String) -> Bool {
        guard var work = works[id] else { return false }
        let knownIds = work.externalIds
        let titleCount = work.knownTitles.count
        work.externalIds.absorb(ids)
        work.noteTitle(title)
        guard work.externalIds != knownIds || work.knownTitles.count != titleCount else { return false }
        works[id] = work
        reindexExternalIds(of: id)
        return true
    }

    /// Points every one of a Work's external ids at it — **unless another live Work
    /// already owns one**, in which case the two are the same manga and must merge
    /// rather than fight over the index (ADR-0008). The **incumbent survives**: chosen
    /// for stability, since aliasing keeps the loser resolvable either way, so the only
    /// user-visible consequence is which `displayTitle` persists — and the id that
    /// arrived first is the one already on screen.
    ///
    /// This also repairs a store that already contains the split, because
    /// `loadIfNeeded` reindexes every Work. A `works.json` holding two Works for one
    /// external id is in exactly the broken state the index exists to prevent, so a
    /// repairing launch is better than a faithful one (ADR-0009).
    private func reindexExternalIds(of id: WorkID) {
        guard let work = works[id] else { return }
        for key in Self.indexKeys(for: work.externalIds) {
            if let incumbent = externalIdIndex[key],
               let live = resolve(incumbent), live != id {
                merge(id, into: live)
                // `id` no longer exists. The merge reindexed the winner, which absorbed
                // the remaining keys — continuing would iterate a deleted Work and
                // mutually recurse through `merge`. Termination is guaranteed because
                // every merge removes one Work from `works`.
                return
            }
            externalIdIndex[key] = id
        }
    }

    /// `nil` < provisional < a real provider. The precedence `applyProvisionalSnapshot`
    /// already enforces as a floor (see above), reused so the store has **one** ordering
    /// of metadata authority rather than two that can disagree.
    private static func rank(_ snapshot: MetadataSnapshot?) -> Int {
        guard let snapshot else { return 0 }
        return snapshot.provider == .mangadex ? 1 : 2
    }

    // MARK: - Persistence

    /// Writes immediately if there's anything pending. Call on backgrounding — a
    /// debounced save that never fires because the app was suspended is a lost write.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        dirty = false

        let payload = Persisted(works: Array(works.values),
                                aliases: aliases.map { Persisted.Alias(from: $0.key, to: $0.value) })
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort, matching the rest of the app's stores: a failed write
            // costs the last few mutations, and there is nothing useful to do here.
            dirty = true
        }
    }

    /// Loaded on first use rather than in `init`, so constructing the store (which
    /// happens at launch) never touches the disk.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Persisted.self, from: data) else { return }

        for work in payload.works { works[work.id] = work }
        for alias in payload.aliases { aliases[alias.from] = alias.to }
        for work in payload.works {
            for key in work.listings { listingIndex[key] = work.id }
            reindexExternalIds(of: work.id)
        }
    }

    private func markDirty() {
        dirty = true
        saveTask?.cancel()
        let delay = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private static func indexKeys(for ids: ExternalIDs) -> [String] {
        var keys: [String] = []
        if let mal = ids.mal { keys.append("mal:\(mal)") }
        if let anilist = ids.anilist { keys.append("anilist:\(anilist)") }
        return keys
    }
}

// MARK: - On-disk shape

/// Only Works and aliases are stored: **both indexes are rebuilt on load**, so they
/// cannot drift out of sync with the Works they point at. Aliases are pairs rather
/// than a dictionary because JSON object keys must be strings and a `WorkID` isn't
/// one. File-scope rather than nested in `WorkStore` so `Alias` stays one level deep.
private struct Persisted: Codable {
    struct Alias: Codable {
        let from: WorkID
        let to: WorkID
    }
    var works: [Work]
    var aliases: [Alias]
}
