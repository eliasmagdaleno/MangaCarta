import Combine
import Foundation

enum RecommendationFeedbackKind {
    case notInterested
    case moreLikeThis
}

@MainActor
final class AnalyticsRecorder: ObservableObject {
    nonisolated static func bundleAppVersion() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(short) (\(build))"
    }

    @Published private(set) var events: [AnalyticsEnvelope]
    @Published private(set) var installID: UUID?
    var vocabulary: TagVocabulary?

    private let consent: AnalyticsConsentStore
    private let buffer: AnalyticsEventBuffer
    private let works: WorkStore
    private let source: (String) -> MangaSource?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let appVersion: String
    private var ledger: [WorkID: CatalogueIDs]

    private static let forYouDayKey = "analytics.lastForYouShownDay"
    private static let activeDayKey = "analytics.lastAppActiveDay"

    init(consent: AnalyticsConsentStore, buffer: AnalyticsEventBuffer, works: WorkStore,
         source: @escaping (String) -> MangaSource?, defaults: UserDefaults,
         now: @escaping () -> Date = Date.init,
         appVersion: String = AnalyticsRecorder.bundleAppVersion()) {
        self.consent = consent
        self.buffer = buffer
        self.works = works
        self.source = source
        self.defaults = defaults
        self.now = now
        self.appVersion = appVersion
        events = buffer.events
        installID = buffer.installID
        ledger = Self.loadLedger(from: buffer.directoryURL)
        consent.configureConsentChanged { [weak self] old, new in
            self?.consentChanged(from: old, to: new)
        }
    }

    func workSaved(manga: Manga, workID: WorkID) {
        guard consent.isCollecting, let work = works.work(workID),
              let source = source(manga.sourceId),
              AnalyticsEligibility.admits(manga: manga, source: source, work: work, vocabulary: vocabulary),
              let ids = AnalyticsEligibility.catalogueIDs(work: work, manga: manga),
              let canonical = canonical(workID), ledgerEntry(for: canonical) == nil else { return }
        guard record(.workSaved(ids)) else { return }
        ledger[canonical] = ids
        saveLedger()
    }

    func workUnsaved(workID: WorkID) {
        guard consent.isCollecting, let canonical = canonical(workID),
              let entry = ledgerEntry(for: canonical),
              let work = works.work(canonical), workIsStillEligibleWithoutManga(work) else {
            if let canonical = canonical(workID), let entry = ledgerEntry(for: canonical),
               let work = works.work(canonical), !workIsStillEligibleWithoutManga(work) {
                ledger.removeValue(forKey: entry.key); saveLedger()
            }
            return
        }
        guard record(.workUnsaved(entry.ids)) else { return }
        ledger.removeValue(forKey: entry.key)
        saveLedger()
    }

    func chapterCompleted(_ completion: ChapterCompletion) {
        guard consent.isCollecting, let work = works.work(completion.workID),
              let source = source(completion.manga.sourceId),
              AnalyticsEligibility.admits(manga: completion.manga, source: source, work: work, vocabulary: vocabulary),
              let ids = AnalyticsEligibility.catalogueIDs(work: work, manga: completion.manga) else { return }
        record(.chapterCompleted(ids, progress: completion.progress))
    }

    func recommendationFeedback(_ kind: RecommendationFeedbackKind, manga: Manga) {
        // RecommendationEngine mints the Work before delivering feedback.
        guard consent.isCollecting, let workID = works.workId(for: ListingKey(manga)),
              let work = works.work(workID), let source = source(manga.sourceId),
              AnalyticsEligibility.admits(manga: manga, source: source, work: work, vocabulary: vocabulary),
              let ids = AnalyticsEligibility.catalogueIDs(work: work, manga: manga) else { return }
        record(kind == .notInterested ? .recNotInterested(ids) : .recMoreLikeThis(ids))
    }

    func forYouOpened(manga: Manga, rank: Int, reason: ForYouReasonKind) {
        let work = works.workId(for: ListingKey(manga)).flatMap { works.work($0) }
        guard consent.isCollecting, let source = source(manga.sourceId),
              AnalyticsEligibility.admits(manga: manga, source: source, work: work, vocabulary: vocabulary),
              let ids = AnalyticsEligibility.catalogueIDs(work: work, manga: manga) else { return }
        record(.forYouOpened(ids, rank: rank, reason: reason))
    }

    func forYouShown(count: Int) {
        guard consent.isCollecting, count > 0 else { return }
        let day = AnalyticsEnvelope.day(for: now())
        guard defaults.string(forKey: Self.forYouDayKey) != day, record(.forYouShown(count: count)) else { return }
        defaults.set(day, forKey: Self.forYouDayKey)
    }

    func mltOpened(from manga: Manga, to openedManga: Manga, toMALID: Int) {
        let fromWork = works.workId(for: ListingKey(manga)).flatMap { works.work($0) }
        let toWork = works.workId(for: ListingKey(openedManga)).flatMap { works.work($0) }
        guard consent.isCollecting,
              let fromSource = source(manga.sourceId), let toSource = source(openedManga.sourceId),
              AnalyticsEligibility.admits(manga: manga, source: fromSource, work: fromWork, vocabulary: vocabulary),
              AnalyticsEligibility.admits(manga: openedManga, source: toSource, work: toWork, vocabulary: vocabulary),
              let fromIDs = AnalyticsEligibility.catalogueIDs(work: fromWork, manga: manga) else { return }
        let toIDs = CatalogueIDs(mal: toMALID, anilist: toWork?.externalIds.anilist)
        record(.mltOpened(from: fromIDs, to: toIDs))
    }

    func appActive() {
        let day = AnalyticsEnvelope.day(for: now())
        guard consent.isCollecting, defaults.string(forKey: Self.activeDayKey) != day,
              record(.appActive) else { return }
        defaults.set(day, forKey: Self.activeDayKey)
    }

    func readerOpened(_ mode: ReadingMode) { if consent.isCollecting { record(.readerOpened(ReaderModeKind(mode))) } }
    func searchUsed() { if consent.isCollecting { record(.searchUsed) } }
    func localImportFinished(fileCount: Int) {
        guard consent.isCollecting, let bucket = ImportFileBucket(count: fileCount) else { return }
        record(.localImportFinished(bucket))
    }
    func sourceInstalled(_ adult: AdultClassification) { if consent.isCollecting { record(.sourceInstalled(adult)) } }
    func settingChanged(_ key: AnalyticsSettingKey, _ value: AnalyticsSettingValue) {
        if consent.isCollecting { record(.settingChanged(key, value)) }
    }

    func resetAnalyticsID() { eraseLocalState() }
    func deleteMyData() { consent.setCollecting(false) }

    @discardableResult
    private func record(_ event: AnalyticsEvent) -> Bool {
        guard consent.isCollecting else { return false }
        let id = buffer.mintInstallIDIfNeeded()
        let envelope = AnalyticsEnvelope(install: id, date: now(), app: appVersion, event: event)
        buffer.append(envelope)
        events = buffer.events
        installID = id
        return true
    }

    private func consentChanged(from old: AnalyticsConsent, to new: AnalyticsConsent) {
        if new == .granted, old != .granted { record(.analyticsEnabled) }
        if old == .granted, new != .granted { eraseLocalState() }
    }

    private func eraseLocalState() {
        buffer.eraseAll(); ledger.removeAll(); removeLedger()
        defaults.removeObject(forKey: Self.forYouDayKey); defaults.removeObject(forKey: Self.activeDayKey)
        events = buffer.events; installID = buffer.installID
    }

    private func canonical(_ id: WorkID) -> WorkID? { works.work(id)?.id }

    private func ledgerEntry(for id: WorkID) -> (key: WorkID, ids: CatalogueIDs)? {
        guard let canonicalID = canonical(id) else { return nil }
        if let ids = ledger[canonicalID] { return (canonicalID, ids) }
        guard let match = ledger.first(where: { canonical($0.key) == canonicalID }) else { return nil }
        ledger[canonicalID] = match.value
        ledger.removeValue(forKey: match.key)
        saveLedger()
        return (canonicalID, match.value)
    }

    private func workIsStillEligibleWithoutManga(_ work: Work) -> Bool {
        guard !work.listings.contains(where: { $0.sourceId == LocalSource.sourceID }) else { return false }
        let allListings = work.listings + work.removedListings.map(\.key)
        guard allListings.allSatisfy({ source($0.sourceId).map { !$0.isNSFW } ?? false }) else { return false }
        guard let snapshot = work.snapshot else { return true }
        let names = snapshot.genres.map(\.name) + snapshot.tags.map(\.name)
        guard vocabulary != nil || names.isEmpty else { return false }
        return !names.contains { $0.caseInsensitiveCompare("Hentai") == .orderedSame ||
            $0.caseInsensitiveCompare("Erotica") == .orderedSame || vocabulary?.isAdult($0) == true }
    }

    private static func loadLedger(from directory: URL) -> [WorkID: CatalogueIDs] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("ledger.json")),
              let value = try? JSONDecoder().decode([WorkID: CatalogueIDs].self, from: data) else { return [:] }
        return value
    }

    private func saveLedger() {
        do {
            try FileManager.default.createDirectory(at: buffer.directoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: buffer.directoryURL.appendingPathComponent("ledger.json"), options: .atomic)
        } catch { }
    }

    private func removeLedger() { try? FileManager.default.removeItem(at: buffer.directoryURL.appendingPathComponent("ledger.json")) }
}
