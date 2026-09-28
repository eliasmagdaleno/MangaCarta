//
//  SourceRegistry.swift
//  MangaCarta
//
//  The single place that knows which manga sources exist and which one is "active" for
//  browsing. ViewModels and Services resolve their source through here instead of
//  referencing a concrete API. Two kinds of source live here: the compiled-in set
//  (`builtInSources()` — only the on-device Local library since ADR-0003 Amendment 6),
//  fixed for the life of the process, and the installed set
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

    /// - Parameter sources: Sources to register, or `nil` for the built-in set (Local only).
    ///   Injectable so tests can supply mock sources.
    init(sources: [MangaSource]? = nil,
         showAdultContent: @escaping () -> Bool = AdultContentSetting.current) {
        let sources = sources ?? Self.builtInSources()
        self.showAdultContent = showAdultContent
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
        let isBrowsableNow: (MangaSource) -> Bool = {
            $0.isBrowsable && (!$0.isNSFW || showAdultContent())
        }
        self.activeSourceID = sources.first(where: {
            $0.id == stored && isBrowsableNow($0)
        })?.id ?? sources.first(where: isBrowsableNow)?.id ?? stored ?? ""
        self.chosenSourceID = stored
    }

    private let showAdultContent: () -> Bool

    /// The app's compiled-in sources. No remote content Source ships in the binary
    /// (ADR-0003 Amendment 6): MangaDex and WeebCentral are installed from a repository the
    /// reader adds, like any other Source.
    private static func builtInSources() -> [MangaSource] {
        [LocalSource(store: .shared)]
    }

    /// Identities of Sources earlier builds shipped. Nothing registers under them now, and
    /// their records wait for the reader to reconnect them (ADR-0003 Amendment 7), so a
    /// lookup must fail as unavailable rather than fall back to whatever is active.
    private static let retiredSourceIDs = Set(InstalledSourceIDMigration.legacyIDs)

    /// Replaces the installed set (Phase 4). The built-ins stay exactly where they were;
    /// `installed` follows them in the order given. If the browse source was one that is
    /// no longer here — uninstalled, disabled, refused at launch — browsing moves to the
    /// first source rather than leaving `activeSourceID` pointing at nothing the picker
    /// can show.
    func setInstalledSources(_ installed: [MangaSource]) {
        sources = builtIn + installed
        if let chosen = chosenSourceID, chosen != activeSourceID, source(id: chosen) != nil {
            activeSourceID = chosen
        } else if (source(id: activeSourceID)?.isBrowsable != true), let first = firstBrowsable {
            activeSourceID = first.id
        }
    }

    /// The currently-active browsing source, or nil when no source is installed.
    var active: MangaSource? {
        source(id: activeSourceID).flatMap { isBrowsableNow($0) ? $0 : nil } ?? firstBrowsable
    }

    /// The registered source that can bridge external catalogue ids. Prefer the active
    /// source, then preserve registration order; nil means cross-catalogue features are
    /// unavailable and should degrade to empty results.
    var externalIdSource: MangaSource? {
        if let active, active.publishesExternalIds { return active }
        return sources.first(where: \.publishesExternalIds)
    }

    /// `externalIdSource` without adult filtering, for resolving titles the reader already
    /// has. Discovery must keep using the filtered one.
    var externalIdResolutionSource: MangaSource? {
        guard let source = externalIdSource else { return nil }
        return (source as? ExtensionSource)?.unfilteredForResolution() ?? source
    }

    /// Browsable, and not hidden whole by the adult switch (ADR-0022 A6).
    private func isBrowsableNow(_ source: MangaSource) -> Bool {
        source.isBrowsable && (!source.isNSFW || showAdultContent())
    }

    /// The fallback browse source. It prefers a non-adult one: no built-in is browsable any
    /// more (ADR-0003 Amendment 6), so registration order alone no longer keeps an adult
    /// Source from becoming the default the way the compiled MangaDex did (ADR-0022). It
    /// falls back to a hidden adult one only while the switch is on (ADR-0022 A6, point 7;
    /// Amendment 7, point 2).
    private var firstBrowsable: MangaSource? {
        sources.first(where: { $0.isBrowsable && !$0.isNSFW }) ?? sources.first(where: isBrowsableNow)
    }

    /// Look up a source by its stable id (e.g. a manga's `sourceId`). Nil if not registered.
    func source(id: String) -> MangaSource? {
        sources.first { $0.id == id }
    }

    /// Whether a title may appear in a discovery surface that did not come through a
    /// Source's own filtered listing: recommendations resolve through `manga(id:)` and
    /// persisted pools. An unknown Source fails closed (ADR-0022 A6).
    func admitsForDiscovery(_ manga: Manga) -> Bool {
        let show = showAdultContent()
        guard let source = source(id: manga.sourceId) else {
            return AdultContentFilter.admits(rating: manga.contentRating,
                                             sourceDeclaresAdultTitles: true,
                                             showAdultContent: show)
        }
        if source.isNSFW && !show { return false }
        return AdultContentFilter.admits(rating: manga.contentRating,
                                         sourceDeclaresAdultTitles: source.declaresAdultTitles,
                                         showAdultContent: show)
    }

    /// The source a given manga came from. Legacy records with an unknown id retain the
    /// active-source fallback; ids known to the extension lifecycle but no longer
    /// registered return nil so callers cannot ask another Source for their listing.
    func source(for manga: Manga) -> MangaSource? {
        if let source = source(id: manga.sourceId) { return source }
        let known = knownSourceIDs.contains(manga.sourceId) || Self.retiredSourceIDs.contains(manga.sourceId)
        return known ? nil : active
    }

    /// Mirrors lifecycle identity knowledge into this registry. The lifecycle owns the
    /// authoritative set; this is only a resolution seam for historical manga records.
    func setKnownSourceIDs(_ ids: Set<String>) {
        knownSourceIDs = ids
    }

    /// The source that refreshes a listing. A nil id predates multi-source and resolves to
    /// the legacy MangaDex id; an id with no registered Source returns nil and the listing
    /// is skipped, never sent to another Source (#219).
    func sourceForRefresh(sourceId: String?) -> MangaSource? {
        let resolvedID = sourceId ?? LegacySourceID.unattributed
        return source(id: resolvedID)
    }

    /// Sources eligible to show in the picker: whole-source adult Sources only when opted in.
    func visibleSources(includeAdult: Bool) -> [MangaSource] {
        sources.filter { $0.isBrowsable && (includeAdult || !$0.isNSFW) }
    }

    var browsableSourceNames: [String] { visibleSources(includeAdult: true).map(\.name) }

    /// Whether any registered source serves adult content, and therefore whether the
    /// "show adult sources" control has anything to gate. False for the built-in set, which
    /// is Local only — which is what hides that control;
    /// true the moment a reader installs a Source that declares adult titles, including a
    /// `mixed` Source (ADR-0022 A6), which is what shows the title filter again.
    var hasAdultSource: Bool {
        sources.contains { $0.isNSFW || $0.declaresAdultTitles }
    }

    /// Enforce adult gating: if adult sources are now hidden but the active browse source is
    /// adult, fall back to the first non-adult source. Call when the "show adult" flag changes.
    /// Checks the stored choice, not `active`: by the time this runs the switch is already off,
    /// so `active` has skipped the hidden Source while `activeSourceID` still names it.
    func enforceAdultGating(includeAdult: Bool) {
        guard !includeAdult, source(id: activeSourceID)?.isNSFW == true,
              let fallback = visibleSources(includeAdult: false).first else { return }
        activeSourceID = fallback.id
    }
}
