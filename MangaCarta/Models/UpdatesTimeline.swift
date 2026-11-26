import Foundation

/// The Updates screen's day-then-Work grouping (spec `2026-11-09-updates-screen-design.md`,
/// slice 1).
///
/// Pure on purpose: no store, clock or time zone is read inside, so every "which day is
/// this?" question is answered by the `calendar` and `now` the caller passes. The screen
/// passes `Calendar.current` (the device's current time zone, owner decision 3); tests pass
/// a fixed one.
///
/// A Work's day is the local calendar day of its `newestDiscoveryAt` — when *this device*
/// discovered the chapters — never `Chapter.date`, which is the Source's release date and
/// may be absent or far older. `updates.json` keeps no per-chapter discovery time, so all of
/// a Work's newly discovered chapters sit under that one day.
struct UpdatesTimeline: Equatable {
    /// Which day a section stands for. `unknown` holds Works with discoveries but no
    /// `newestDiscoveryAt` (possible in state written before that field was set).
    enum Day: Hashable {
        case today
        case yesterday
        /// Any earlier (or, after a clock or time-zone change, later) day; the date is the
        /// start of that day in the grouping calendar.
        case date(Date)
        case unknown
    }

    struct WorkGroup: Identifiable, Equatable {
        let summary: WorkUpdateSummary
        /// The Work's newly discovered chapter ordinals, newest first.
        let ordinals: [ChapterOrdinal]
        var id: WorkID { summary.id }
    }

    struct DaySection: Identifiable, Equatable {
        let day: Day
        /// "Today", "Yesterday", a locale-formatted date, or "Date unknown".
        let title: String
        let works: [WorkGroup]
        var id: Day { day }
    }

    /// Newest day first; `unknown` last.
    let sections: [DaySection]

    var isEmpty: Bool { sections.isEmpty }

    /// Every Work shown, in display order. "Mark all seen" clears exactly these, which is
    /// what keeps it scoped to Works still in the Library.
    var workIds: [WorkID] { sections.flatMap { $0.works.map(\.id) } }

    /// The header's "N new chapters".
    var newChapterCount: Int { sections.reduce(0) { $0 + $1.works.reduce(0) { $0 + $1.ordinals.count } } }

    /// - Parameters:
    ///   - summaries: the Library's Work summaries (`LibraryUpdatesPresentation.summaries`),
    ///     which are already one per Work and already limited to saved Works.
    ///   - newlyDiscovered: each Work's `WorkUpdateState.newlyDiscovered`. A Work with an
    ///     empty or missing set is left out; a muted Work is not — muting silences
    ///     notifications, not the in-app inbox.
    init(summaries: [WorkUpdateSummary],
         newlyDiscovered: [WorkID: Set<ChapterOrdinal>],
         calendar: Calendar,
         now: Date,
         locale: Locale = .current) {
        var dated: [Date: [WorkGroup]] = [:]
        var undated: [WorkGroup] = []

        for summary in summaries {
            guard let ordinals = newlyDiscovered[summary.id], !ordinals.isEmpty else { continue }
            let group = WorkGroup(summary: summary, ordinals: ordinals.sorted(by: >))
            if let discovered = summary.newestDiscoveryAt {
                dated[calendar.startOfDay(for: discovered), default: []].append(group)
            } else {
                undated.append(group)
            }
        }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today).map(calendar.startOfDay(for:))
        var sections = dated.keys.sorted(by: >).map { start -> DaySection in
            let day: Day = start == today ? .today : start == yesterday ? .yesterday : .date(start)
            let works = dated[start, default: []].sorted(by: Self.newestThenTitle)
            return DaySection(day: day, title: Self.title(for: day, calendar: calendar, locale: locale),
                              works: works)
        }
        if !undated.isEmpty {
            sections.append(DaySection(day: .unknown,
                                       title: Self.title(for: .unknown, calendar: calendar, locale: locale),
                                       works: undated.sorted(by: Self.titleOrder)))
        }
        self.sections = sections
    }

    private static func newestThenTitle(_ lhs: WorkGroup, _ rhs: WorkGroup) -> Bool {
        let left = lhs.summary.newestDiscoveryAt ?? .distantPast
        let right = rhs.summary.newestDiscoveryAt ?? .distantPast
        if left != right { return left > right }
        return titleOrder(lhs, rhs)
    }

    /// Title, then id, so two Works with the same title still order the same way every pass.
    private static func titleOrder(_ lhs: WorkGroup, _ rhs: WorkGroup) -> Bool {
        switch lhs.summary.displayManga.title.localizedStandardCompare(rhs.summary.displayManga.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id.raw.uuidString < rhs.id.raw.uuidString
        }
    }

    private static func title(for day: Day, calendar: Calendar, locale: Locale) -> String {
        switch day {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .unknown: return "Date unknown"
        case .date(let start):
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            style.locale = locale
            return start.formatted(style)
        }
    }
}

extension UpdatesTimeline {
    /// The screen's convenience: reads each summarized Work's discovery set from the store.
    /// Kept as a thin shell over the pure init so the grouping itself stays store-free.
    @MainActor
    init(summaries: [WorkUpdateSummary],
         updates: UpdateStateStore,
         calendar: Calendar = .current,
         now: Date = .now,
         locale: Locale = .current) {
        var sets: [WorkID: Set<ChapterOrdinal>] = [:]
        for summary in summaries {
            sets[summary.id] = updates.state(for: summary.id)?.newlyDiscovered
        }
        self.init(summaries: summaries, newlyDiscovered: sets, calendar: calendar, now: now, locale: locale)
    }
}
