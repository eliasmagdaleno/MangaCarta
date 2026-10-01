//
//  SourcePreferenceStore.swift
//  MangaCarta
//
//  Which source a reader wants, at two scopes that compose.
//
//  **Primary source** — "when several sources have a manga, prefer this one." It
//  settles ties in `FulfillmentRouter`; it never overrides completeness, because
//  preferring a source's scans is not a claim it has chapters it lacks.
//
//  **Per-Work choice** — "for *this* manga, read it here." Deliberately switching
//  source on a title is a statement about that title, and it outranks both the
//  ranking and the primary source. Without it the app would silently switch the
//  reader back the next time counts moved, which reads as a bug rather than a
//  preference.
//
//  UserDefaults rather than a file: this is small, flat, and read on the detail
//  page's first paint, so it wants to already be in memory. `EntityResolutionStore`
//  makes the same call for the same reason.
//
//  Per-Work choices follow merges by `ReadingModeStore`'s rule (#310): a key belongs to
//  the Work it resolves to, the survivor's own entry wins, an unresolvable key is
//  ignored. Reads are pure, because the detail page calls them from `body`; writes
//  re-key the stored map first.
//

import Foundation

@MainActor
final class SourcePreferenceStore: ObservableObject {

    private let defaults: UserDefaults
    private let works: WorkStore
    private static let primaryKey = "source.primaryID"
    private static let choicesKey = "source.workChoices"

    /// Work id → the Listing the reader pinned for it. Keys may be merged-away ids until
    /// the next write re-keys them.
    @Published private var choices: [String: ListingKey] = [:]

    /// The reader's preferred source, or `nil` when they have not chosen one.
    ///
    /// `nil` is the honest answer rather than a guessed default: the router already
    /// falls back to MangaDex, and naming that default here too would put one
    /// decision in two places to drift apart.
    @Published var primarySourceId: String? {
        didSet { defaults.set(primarySourceId, forKey: Self.primaryKey) }
    }

    init(defaults: UserDefaults = .standard, works: WorkStore) {
        self.defaults = defaults
        self.works = works
        primarySourceId = defaults.string(forKey: Self.primaryKey)
        if let data = defaults.data(forKey: Self.choicesKey),
           let decoded = try? JSONDecoder().decode([String: ListingKey].self, from: data) {
            choices = decoded
        }
    }

    // MARK: - Per-Work choice

    /// The Listing this Work is pinned to, or `nil` when the ranking still decides.
    func choice(for workID: WorkID) -> ListingKey? {
        guard let target = resolvedKey(workID.raw.uuidString) else { return nil }
        if let own = choices[target] { return own }
        return choices.keys.sorted()
            .first { $0 != target && resolvedKey($0) == target }
            .flatMap { choices[$0] }
    }

    func choose(_ listing: ListingKey, for workID: WorkID) {
        var next = rekeyed()
        guard let target = resolvedKey(workID.raw.uuidString) else { return }
        next[target] = listing
        commit(next)
    }

    /// Returns the Work to the ranking. Note this **clears** rather than pinning the
    /// ranking's current answer: a reader switching back is saying "stop overriding",
    /// and those two readings diverge the moment a better Listing appears.
    func clearChoice(for workID: WorkID) {
        var next = rekeyed()
        guard let target = resolvedKey(workID.raw.uuidString) else { return }
        next[target] = nil
        commit(next)
    }

    // MARK: - Merge resolution

    /// The live Work id a stored key belongs to, or `nil` when it resolves to no Work.
    private func resolvedKey(_ key: String) -> String? {
        guard let uuid = UUID(uuidString: key) else { return nil }
        return works.work(WorkID(raw: uuid))?.id.raw.uuidString
    }

    /// `choices` with every key moved to the Work it resolves to. The survivor's own
    /// entry wins; among several merged-away keys the lexicographically smallest wins,
    /// matching the read path; unresolvable keys are dropped.
    private func rekeyed() -> [String: ListingKey] {
        var result: [String: ListingKey] = [:]
        for key in choices.keys.sorted() {
            guard let target = resolvedKey(key), let value = choices[key] else { continue }
            if key == target {
                result[target] = value
            } else if result[target] == nil, choices[target] == nil {
                result[target] = value
            }
        }
        return result
    }

    private func commit(_ next: [String: ListingKey]) {
        choices = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.choicesKey)
    }
}
