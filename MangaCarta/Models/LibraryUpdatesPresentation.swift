import Foundation

enum UpdateFreshness: Codable, Equatable {
    case notChecked
    case refreshing
    case fresh
    case stale
    case partialFailure
}

struct WorkUpdateSummary: Codable, Identifiable, Equatable {
    let id: WorkID
    let displayManga: Manga
    let unreadChapterCount: Int
    let newlyDiscoveredCount: Int
    let newestDiscoveryAt: Date?
    let lastSuccessfulCheck: Date?
    let freshness: UpdateFreshness
    let recoverySummaries: [String]
    let isMuted: Bool
}

extension WorkUpdateSummary {
    /// The row as one spoken sentence (issue #90).
    ///
    /// The "NEW" badge is a capsule of tracked uppercase, and the row's label used to omit
    /// it entirely — so the one thing the badge exists to say was the one thing VoiceOver
    /// did not. Muted is the same kind of state: visible in the row, previously silent.
    var accessibilityLabel: String {
        var parts = [displayManga.title, unreadChapterText]
        if newlyDiscoveredCount > 0 {
            parts.append(newlyDiscoveredCount == 1
                         ? "1 new chapter"
                         : "\(newlyDiscoveredCount) new chapters")
        }
        if isMuted { parts.append("Muted") }
        return parts.joined(separator: ", ")
    }

    /// The unread count as the row draws it, shared so the sentence and the subtitle
    /// cannot drift apart.
    var unreadChapterText: String {
        unreadChapterCount == 1 ? "1 unread chapter" : "\(unreadChapterCount) unread chapters"
    }
}

enum LibraryUpdatesPresentation {
    @MainActor
    static func summaries(works: WorkStore,
                          library: LibraryStore,
                          history: HistoryStore,
                          updates: UpdateStateStore,
                          registry: SourceRegistry? = nil,
                          isRefreshing: Bool? = nil,
                          now: Date = .now) -> [WorkUpdateSummary] {
        let sourceRegistry = registry ?? .shared
        let saved = Dictionary(uniqueKeysWithValues: library.items.map { item in
            (ListingKey(sourceId: item.sourceId ?? LegacySourceID.unattributed, mangaId: item.id), item)
        })

        return works.allWorkIds().compactMap { workId -> WorkUpdateSummary? in
            guard let work = works.work(workId),
                  let listing = work.listings.first(where: { saved[$0] != nil }),
                  let item = saved[listing] else { return nil }
            let state = updates.state(for: workId) ?? WorkUpdateState()
            let readOrdinals = Set(work.listings.flatMap { linkedListing in
                history.readChapterNumbers(forManga: linkedListing.mangaId).compactMap(ChapterOrdinal.parse)
            })
            let recovery: [String] = state.listings.compactMap { element -> String? in
                let (listing, check) = element
                guard check.consecutiveFailures > 0 else { return nil }
                return sourceRegistry.source(id: listing.sourceId)?.name ?? listing.sourceId
            }.sorted()
            let refreshing = isRefreshing ?? library.isRefreshing
            return WorkUpdateSummary(
                id: work.id,
                displayManga: Manga(id: listing.mangaId, sourceId: listing.sourceId,
                                    title: item.title, description: "", status: "unknown",
                                    year: nil, coverURL: item.coverURL,
                                    malId: work.externalIds.mal),
                unreadChapterCount: state.frontier.known.subtracting(readOrdinals).count,
                newlyDiscoveredCount: state.newlyDiscovered.count,
                newestDiscoveryAt: state.newestDiscoveryAt,
                lastSuccessfulCheck: state.lastSuccessfulCheck,
                freshness: freshness(for: state, isRefreshing: refreshing, now: now),
                recoverySummaries: recovery,
                isMuted: state.isMuted
            )
        }.sorted { lhs, rhs in
            if lhs.newestDiscoveryAt != rhs.newestDiscoveryAt {
                return (lhs.newestDiscoveryAt ?? .distantPast) > (rhs.newestDiscoveryAt ?? .distantPast)
            }
            return lhs.displayManga.title.localizedStandardCompare(rhs.displayManga.title) == .orderedAscending
        }
    }

    static func freshness(for state: WorkUpdateState,
                          isRefreshing: Bool,
                          now: Date = .now) -> UpdateFreshness {
        guard state.hasBaseline else { return .notChecked }
        if isRefreshing { return .refreshing }
        if state.listings.values.contains(where: { $0.consecutiveFailures > 0 }) {
            return .partialFailure
        }
        guard let checked = state.lastSuccessfulCheck else { return .stale }
        return now.timeIntervalSince(checked) <= UpdateTuning.freshWindow ? .fresh : .stale
    }

    static func homeSummaries(_ summaries: [WorkUpdateSummary]) -> [WorkUpdateSummary] {
        Array(summaries.prefix(UpdateTuning.homeSummaryLimit))
    }
}
