//
//  SourceLifecycleRegistry.swift
//  MangaCarta
//
//  The Host API design's "Identity lifecycle" (§11): disabling or uninstalling an
//  installed Source unregisters it, but must preserve Listings, pins, and bounded
//  Source storage keyed by its `QualifiedSourceID`. Reinstalling the same qualified id
//  — even with a changed `name`, `engine`, `configuration`, or `capabilities` — must
//  reconnect those stored references. An unrelated repository that happens to reuse the
//  same `localId` string must never be treated as the same Source.
//
//  This type owns exactly that lifecycle state machine: registered / disabled /
//  uninstalled, keyed exclusively by `QualifiedSourceID`. It does not own Listings or
//  pins itself — those already live in `SourcePreferenceStore` (per-Work pin) and in
//  whatever holds a Work's `[ListingKey]` (`Work.listings`) — and it must never grow a
//  second, parallel notion of either. "Reconnects" here means: this registry's own
//  state for a `QualifiedSourceID` goes back to `.registered`, and everything else in
//  the app that already keys off that same id (a pin, a Listing, bounded storage) needs
//  no migration to see it as valid again, because none of those other stores are ever
//  touched by `disable`, `uninstall`, or `reinstall` below.
//
//  The installer (Phase 4) is what actually mints `QualifiedSourceID` and drives these
//  transitions from repository events; this file is the lifecycle contract those events
//  must satisfy; see also `SourceDeclarationValidator`, which this reuses for the
//  identity-change rule rather than re-implementing it.
//

import Foundation

/// A minimal seam for bounded per-Source storage (Host API design §4.3, "Storage").
/// S5 owns the real `host.storage` implementation, which has not merged as of this
/// slice. This protocol exists only so this slice's tests can assert the *contract* —
/// storage keyed by a `QualifiedSourceID` is untouched by disable/uninstall/reinstall —
/// against a fake, without building or depending on S5's storage. There is no
/// production conformer here.
protocol QualifiedSourceStorage: AnyObject {
    /// Whether storage exists for this id. Nothing in `SourceLifecycleRegistry` holds a
    /// reference to a `QualifiedSourceStorage`, let alone calls a method that would make
    /// this `false` — that absence is itself the preservation guarantee.
    func hasStorage(for id: QualifiedSourceID) -> Bool
}

/// Why a lifecycle transition was refused.
enum SourceLifecycleError: Error, Equatable {
    /// `register` was called for a `QualifiedSourceID` that has already been seen.
    /// Use `reinstall` once an id has ever been registered.
    case alreadyRegistered
    /// `disable`, `uninstall`, or `state(for:)`-consuming calls referenced an id this
    /// registry has never seen.
    case unknownSource
    /// `reinstall` revalidated the incoming declaration against the one this registry
    /// remembers for the same qualified id, per `SourceDeclarationValidator.validateUpdate`,
    /// and it failed — most commonly because `localId` or `qualifiedId` itself changed,
    /// which would mean this isn't actually the same Source.
    case declarationInvalid(SourceDeclarationError)
}

/// Tracks the registration lifecycle of an installer-managed Source, keyed exclusively
/// by `QualifiedSourceID`. See the file header for what this does and does not own.
@MainActor
final class SourceLifecycleRegistry {

    /// A Source's current lifecycle state. Disablement and uninstall are modeled as
    /// distinct states — both currently transition and preserve identically, but the
    /// design's §11 treats them as separate lifecycle events, and collapsing them into
    /// one would make a future distinction (e.g. auto re-enable vs. requiring an
    /// explicit reinstall) a breaking change instead of an additive one.
    ///
    /// `String`-backed and `Codable` so the installer's installed-Source record can
    /// persist this state as-is, rather than keeping a second enum that mirrors it.
    enum State: String, Equatable, Codable {
        case registered
        case disabled
        case uninstalled
    }

    private struct Entry {
        var declaration: SourceDeclaration
        var state: State
    }

    private var entries: [QualifiedSourceID: Entry] = [:]

    init() {}

    /// Registers a Source for the first time under `declaration.qualifiedId`.
    ///
    /// - Throws: `SourceLifecycleError.alreadyRegistered` if this id has been seen
    ///   before (registered, disabled, or uninstalled) — that case is `reinstall`.
    func register(_ declaration: SourceDeclaration) throws {
        guard entries[declaration.qualifiedId] == nil else {
            throw SourceLifecycleError.alreadyRegistered
        }
        entries[declaration.qualifiedId] = Entry(declaration: declaration, state: .registered)
    }

    /// Unregisters the Source for new invocations. Per §11, "calls fail as unavailable
    /// and existing fallback behavior may choose another registered Source" — that
    /// fallback lives wherever a caller resolves a Source today (`SourceRegistry`,
    /// `FulfillmentRouter`); this method only flips the state this registry tracks.
    /// Listings, pins, and bounded storage keyed by this id are untouched, because
    /// nothing here reaches into any store that holds them.
    func disable(_ id: QualifiedSourceID) throws {
        try transition(id, to: .disabled)
    }

    /// Unregisters the Source, same preservation guarantee as `disable` — see the type
    /// header on why these are modeled as distinct states despite matching behavior.
    func uninstall(_ id: QualifiedSourceID) throws {
        try transition(id, to: .uninstalled)
    }

    private func transition(_ id: QualifiedSourceID, to state: State) throws {
        guard var entry = entries[id] else { throw SourceLifecycleError.unknownSource }
        entry.state = state
        entries[id] = entry
    }

    /// Reinstalls (or performs the very first install of) a Source under
    /// `declaration.qualifiedId`.
    ///
    /// When this id has been seen before, the incoming declaration is revalidated
    /// against the one this registry remembers — via `SourceDeclarationValidator
    /// .validateUpdate`, never by comparing `localId` strings alone — before the state
    /// moves back to `.registered`. `name`, `engine`, `configuration`, and
    /// `capabilities` may all differ from what was remembered; `qualifiedId` and
    /// `localId` may not, and `validateUpdate` is exactly the rule that already
    /// enforces that. `declaration` has already passed `SourceDeclarationValidator
    /// .validate` — not by convention but by type: since ADR-0003 Amendment 4 (#161) a
    /// `SourceDeclaration` can only be obtained as that validator's output — and this
    /// method never trusts a cached declaration in place of revalidating the one being
    /// installed now.
    ///
    /// A `QualifiedSourceID` this registry has never seen reinstalls exactly like a
    /// fresh `register`: there is nothing to revalidate against, so it simply becomes
    /// `.registered`.
    func reinstall(_ declaration: SourceDeclaration) throws {
        if let existing = entries[declaration.qualifiedId] {
            if let error = SourceDeclarationValidator.validateUpdate(from: existing.declaration,
                                                                      to: declaration) {
                throw SourceLifecycleError.declarationInvalid(error)
            }
        }
        entries[declaration.qualifiedId] = Entry(declaration: declaration, state: .registered)
    }

    /// The declaration this registry currently remembers for `id`, regardless of
    /// lifecycle state — `nil` only if the id has never been seen.
    func declaration(for id: QualifiedSourceID) -> SourceDeclaration? {
        entries[id]?.declaration
    }

    /// `nil` if this id has never been seen; otherwise its current lifecycle state.
    func state(for id: QualifiedSourceID) -> State? {
        entries[id]?.state
    }

    /// Whether calls for `id` should be routed to the Source, versus failing as
    /// unavailable per §11.
    func isActive(_ id: QualifiedSourceID) -> Bool {
        state(for: id) == .registered
    }
}
