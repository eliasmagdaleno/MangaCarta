//
//  SimulatorSeed.swift
//  MangaCartaTests
//
//  The seeded-simulator fixture, expressed as data plus a builder that drives the **real**
//  stores. Lives in the test target because it is a fixture tool, not app behaviour.
//
//  **Why it drives the stores rather than writing JSON.** `works.json` is written by
//  `WorkStore`'s own encoder. Hand-rolling that file means maintaining a second definition
//  of the on-disk shape, and the day `Work` gains a field the hand-rolled copy keeps
//  decoding — into something quietly wrong. Minting through `WorkStore.mint` and upgrading
//  through `WorkStore.apply` is the same route `MetadataUpgradeQueue` takes in the app, so
//  a shape change breaks the seed loudly, in a test, instead of silently in a fixture.
//

import Foundation
@testable import MangaCarta

enum SimulatorSeed {

    /// One seeded Work: a Listing to mint from, plus the AniList record that upgrades it.
    ///
    /// `tags` carries AniList's **ranked** axis with real ranks, because the ≥ 60 floor in
    /// `TagPairSeeding` is what decides whether a Work contributes a seed pair at all — a
    /// fixture with plausible names and invented ranks would clear or miss that gate for
    /// reasons unrelated to the app.
    struct Row {
        // Read belongs to its enclosing seed row fixture.
        /// One chapter the seeded user has read, and how far into it they got.
        ///
        /// `pageCount` matters as much as `page`: "finished" is `page == pageCount - 1`,
        /// and Continue Reading, the in-progress badge and the taste signals all read that
        /// comparison rather than a flag. A fixture with every entry parked mid-chapter
        /// would show a home screen the app can never actually reach.
        struct Read { // swiftlint:disable:this nesting
            let chapterId: String
            let chapterNumber: String
            let page: Int
            let pageCount: Int
        }

        let title: String
        let sourceId: String
        let mangaId: String
        /// The cover the app would already be holding. `Manga` carries a ready-built
        /// cover URL everywhere else in the app (every `/manga` query injects
        /// `includes[]=cover_art` for exactly that), and `ReadingEntry` and `LibraryItem`
        /// each persist one — so a fixture without covers shows a Library of grey
        /// rectangles, which is not what a real user's looks like.
        let coverURL: URL?
        let malId: Int?
        let anilistId: Int
        let genres: [String]
        let tags: [RankedTag]
        let status: PublicationStatus
        let chapterTotal: Int?
        /// Chapters read, oldest first. Empty for a Work the user only saved.
        let reading: [Read]
        /// Whether the Work sits in the library.
        let isSaved: Bool
        /// Why the upgrade queue refused this Work, or `nil` for a Work it upgraded.
        ///
        /// A refused row is left **provisional** — no AniList snapshot — because that is
        /// the state the refusal is an answer to. Seeding a snapshot *and* a refusal
        /// would produce a Work no drain could ever have created.
        let refusal: UpgradeOutcome?
    }

    /// The defaults keys the seed writes — and therefore the exact set the in-place run
    /// clears first, so a previous fixture cannot survive underneath the new one.
    ///
    /// `taste.notInterested` / `taste.moreLikeThis` are deliberately absent: they hold
    /// explicit user feedback, and a fixture that pre-dismisses titles would silently
    /// subtract from every recommendation run made against it. Clearing them would erase
    /// real feedback the seed never replaces.
    static let seededDefaultsKeys = ["history.entries", "history.readMarks", "library.items"]

    /// Answers the fixture must **not** inherit from whatever was in the container before.
    ///
    /// These are resolution caches, not state the seed writes — so they are cleared rather
    /// than replaced. The ADR-0020 AniList-arm run is why they are here: two launches
    /// produced an empty instrument log against a fully built pool because
    /// `entityResolution.reverseCache` still held 107 answers from earlier sessions, so
    /// every target was answered without a search and the path under test never ran.
    /// ADR-0020 Decision 3 calls that a test-fixture problem in as many words. A fixture
    /// that silently disables the path under test is worse than no fixture.
    static let clearedDefaultsKeys = ["entityResolution.cache", "entityResolution.reverseCache"]

    /// Where `scripts/seed-simulator.sh` leaves the file that arms the seeding run.
    ///
    /// In Documents rather than Application Support so it never sits beside the fixture
    /// files the run writes, and so a stray marker is visible next to nothing else.
    static func markerURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("seed-simulator.marker")
    }

    /// Drops the answers a fixture must not inherit. Separate from `apply` because it is
    /// destruction, not seeding: the in-place run calls both, and a unit test that only
    /// wants rows in a store must not have to think about a defaults suite.
    static func clearInheritedState(in defaults: UserDefaults) {
        for key in clearedDefaultsKeys { defaults.removeObject(forKey: key) }
    }

    /// Mints each row's Listing, upgrades it with the row's AniList record, then reads and
    /// saves it — each through the store that owns that state, exactly as the app would.
    ///
    /// Reading sessions are spread over consecutive calendar days ending at `now`.
    /// Applying oldest-first still leaves the newest entry at index 0 because `record`
    /// prepends. A single injected anchor makes both the generated fixture and unit tests
    /// deterministic while normal app recording continues to default to `Date()`.
    @MainActor
    static func apply(_ rows: [Row], to store: WorkStore,
                      history: HistoryStore? = nil, library: LibraryStore? = nil,
                      attempts: UpgradeAttemptMemory? = nil, now: Date = Date()) {
        let readCount = rows.reduce(0) { $0 + $1.reading.count }
        var readIndex = 0
        for row in rows {
            let listing = Manga(id: row.mangaId,
                                sourceId: row.sourceId,
                                title: row.title,
                                description: "",
                                status: row.status == .finished ? "completed" : "ongoing",
                                year: nil,
                                coverURL: row.coverURL,
                                malId: row.malId)
            let id = store.mint(from: listing)
            if let refusal = row.refusal {
                // Refused Works stay provisional; the memory is the only record.
                attempts?.record(refusal, for: id)
            } else {
                store.apply(AniListWork(anilistId: row.anilistId,
                                        malId: row.malId,
                                        knownTitles: [row.title],
                                        genres: row.genres,
                                        tags: row.tags,
                                        publicationStatus: row.status,
                                        chapterTotal: row.chapterTotal),
                            to: id)
            }

            // Reading and saving mint on their own (ADR-0007). They are handed the *same*
            // listing, so they resolve to the Work minted above instead of a provisional
            // twin the AniList upgrade never touched.
            for read in row.reading {
                let daysBeforeNewest = readCount - readIndex - 1
                let recordedAt = Calendar.current.date(byAdding: .day,
                                                       value: -daysBeforeNewest,
                                                       to: now) ?? now
                history?.record(manga: listing,
                                chapter: Chapter(id: read.chapterId, number: read.chapterNumber,
                                                 title: nil),
                                position: ReadingPosition(page: read.page),
                                pageCount: read.pageCount,
                                at: recordedAt)
                readIndex += 1
            }
            if row.isSaved { library?.toggle(listing) }
        }
        // `record` writes through a throttle; without this the last entries of the run
        // would still be unwritten when the payload is read.
        history?.flush()
        // `record` writes through the same debounce `HistoryStore` does.
        attempts?.flush()
    }

    /// The rows the seeding run installs: the harvested set, generated into
    /// `SimulatorSeedFixture.swift` from real MangaDex ids and real AniList tag ranks.
    /// `sampleRows` below stays as the unit tests' own fixture, small enough to read.
    static var fixtureRows: [Row] { harvestedRows }

    /// A small hand-written set, used by the builder's own tests. The real fixture is
    /// harvested from AniList into a committed snapshot; this stays small so the unit
    /// tests stay fast and readable.
    static let sampleRows: [Row] = [
        Row(title: "Berserk", sourceId: "mangadex", mangaId: "md-berserk", coverURL: nil,
            malId: 2, anilistId: 30002,
            genres: ["Action", "Adventure", "Drama"],
            tags: [RankedTag(name: "Male Protagonist", rank: 92),
                   RankedTag(name: "Tragedy", rank: 88),
                   RankedTag(name: "Gore", rank: 85)],
            status: .releasing, chapterTotal: nil,
            reading: [Row.Read(chapterId: "ch-berserk-1", chapterNumber: "1",
                               page: 41, pageCount: 42),
                      Row.Read(chapterId: "ch-berserk-2", chapterNumber: "2",
                               page: 12, pageCount: 40)],
            isSaved: true, refusal: nil),
        Row(title: "Vinland Saga", sourceId: "mangadex", mangaId: "md-vinland", coverURL: nil,
            malId: 642, anilistId: 30642,
            genres: ["Action", "Adventure", "Drama"],
            tags: [RankedTag(name: "Male Protagonist", rank: 90),
                   RankedTag(name: "Tragedy", rank: 75),
                   RankedTag(name: "Historical", rank: 95)],
            status: .releasing, chapterTotal: nil,
            reading: [Row.Read(chapterId: "ch-vinland-1", chapterNumber: "1",
                               page: 53, pageCount: 54)],
            isSaved: true, refusal: nil),
        Row(title: "Vagabond", sourceId: "mangadex", mangaId: "md-vagabond", coverURL: nil,
            malId: 656, anilistId: 30656,
            genres: ["Action", "Adventure", "Drama"],
            tags: [RankedTag(name: "Male Protagonist", rank: 94),
                   RankedTag(name: "Tragedy", rank: 70),
                   RankedTag(name: "Historical", rank: 90)],
            status: .hiatus, chapterTotal: nil,
            reading: [], isSaved: false, refusal: nil),
        // Two refusals, one of each shape, so the ADR-0018 guard has something to release.
        // `knownTitlesCount: 1` is what `mint` produces from a single listing — the
        // suppression test fails loudly if that ever stops being true.
        // The bundled Source's qualified id (ADR-0003 A5): the fixture never carries the bare
        // compiled id, so nothing here depends on the launch-time migration.
        Row(title: "Ranking of Kings", sourceId: WeebCentralIdentityMigration.qualifiedID,
            mangaId: "wc-ranking", coverURL: nil,
            malId: nil, anilistId: 0,
            genres: [], tags: [],
            status: .releasing, chapterTotal: nil,
            reading: [], isSaved: true,
            refusal: .unmatched(knownTitlesCount: 1)),
        Row(title: "Kagurabachi", sourceId: "mangadex", mangaId: "md-kagurabachi", coverURL: nil,
            malId: 156901, anilistId: 0,
            genres: [], tags: [],
            status: .releasing, chapterTotal: nil,
            reading: [], isSaved: false,
            refusal: .absentFromProvider(malId: 156901)),
    ]
}
