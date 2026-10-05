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

        if var first = entries.first, first.mangaId == manga.id, first.chapterId == chapter.id {
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
        if entries.count > cap { entries.removeLast(entries.count - cap) }
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
    func entry(forChapter chapterId: String) -> ReadingEntry? {
        entries.first { $0.chapterId == chapterId }
    }

    /// Chapter numbers considered read for a manga — read to the end, or manually
    /// marked. Single source of truth shared by the chapter rows and `LibraryStore`
    /// badge reconciliation.
    func readChapterNumbers(forManga id: String) -> Set<String> {
        var numbers = Set(entries.filter { $0.mangaId == id && $0.isComplete }.map(\.chapterNumber))
        numbers.formUnion(readMarks.filter { $0.mangaId == id }.map(\.chapterNumber))
        return numbers
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

    func markRead(manga: Manga, chapter: Chapter) {
        guard !readMarks.contains(where: { $0.chapterId == chapter.id }) else { return }
        readMarks.append(ReadMark(mangaId: manga.id, chapterId: chapter.id,
                                  chapterNumber: chapter.number))
        save()
    }

    /// Clear read state: drop the manual mark and any history entries for the
    /// chapter, so "opened" no longer counts it as read.
    func markUnread(manga: Manga, chapter: Chapter) {
        readMarks.removeAll { $0.chapterId == chapter.id }
        entries.removeAll { $0.chapterId == chapter.id }
        save()
    }

    func toggleRead(manga: Manga, chapter: Chapter) {
        if isRead(chapterId: chapter.id) {
            markUnread(manga: manga, chapter: chapter)
        } else {
            markRead(manga: manga, chapter: chapter)
        }
    }

    /// Mark multiple chapters read in one save. Skips chapters already marked
    /// (mirrors the single-chapter `markRead`'s idempotency).
    func markRead(manga: Manga, chapters: [Chapter]) {
        var existing = Set(readMarks.map(\.chapterId))
        for chapter in chapters where !existing.contains(chapter.id) {
            readMarks.append(ReadMark(mangaId: manga.id, chapterId: chapter.id,
                                      chapterNumber: chapter.number))
            existing.insert(chapter.id)
        }
        save()
    }

    /// Mark multiple chapters unread in one save: drops both manual marks and
    /// any history entries for exactly the given chapters, leaving others untouched.
    func markUnread(manga: Manga, chapters: [Chapter]) {
        let ids = Set(chapters.map(\.id))
        readMarks.removeAll { ids.contains($0.chapterId) }
        entries.removeAll { ids.contains($0.chapterId) }
        save()
    }

    func delete(_ entry: ReadingEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
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
                            chapterNumber: chapterNumbers[mark.chapterId] ?? mark.chapterNumber)
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
