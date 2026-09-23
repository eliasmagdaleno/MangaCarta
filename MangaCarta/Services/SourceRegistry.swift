//
//  SourceRegistry.swift
//  MangaCarta
//
//  The single place that knows which manga sources exist and which one is "active" for
//  browsing. ViewModels and Services resolve their source through here instead of
//  referencing a concrete API. Two kinds of source live here: the compiled-in set
//  (`builtInSources()`), fixed for the life of the process, and the installed set
//  (Phase 4), which `ExtensionSourceRegistrar` replaces whenever the lifecycle registry
//  or the repository store changes. Installed sources are *added* after the built-ins,
//  never substituted for them; registration order is what the fulfillment ranking's last
//  tiebreak reads (ADR-0004).
//

import Foundation
import Combine

@MainActor
final class SourceRegistry: ObservableObject {
    /// App-wide shared instance. Tests construct their own with injected sources instead.
    static let shared = SourceRegistry()

    /// Every source the app can browse or read from: the built-ins, then the installed
    /// ones. Replaced as a whole so one `objectWillChange` covers a lifecycle event.
    @Published private(set) var sources: [MangaSource]

    /// The set this registry was constructed with. Installed sources are appended to it
    /// and never displace it.
    private let builtIn: [MangaSource]

    /// Source ids known to the extension lifecycle, including disabled and uninstalled
    /// entries. This lets legacy records retain the active-source fallback while an old
    /// extension listing is treated as unavailable instead of being misrouted.
    private var knownSourceIDs: Set<String> = []

    /// The source used for browsing feeds (Home rails, search). Persisted across launches.
    @Published var activeSourceID: String {
        didSet {
            UserDefaults.standard.set(activeSourceID, forKey: Self.activeKey)
            chosenSourceID = activeSourceID
        }
    }

    /// The reader's browse choice as persisted, kept while it cannot be honoured. `init` runs
    /// before any installed Source registers, so a stored installed id is not there to restore
    /// yet; `setInstalledSources` restores it when it arrives instead of keeping the fallback.
    private var chosenSourceID: String?

    private static let activeKey = "source.activeID"

    /// - Parameter sources: Sources to register, or `nil` for the built-in MangaDex source.
    ///   Injectable so tests can supply mock sources.
    init(sources: [MangaSource]? = nil) {
        let sources = sources ?? Self.builtInSources()
        precondition(!sources.isEmpty, "SourceRegistry requires at least one source")
        self.builtIn = sources
        self.sources = sources
        // Restore the persisted active source if it still exists; otherwise fall back to the first.
        let stored: String?
#if DEBUG
        // A UI test that needs a MangaDex-only browse path must not inherit this device's
        // previously selected source, or it passes on fresh CI and fails after a WeebCentral run.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-uitest-source"),
           arguments.indices.contains(index + 1) {
            stored = arguments[index + 1]
        } else {
            stored = UserDefaults.standard.string(forKey: Self.activeKey)
        }
#else
        stored = UserDefaults.standard.string(forKey: Self.activeKey)
#endif
        self.activeSourceID = sources.contains(where: { $0.id == stored }) ? stored! : sources[0].id
        self.chosenSourceID = stored
    }

    /// The app's compiled-in source. WeebCentral is restored through the bundled package.
    private static func builtInSources() -> [MangaSource] {
        [MangaDexSource()]
    }

    /// Replaces the installed set (Phase 4). The built-ins stay exactly where they were;
    /// `installed` follows them in the order given. If the browse source was one that is
    /// no longer here — uninstalled, disabled, refused at launch — browsing moves to the
    /// first source rather than leaving `activeSourceID` pointing at nothing the picker
    /// can show. The first source is a built-in, which ADR-0022 keeps non-adult.
    func setInstalledSources(_ installed: [MangaSource]) {
        sources = builtIn + installed
        if let chosen = chosenSourceID, chosen != activeSourceID, source(id: chosen) != nil {
            activeSourceID = chosen
        } else if source(id: activeSourceID) == nil {
            activeSourceID = sources[0].id
        }
    }

    /// The currently-active browsing source (never nil — falls back to the first source).
    var active: MangaSource {
        source(id: activeSourceID) ?? sources[0]
    }

    /// Look up a source by its stable id (e.g. a manga's `sourceId`). Nil if not registered.
    func source(id: String) -> MangaSource? {
        sources.first { $0.id == id }
    }

    /// The source a given manga came from. Legacy records with an unknown id retain the
    /// active-source fallback; ids known to the extension lifecycle but no longer
    /// registered return nil so callers cannot ask another Source for their listing.
    func source(for manga: Manga) -> MangaSource? {
        if let source = source(id: manga.sourceId) { return source }
        return knownSourceIDs.contains(manga.sourceId) ? nil : active
    }

    /// Mirrors lifecycle identity knowledge into this registry. The lifecycle owns the
    /// authoritative set; this is only a resolution seam for historical manga records.
    func setKnownSourceIDs(_ ids: Set<String>) {
        knownSourceIDs = ids
    }

    /// Update checks use MangaDex for legacy or unregistered source ids, falling back
    /// to the active source only when MangaDex itself is unavailable in this registry.
    func sourceForRefresh(sourceId: String?) -> MangaSource {
        let fallback = source(id: MangaDexSource.sourceID) ?? active
        return sourceId.flatMap { source(id: $0) } ?? fallback
    }

    /// Sources eligible to show in the picker: adult sources only when opted in.
    func visibleSources(includeAdult: Bool) -> [MangaSource] {
        sources.filter { includeAdult || !$0.isNSFW }
    }

    /// Whether any registered source serves adult content, and therefore whether the
    /// "show adult sources" control has anything to gate. False for the built-in set by
    /// ADR-0022 — the adult source is never merged — which is what hides that control;
    /// true the moment a reader installs a `mixed` or `adultOnly` Source (ADR-0022
    /// Amendment 1), which is what shows it again.
    var hasAdultSource: Bool {
        sources.contains(where: \.isNSFW)
    }

    /// Enforce adult gating: if adult sources are now hidden but the active browse source is
    /// adult, fall back to the first non-adult source. Call when the "show adult" flag changes.
    func enforceAdultGating(includeAdult: Bool) {
        guard !includeAdult, active.isNSFW,
              let fallback = visibleSources(includeAdult: false).first else { return }
        activeSourceID = fallback.id
    }
}
