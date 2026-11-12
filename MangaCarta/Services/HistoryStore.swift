//
//  HistoryStore.swift
//  MangaCarta
//
//  Chronological reading history + per-manga resume position. Backed by
//  UserDefaults. Powers both the detail "Continue" button and the History tab.
//

import SwiftUI

/// One logged reading position. A continuous session (the chapter being
/// recorded is already the newest entry) updates that entry in place;
/// re-opening a chapter later — after other reading has happened — creates a
/// brand-new entry so the log is a full chronological history.
struct ReadingEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let mangaId: String
    let mangaTitle: String
    let coverURL: URL?
    let chapterId: String
    let chapterNumber: String
    var page: Int
    var pageCount: Int
    var updatedAt: Date
    var sourceId: String? = nil   // nil = saved before multi-source; treat as MangaDex
    /// How far down `page` the reader had scrolled, 0..<1. Only ever non-zero in the
    /// vertical mode, where a page is a long strip (ADR-0014). Flat rather than a nested
    /// `ReadingPosition` so entries saved before it existed decode unchanged — the
    /// default reads as "the top of `page`", which is exactly the old behaviour.
    var fraction: Double = 0
    /// The MyAnimeList id the *source* published, if it publishes one — MangaDex returns
    /// it as `links.mal` on the response the app already fetches. Carried here so the
    /// Work minted from this entry is born with it and never becomes a resolution
    /// question (ADR-0018). `nil` means the source published none, or the entry predates
    /// this field; both are answered the same way, by resolving.
    var malId: Int? = nil

    /// The two fields as the one value the rest of the app passes around. They are
    /// only meaningful together: a `fraction` belongs to the `page` it was captured on.
    var position: ReadingPosition {
        get { ReadingPosition(page: page, fraction: fraction) }
        set { page = newValue.page; fraction = newValue.fraction }
    }

    /// The chapter was read to its end.
    ///
    /// `record` only ever advances `page` (ADR-0014), so this is a durable fact about the
    /// furthest point reached, not a snapshot of where the reader happens to be sitting.
    /// The `pageCount > 0` guard matters: an entry recorded before any page loaded has a
    /// count of 0, and `page >= -1` would otherwise call that finished.
    var isComplete: Bool { pageCount > 0 && page >= pageCount - 1 }

    init(id: UUID, mangaId: String, mangaTitle: String, coverURL: URL?, chapterId: String,
         chapterNumber: String, page: Int, pageCount: Int, updatedAt: Date,
         sourceId: String? = nil, fraction: Double = 0, malId: Int? = nil) {
        self.id = id
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.coverURL = coverURL
        self.chapterId = chapterId
        self.chapterNumber = chapterNumber
        self.page = page
        self.pageCount = pageCount
        self.updatedAt = updatedAt
        self.sourceId = sourceId
        self.fraction = fraction
        self.malId = malId
    }

    /// Hand-written **only** to make `fraction` tolerate its own absence.
    ///
    /// A default value does *not* do that: Swift's synthesized `init(from:)` ignores
    /// defaults for non-optional properties and throws `keyNotFound`, so every entry
    /// saved before ADR-0014 would fail to decode and the entire history would read as
    /// empty. `sourceId` got away with a bare default because `Optional` decodes via
    /// `decodeIfPresent`; a `Double` does not. Every other key stays required — a
    /// missing `page` or `chapterId` is corruption, not an older format.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mangaId = try c.decode(String.self, forKey: .mangaId)
        mangaTitle = try c.decode(String.self, forKey: .mangaTitle)
        coverURL = LocalLibraryPaths.relocated(try c.decodeIfPresent(URL.self, forKey: .coverURL))
        chapterId = try c.decode(String.self, forKey: .chapterId)
        chapterNumber = try c.decode(String.self, forKey: .chapterNumber)
        page = try c.decode(Int.self, forKey: .page)
        pageCount = try c.decode(Int.self, forKey: .pageCount)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction) ?? 0
        // `Optional`, so a bare default would have sufficed — spelled out only because
        // this decoder is hand-written and silence here would read as an oversight.
        malId = try c.decodeIfPresent(Int.self, forKey: .malId)
    }
}

/// A chapter the user explicitly marked as read (or that was read but whose
/// history entry was cleared). Kept separate from `ReadingEntry` so a manual
/// mark never pollutes the chronological reading log.
struct ReadMark: Codable, Hashable {
    let mangaId: String
    let chapterId: String
    let chapterNumber: String
    let sourceId: String?

    init(mangaId: String, chapterId: String, chapterNumber: String, sourceId: String? = nil) {
        self.mangaId = mangaId
        self.chapterId = chapterId
        self.chapterNumber = chapterNumber
        self.sourceId = sourceId
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    typealias ChapterCompleted = (ChapterCompletion) -> Void

    @Published private(set) var entries: [ReadingEntry] = []
    @Published private(set) var readMarks: [ReadMark] = []

    private let key = "history.entries"
    private let marksKey = "history.readMarks"
    private let defaults: UserDefaults
    private let cap = 500
    /// Reading is a commitment, so it mints a Work (ADR-0007). Optional because
    /// history predates the Work store and most tests have no interest in it; the
    /// app wires it in `MangaCartaApp`.
    private let works: WorkStore?
    private let chapterCompleted: ChapterCompleted

    /// How long a recorded position may sit unwritten. Only `record` waits — see
    /// `saveSoon()`.
    private let saveInterval: TimeInterval
    private var pendingSave: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, works: WorkStore? = nil,
         saveInterval: TimeInterval = 2,
         chapterCompleted: @escaping ChapterCompleted = { _ in }) {
        self.defaults = defaults
        self.works = works
        self.saveInterval = saveInterval
        self.chapterCompleted = chapterCompleted
        load()
    }

    /// Record progress. If the newest entry (the current session) is the same
    /// manga + chapter, update it in place; otherwise (including re-opening a
    /// chapter read previously) prepend a brand-new entry so the log stays a
    /// full chronological history of reading sessions.
    func record(manga: Manga, chapter: Chapter, position: ReadingPosition, pageCount: Int,
                at recordedAt: Date = Date()) {
        // Reading is the strongest commitment signal there is. Minting is local and
        // network-free, so it is safe on this path — it runs on every page turn.
        let workID = works?.mint(from: manga)
        var wasComplete = false

        if var first = entries.first, matches(first, chapter: chapter, in: manga) {
            wasComplete = first.isComplete
            // Furthest position reached. `ReadingPosition` is ordered lexicographically,
            // so this keeps the larger fraction within a page and takes the whole new
            // pair on a higher one. Monotonicity is load-bearing: `page` is also the
            // completion signal for Continue Reading, the in-progress badge and taste
            // signals, so a backwards scroll must not walk it back (ADR-0014).
            let advanced = position > first.position

            // **A call that learns nothing changes nothing** — not the position, not the
            // timestamp, and no write. The reader has no latch of its own any more, so it
            // calls this on every throttled tick and every backwards scroll; `save()`
            // re-encodes all 500 entries plus the read marks. Same bargain as
            // `WorkStore.mint`, which is on this same page-turn path.
            guard advanced || first.pageCount != pageCount else { return }

            if advanced { first.position = position }
            first.pageCount = pageCount
            first.updatedAt = recordedAt
            entries[0] = first
        } else {
            entries.insert(
                ReadingEntry(id: UUID(), mangaId: manga.id, mangaTitle: manga.title,
                             coverURL: manga.coverURL, chapterId: chapter.id,
                             chapterNumber: chapter.number, page: position.page,
                             pageCount: pageCount, updatedAt: recordedAt,
                             sourceId: manga.sourceId, fraction: position.fraction,
                             malId: manga.malId),
                at: 0
            )
        }
        if entries.count > cap {
            preserveReadMarks(for: Array(entries.suffix(entries.count - cap)))
            entries.removeLast(entries.count - cap)
        }
        saveSoon()

        if !wasComplete,
           entries.first?.isComplete == true,
           let workID,
           let progress = MALChapterProgress.map(chapterNumber: chapter.number) {
            chapterCompleted(ChapterCompletion(manga: manga, chapter: chapter, workID: workID,
                                               progress: progress, completedAt: recordedAt))
        }
    }

    func latestEntry(forManga id: String) -> ReadingEntry? {
        entries.first { $0.mangaId == id }
    }

    /// Newest entry across a Work's Listings, so Continue still finds reading done through
    /// a Listing other than the one the page was opened from (#328). History is
    /// newest-first, so the first match is the most recent, whichever Listing it names.
    func latestEntry(forMangaIds ids: Set<String>) -> ReadingEntry? {
        entries.first { ids.contains($0.mangaId) }
    }

    /// Newest history entry for a specific chapter, if any. Drives the "Page: N"
    /// resume label on a chapter row.
    ///
    /// An exact chapter-id match wins; otherwise the newest entry with the same ordinal on any
    /// Listing of the Work (ADR-0027). Without a Work, or for an unparseable number, id only.
    func entry(for chapter: Chapter, in manga: Manga) -> ReadingEntry? {
        if let exact = entries.first(where: { matches($0, chapter: chapter, in: manga) }) { return exact }
        let listingIDs = listingIDs(for: manga)
        guard !listingIDs.isEmpty, let ordinal = ChapterOrdinal.parse(chapter.number) else { return nil }
        return entries.first { entry in
            listingIDs.contains(where: { $0.mangaId == entry.mangaId &&
                (entry.sourceId == nil || $0.sourceId == entry.sourceId) }) &&
                ChapterOrdinal.parse(entry.chapterNumber) == ordinal
        }
    }

    /// Legacy id-only lookup for storage maintenance callers that have no Manga value.
    func entry(forChapter chapterId: String) -> ReadingEntry? {
        entries.first { $0.chapterId == chapterId }
    }

    /// Chapter numbers considered read on one Listing — read to the end, or manually
    /// marked. The per-Listing building block: Work-wide answers (ADR-0027) go through
    /// `readOrdinals(forListings:)`, `isRead(_:in:)` and `unreadCount(for:)`.
    func readChapterNumbers(forManga id: String) -> Set<String> {
        var numbers = Set(entries.filter { $0.mangaId == id && $0.isComplete }.map(\.chapterNumber))
        numbers.formUnion(readMarks.filter { $0.mangaId == id }.map(\.chapterNumber))
        return numbers
    }

    func readChapterNumbers(for listing: ListingKey) -> Set<String> {
        var numbers = Set(entries.filter {
            $0.mangaId == listing.mangaId && ($0.sourceId == nil || $0.sourceId == listing.sourceId) && $0.isComplete
        }.map(\.chapterNumber))
        numbers.formUnion(readMarks.filter {
            $0.mangaId == listing.mangaId && ($0.sourceId == nil || $0.sourceId == listing.sourceId)
        }.map(\.chapterNumber))
        return numbers
    }

    /// Parsed chapter ordinals read on the supplied Listings. This is the shared
    /// derivation used by Work-wide read state and update badges (ADR-0027).
    func readOrdinals(forListings listings: [ListingKey]) -> Set<ChapterOrdinal> {
        listings.reduce(into: Set<ChapterOrdinal>()) { result, listing in
            result.formUnion(readChapterNumbers(for: listing).compactMap(ChapterOrdinal.parse))
        }
    }

    /// A Library item's unread badge, Work-wide (ADR-0027, #331). A chapter number counts as
    /// read when it is read on the item's own Listing, or when its ordinal is read on any
    /// Listing of the item's Work — so a title saved from A and read through B still falls.
    /// No Work: the item's own Listing only, as before. `nil` chapter numbers (never
    /// refreshed) is 0, as `LibraryItem.unreadCount` has always said.
    func unreadCount(for item: LibraryItem) -> Int {
        let listing = ListingKey(sourceId: item.sourceId ?? LegacySourceID.unattributed, mangaId: item.id)
        let workOrdinals = workListings(for: listing).map(readOrdinals(forListings:)) ?? []
        return item.unreadCount(readNumbers: readChapterNumbers(for: listing)) { number in
            ChapterOrdinal.parse(number).map(workOrdinals.contains) ?? false
        }
    }

    // MARK: Read / unread

    /// True if the chapter was read to its end, or manually marked read.
    ///
    /// *Opening* is deliberately not enough. It used to be, which made the unread badge
    /// undercount — abandoning a chapter on page 1 stopped it counting as unread. A
    /// manual mark still outranks completion, which is the point of marking.
    func isRead(chapterId: String) -> Bool {
        entries.contains { $0.chapterId == chapterId && $0.isComplete } ||
        readMarks.contains { $0.chapterId == chapterId }
    }

    /// True when this chapter is complete or manually marked, either by id or by
    /// ordinal on another Listing of the same Work. Without a Work, id matching is
    /// intentionally unchanged.
    func isRead(_ chapter: Chapter, in manga: Manga) -> Bool {
        if entries.contains(where: { matches($0, chapter: chapter, in: manga) && $0.isComplete }) ||
            readMarks.contains(where: { matches($0, chapter: chapter, in: manga) }) { return true }
        guard let target = ChapterOrdinal.parse(chapter.number),
              let workListings = workListings(for: manga) else { return false }
        let ordinals = readOrdinals(forListings: workListings)
        return ordinals.contains(target)
    }

    func markRead(manga: Manga, chapter: Chapter) {
        guard !readMarks.contains(where: { matches($0, chapter: chapter, in: manga) }) else { return }
        readMarks.append(ReadMark(mangaId: manga.id, chapterId: chapter.id,
                                  chapterNumber: chapter.number, sourceId: manga.sourceId))
        save()
    }

    /// Clear read state: drop the manual mark and any history entries for the
    /// chapter, so "opened" no longer counts it as read.
    func markUnread(manga: Manga, chapter: Chapter) {
        let listingIDs = listingIDs(for: manga)
        readMarks.removeAll { matches($0, chapter: chapter, in: manga) ||
            clearsOrdinal($0.mangaId, sourceId: $0.sourceId, number: $0.chapterNumber, matching: chapter, listingIDs: listingIDs) }
        entries.removeAll { matches($0, chapter: chapter, in: manga) ||
            clearsOrdinal($0.mangaId, sourceId: $0.sourceId, number: $0.chapterNumber, matching: chapter, listingIDs: listingIDs) }
        save()
    }

    func toggleRead(manga: Manga, chapter: Chapter) {
        if isRead(chapter, in: manga) {
            markUnread(manga: manga, chapter: chapter)
        } else {
            markRead(manga: manga, chapter: chapter)
        }
    }

    /// Mark multiple chapters read in one save. Skips chapters already marked
    /// (mirrors the single-chapter `markRead`'s idempotency).
    func markRead(manga: Manga, chapters: [Chapter]) {
        for chapter in chapters where !readMarks.contains(where: { matches($0, chapter: chapter, in: manga) }) {
            readMarks.append(ReadMark(mangaId: manga.id, chapterId: chapter.id,
                                      chapterNumber: chapter.number, sourceId: manga.sourceId))
        }
        save()
    }

    /// Mark multiple chapters unread in one save: drops both manual marks and
    /// any history entries for exactly the given chapters, leaving others untouched.
    func markUnread(manga: Manga, chapters: [Chapter]) {
        let listingIDs = listingIDs(for: manga)
        for chapter in chapters {
            readMarks.removeAll { matches($0, chapter: chapter, in: manga) ||
                clearsOrdinal($0.mangaId, sourceId: $0.sourceId, number: $0.chapterNumber, matching: chapter, listingIDs: listingIDs) }
            entries.removeAll { matches($0, chapter: chapter, in: manga) ||
                clearsOrdinal($0.mangaId, sourceId: $0.sourceId, number: $0.chapterNumber, matching: chapter, listingIDs: listingIDs) }
        }
        save()
    }

    private func workListings(for manga: Manga) -> [ListingKey]? {
        workListings(for: ListingKey(manga))
    }

    private func workListings(for listing: ListingKey) -> [ListingKey]? {
        guard let works, let id = works.workId(for: listing),
              let work = works.work(id) else { return nil }
        return work.listings
    }

    /// The Work's Listing ids, or empty when the Manga has no Work — which makes every
    /// ordinal match fail and leaves id matching alone, as before ADR-0027.
    private func listingIDs(for manga: Manga) -> Set<ListingKey> {
        guard let listings = workListings(for: manga) else { return [] }
        return Set(listings).union([ListingKey(manga)])
    }

    private func clearsOrdinal(_ mangaID: String, sourceId: String?, number: String, matching chapter: Chapter,
                               listingIDs: Set<ListingKey>) -> Bool {
        guard listingIDs.contains(where: { $0.mangaId == mangaID && (sourceId == nil || $0.sourceId == sourceId) }),
              let target = ChapterOrdinal.parse(chapter.number) else { return false }
        return ChapterOrdinal.parse(number) == target
    }

    private func matches(_ entry: ReadingEntry, chapter: Chapter, in manga: Manga) -> Bool {
        entry.mangaId == manga.id && entry.chapterId == chapter.id &&
            (entry.sourceId == nil || entry.sourceId == manga.sourceId)
    }

    private func matches(_ mark: ReadMark, chapter: Chapter, in manga: Manga) -> Bool {
        mark.mangaId == manga.id && mark.chapterId == chapter.id &&
            (mark.sourceId == nil || mark.sourceId == manga.sourceId)
    }

    func delete(_ entry: ReadingEntry) {
        preserveReadMarks(for: entries.filter { $0.id == entry.id })
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        preserveReadMarks(for: entries)
        entries.removeAll()
        save()
    }

    func rewriteLocalListing(from oldID: String, to newID: String,
                             chapterNumbers: [String: String]) {
        entries = entries.map { entry in
            guard entry.mangaId == oldID else { return entry }
            var updated = entry
            updated = ReadingEntry(id: entry.id, mangaId: newID, mangaTitle: entry.mangaTitle,
                                   coverURL: entry.coverURL, chapterId: entry.chapterId,
                                   chapterNumber: chapterNumbers[entry.chapterId] ?? entry.chapterNumber,
                                   page: entry.page, pageCount: entry.pageCount, updatedAt: entry.updatedAt,
                                   sourceId: entry.sourceId, fraction: entry.fraction, malId: entry.malId)
            return updated
        }
        readMarks = readMarks.map { mark in
            guard mark.mangaId == oldID else { return mark }
            return ReadMark(mangaId: newID, chapterId: mark.chapterId,
                            chapterNumber: chapterNumbers[mark.chapterId] ?? mark.chapterNumber,
                            sourceId: mark.sourceId)
        }
        save()
    }

    /// Coalesce a write from the scroll path. **A throttle, not a debounce:** an already
    /// scheduled write is left alone rather than pushed out, because every recorded
    /// position carries new data and re-arming would defer the write for as long as the
    /// reader keeps scrolling — which, in a webtoon, is the entire session (ADR-0014).
    ///
    /// Only `record` comes through here. Deliberate user actions — marking read, deleting,
    /// clearing — write straight through, and in doing so satisfy whatever this had
    /// pending.
    private func saveSoon() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, self?.saveInterval ?? 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write anything the throttle is still holding. Call on backgrounding: a scheduled
    /// write that never runs because the app was suspended is a lost reading position.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
        if let marks = try? JSONEncoder().encode(readMarks) {
            defaults.set(marks, forKey: marksKey)
        }
    }

    /// Preserve completion when a history entry leaves the bounded log. An existing
    /// manual or migrated mark wins, so each chapter keeps one durable read mark.
    private func preserveReadMarks(for entries: [ReadingEntry]) {
        for entry in entries where entry.isComplete && !readMarks.contains(where: {
            $0.mangaId == entry.mangaId && $0.chapterId == entry.chapterId &&
                ($0.sourceId == nil || $0.sourceId == entry.sourceId)
        }) {
            readMarks.append(ReadMark(mangaId: entry.mangaId, chapterId: entry.chapterId,
                                      chapterNumber: entry.chapterNumber, sourceId: entry.sourceId))
        }
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ReadingEntry].self, from: data) {
            entries = decoded
        }
        if let data = defaults.data(forKey: marksKey),
           let decoded = try? JSONDecoder().decode([ReadMark].self, from: data) {
            readMarks = decoded
        }
    }
}
