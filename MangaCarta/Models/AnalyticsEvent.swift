import Foundation

struct CatalogueIDs: Codable, Equatable, Hashable {
    let mal: Int?
    let anilist: Int?

    var isEmpty: Bool { mal == nil && anilist == nil }

    private enum CodingKeys: String, CodingKey { case mal, anilist }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(mal, forKey: .mal)
        try container.encodeIfPresent(anilist, forKey: .anilist)
    }
}

enum ForYouReasonKind: String, Codable, CaseIterable {
    case tag, anilist, mal, explore, other
}

enum ReaderModeKind: String, Codable, CaseIterable {
    case ltr, rtl, vertical

    init(_ mode: ReadingMode) {
        switch mode {
        case .leftToRight: self = .ltr
        case .rightToLeft: self = .rtl
        case .vertical: self = .vertical
        }
    }
}

enum ImportFileBucket: String, Codable, CaseIterable {
    case one = "1"
    case twoToNine = "2-9"
    case tenOrMore = "10+"

    init?(count: Int) {
        switch count {
        case 1: self = .one
        case 2...9: self = .twoToNine
        case 10...: self = .tenOrMore
        default: return nil
        }
    }
}

enum AnalyticsSettingKey: String, Codable, CaseIterable {
    case notifications, malSync = "mal_sync", showAdult = "show_adult"
    case readingModeDefault = "reading_mode_default"
}

enum AnalyticsSettingValue: Equatable, Codable {
    case on(Bool)
    case readingMode(ReaderModeKind)

    private enum CodingKeys: String, CodingKey { case on, value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .on(let value): try container.encode(value, forKey: .on)
        case .readingMode(let mode): try container.encode(mode, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let on = try container.decodeIfPresent(Bool.self, forKey: .on) {
            self = .on(on)
        } else {
            self = .readingMode(try container.decode(ReaderModeKind.self, forKey: .value))
        }
    }
}

enum AnalyticsEvent: Equatable, Codable {
    case workSaved(CatalogueIDs)
    case workUnsaved(CatalogueIDs)
    case chapterCompleted(CatalogueIDs, progress: Int)
    case recNotInterested(CatalogueIDs)
    case recMoreLikeThis(CatalogueIDs)
    case forYouOpened(CatalogueIDs, rank: Int, reason: ForYouReasonKind)
    case forYouShown(count: Int)
    case mltOpened(from: CatalogueIDs, to: CatalogueIDs)
    case appActive
    case readerOpened(ReaderModeKind)
    case searchUsed
    case localImportFinished(ImportFileBucket)
    case sourceInstalled(AdultClassification)
    case settingChanged(AnalyticsSettingKey, AnalyticsSettingValue)
    case analyticsEnabled

    var name: String {
        switch self {
        case .workSaved: return "work_saved"
        case .workUnsaved: return "work_unsaved"
        case .chapterCompleted: return "chapter_completed"
        case .recNotInterested: return "rec_not_interested"
        case .recMoreLikeThis: return "rec_more_like_this"
        case .forYouOpened: return "for_you_opened"
        case .forYouShown: return "for_you_shown"
        case .mltOpened: return "mlt_opened"
        case .appActive: return "app_active"
        case .readerOpened: return "reader_opened"
        case .searchUsed: return "search_used"
        case .localImportFinished: return "local_import_finished"
        case .sourceInstalled: return "source_installed"
        case .settingChanged: return "setting_changed"
        case .analyticsEnabled: return "analytics_enabled"
        }
    }

    var plainDescription: String {
        func ids(_ value: CatalogueIDs) -> String {
            if let mal = value.mal { return "MAL \(mal)" }
            if let anilist = value.anilist { return "AniList \(anilist)" }
            return "catalogue title"
        }
        switch self {
        case .workSaved(let value): return "Saved a title (\(ids(value)))"
        case .workUnsaved(let value): return "Removed a title (\(ids(value)))"
        case .chapterCompleted(let value, let progress):
            return "Finished chapter \(progress) (\(ids(value)))"
        case .recNotInterested(let value): return "Marked a recommendation not interested (\(ids(value)))"
        case .recMoreLikeThis(let value): return "Asked for more like this (\(ids(value)))"
        case .forYouOpened(let value, let rank, _): return "Opened a recommendation at rank \(rank) (\(ids(value)))"
        case .forYouShown(let count): return "Shown \(count) recommendations"
        case .mltOpened(let from, let to): return "Opened a More Like This title (\(ids(from)) → \(ids(to)))"
        case .appActive: return "Opened the app"
        case .readerOpened(let mode):
            let label = mode == .ltr ? "left to right" : mode == .rtl ? "right to left" : "vertical"
            return "Opened the reader (\(label))"
        case .searchUsed: return "Used search"
        case .localImportFinished(let files): return "Finished importing \(files.rawValue) files"
        case .sourceInstalled(let adult): return "Installed a source (\(adult.rawValue))"
        case .settingChanged(let key, let value):
            switch value {
            case .on(let on): return "Changed \(key.rawValue) (\(on ? "on" : "off"))"
            case .readingMode(let mode): return "Changed \(key.rawValue) (\(mode.rawValue))"
            }
        case .analyticsEnabled: return "Enabled analytics"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, ids, progress, rank, reason, count, from, to, mode, files, adult, key, on, value
    }

    // swiftlint:disable:next cyclomatic_complexity
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        switch self {
        case .workSaved(let ids), .workUnsaved(let ids), .recNotInterested(let ids), .recMoreLikeThis(let ids):
            try c.encode(ids, forKey: .ids)
        case .chapterCompleted(let ids, let progress):
            try c.encode(ids, forKey: .ids); try c.encode(progress, forKey: .progress)
        case .forYouOpened(let ids, let rank, let reason):
            try c.encode(ids, forKey: .ids); try c.encode(rank, forKey: .rank); try c.encode(reason, forKey: .reason)
        case .forYouShown(let count): try c.encode(count, forKey: .count)
        case .mltOpened(let from, let to): try c.encode(from, forKey: .from); try c.encode(to, forKey: .to)
        case .readerOpened(let mode): try c.encode(mode, forKey: .mode)
        case .localImportFinished(let files): try c.encode(files, forKey: .files)
        case .sourceInstalled(let adult): try c.encode(adult, forKey: .adult)
        case .settingChanged(let key, let value):
            try c.encode(key, forKey: .key)
            switch value {
            case .on(let on): try c.encode(on, forKey: .on)
            case .readingMode(let mode): try c.encode(mode, forKey: .value)
            }
        case .appActive, .searchUsed, .analyticsEnabled: break
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        func ids(_ key: CodingKeys = .ids) throws -> CatalogueIDs { try c.decode(CatalogueIDs.self, forKey: key) }
        switch name {
        case "work_saved": self = .workSaved(try ids())
        case "work_unsaved": self = .workUnsaved(try ids())
        case "chapter_completed": self = .chapterCompleted(try ids(), progress: try c.decode(Int.self, forKey: .progress))
        case "rec_not_interested": self = .recNotInterested(try ids())
        case "rec_more_like_this": self = .recMoreLikeThis(try ids())
        case "for_you_opened":
            self = .forYouOpened(try ids(), rank: try c.decode(Int.self, forKey: .rank),
                                 reason: try c.decode(ForYouReasonKind.self, forKey: .reason))
        case "for_you_shown": self = .forYouShown(count: try c.decode(Int.self, forKey: .count))
        case "mlt_opened": self = .mltOpened(from: try ids(.from), to: try ids(.to))
        case "app_active": self = .appActive
        case "reader_opened": self = .readerOpened(try c.decode(ReaderModeKind.self, forKey: .mode))
        case "search_used": self = .searchUsed
        case "local_import_finished": self = .localImportFinished(try c.decode(ImportFileBucket.self, forKey: .files))
        case "source_installed": self = .sourceInstalled(try c.decode(AdultClassification.self, forKey: .adult))
        case "setting_changed":
            let key = try c.decode(AnalyticsSettingKey.self, forKey: .key)
            if let on = try c.decodeIfPresent(Bool.self, forKey: .on) {
                self = .settingChanged(key, .on(on))
            } else {
                self = .settingChanged(key, .readingMode(
                    try c.decode(ReaderModeKind.self, forKey: .value)
                ))
            }
        case "analytics_enabled": self = .analyticsEnabled
        default: throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Unknown analytics event")
        }
    }
}

struct AnalyticsEnvelope: Codable, Equatable {
    static let schemaVersion = 1
    let v: Int
    let install: UUID
    let day: String
    let app: String
    let event: AnalyticsEvent

    init(install: UUID, date: Date, app: String, event: AnalyticsEvent, v: Int = schemaVersion) {
        self.v = v; self.install = install; self.day = Self.day(for: date); self.app = app; self.event = event
    }

    init(v: Int, install: UUID, day: String, app: String, event: AnalyticsEvent) {
        self.v = v; self.install = install; self.day = day; self.app = app; self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case v, install, day, app, name, ids, progress, rank, reason, count
        case from, to, mode, files, adult, key, on, value
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v); try c.encode(install.uuidString, forKey: .install)
        try c.encode(day, forKey: .day); try c.encode(app, forKey: .app)
        try event.encode(to: encoder)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard let install = UUID(uuidString: try c.decode(String.self, forKey: .install)) else {
            throw DecodingError.dataCorruptedError(forKey: .install, in: c, debugDescription: "Invalid UUID")
        }
        self.init(v: v, install: install, day: try c.decode(String.self, forKey: .day),
                  app: try c.decode(String.self, forKey: .app), event: try AnalyticsEvent(from: decoder))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(for date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
