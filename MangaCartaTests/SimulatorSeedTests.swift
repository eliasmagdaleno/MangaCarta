//
//  SimulatorSeedTests.swift
//  MangaCartaTests
//
//  Builds the seeded-simulator fixture by driving the **real** stores, so the fixture
//  cannot drift from the app's own encoders. A hand-rolled works.json would decode into
//  something subtly wrong the day `Work` changes shape, and a fixture you cannot trust is
//  worse than no fixture — this project has paid for that lesson once already, when the
//  seeded simulator was erased and the ADR-0020 AniList arm lost its instrument.
//
//  The seeding *run* is `testWriteSeedToDisk`, which is skipped unless `SEED_SIMULATOR_OUT`
//  names an output directory. Everything else here is an ordinary unit test of the builder
//  and runs on every `xcodebuild test`, including CI.
//

import XCTest
@testable import MangaCarta

final class SimulatorSeedTests: XCTestCase {

    @MainActor
    private func makeStore() -> (WorkStore, URL) {
        let dir = makeTestDirectory("SimulatorSeedTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (WorkStore(directory: dir, saveDebounce: 0), dir)
    }

    /// The seed must mint one Work per listing and stamp each with the AniList snapshot
    /// its row carries — the same route `MetadataUpgradeQueue` takes when it upgrades a
    /// provisional Work, rather than a shortcut that writes the snapshot directly.
    @MainActor
    func testSeedMintsOneWorkPerRowWithItsSnapshot() throws {
        let (store, _) = makeStore()

        SimulatorSeed.apply(SimulatorSeed.sampleRows, to: store)

        XCTAssertEqual(store.allWorkIds().count, SimulatorSeed.sampleRows.count)
        for row in SimulatorSeed.sampleRows {
            let id = try XCTUnwrap(store.workId(for: ListingKey(sourceId: row.sourceId,
                                                               mangaId: row.mangaId)),
                                   "no Work minted for \(row.title)")
            let work = try XCTUnwrap(store.work(id))
            XCTAssertEqual(work.externalIds.mal, row.malId, "\(row.title) lost its MAL id")
            // A refused row is deliberately left provisional — that is the state the
            // ADR-0018 guard exists to release, so the fixture has to contain it.
            guard row.refusal == nil else {
                XCTAssertNil(work.snapshot,
                             "\(row.title) is a refusal but was upgraded anyway")
                continue
            }
            let snapshot = try XCTUnwrap(work.snapshot, "\(row.title) has no snapshot")
            XCTAssertEqual(snapshot.provider, .anilist,
                           "\(row.title) kept its provisional snapshot")
            XCTAssertEqual(snapshot.tags.map(\.name), row.tags.map(\.name))
        }
    }

    /// The fixture exists to unblock the AniList arm, and that arm is dead without seed
    /// pairs. `TagPairSeeding` only counts a Work toward a pair when **both** legs sit at
    /// rank >= 60, so a seed can look full of tags and still produce nothing. This asserts
    /// the property the fixture is actually for, rather than the row count.
    @MainActor
    func testSeedClearsTheThreeWorkTagPairGate() throws {
        let (store, _) = makeStore()
        SimulatorSeed.apply(SimulatorSeed.sampleRows, to: store)

        let works = store.allWorkIds().compactMap { store.work($0) }
        let weights = Dictionary(uniqueKeysWithValues: works.map { ($0.id, 1.0) })
        let pairs = seedPairs(works: works,
                              weights: weights,
                              vocabulary: TagVocabulary(fetchedAt: Date(), entries: []))

        let gated = pairs.filter { $0.contributingWorks.count >= 3 }
        XCTAssertFalse(gated.isEmpty,
                       "no tag pair reached 3 contributing Works; the AniList pool would "
                       + "have nothing to query. Pairs: "
                       + pairs.map { "\($0.pair.a)+\($0.pair.b)=\($0.contributingWorks.count)" }
                           .joined(separator: ", "))
    }

    /// An isolated defaults suite, so seeding never touches the test runner's own
    /// `standard` defaults and each test starts empty.
    private func makeDefaults() -> UserDefaults {
        return makeTestDefaults("SimulatorSeedTests")
    }

    /// The history and library halves must be written **by the real stores**, for the
    /// same reason `works.json` is: the keys and the encoders are theirs, and a
    /// hand-rolled copy drifts silently. This asserts the bytes that land in the suite
    /// decode back through the app's own Codables.
    @MainActor
    func testSeedWritesHistoryAndLibraryThroughTheRealStores() throws {
        let (works, _) = makeStore()
        let defaults = makeDefaults()
        let history = HistoryStore(defaults: defaults, works: works, saveInterval: 0)
        let library = LibraryStore(defaults: defaults, works: works)
        let now = Date(timeIntervalSince1970: 1_785_758_400) // 2026-08-01 12:00 UTC

        SimulatorSeed.apply(SimulatorSeed.sampleRows, to: works,
                            history: history, library: library, now: now)

        let entryData = try XCTUnwrap(defaults.data(forKey: "history.entries"),
                                      "no history written to the defaults suite")
        let entries = try JSONDecoder().decode([ReadingEntry].self, from: entryData)
        let expectedReads = SimulatorSeed.sampleRows.flatMap { $0.reading }
        XCTAssertEqual(entries.count, expectedReads.count)
        XCTAssertEqual(Set(entries.map(\.chapterId)), Set(expectedReads.map { $0.chapterId }))
        XCTAssertEqual(entries.first?.updatedAt, now)
        XCTAssertEqual(entries.map(\.updatedAt), entries.map(\.updatedAt).sorted(by: >),
                       "history is not newest-first")
        XCTAssertEqual(Set(entries.map { Calendar.current.startOfDay(for: $0.updatedAt) }).count,
                       expectedReads.count,
                       "seeded reading sessions should occupy consecutive date groups")
        for entry in entries {
            XCTAssertEqual(entry.sourceId, "mangadex", "\(entry.mangaTitle) lost its source")
            XCTAssertNotNil(entry.malId, "\(entry.mangaTitle) lost its MAL id")
        }

        let itemData = try XCTUnwrap(defaults.data(forKey: "library.items"),
                                     "no library written to the defaults suite")
        // Qualified: SwiftUI ships a `LibraryItem` of its own, and `@testable import`
        // re-exports it into this file.
        let items = try JSONDecoder().decode([MangaCarta.LibraryItem].self, from: itemData)
        let expectedSaved = SimulatorSeed.sampleRows.filter { $0.isSaved }.map { $0.mangaId }
        XCTAssertFalse(expectedSaved.isEmpty, "the sample rows save nothing to the library")
        XCTAssertEqual(Set(items.map { $0.id }), Set(expectedSaved))
    }

    /// Reading is a commitment, so history and library rows mint Works of their own
    /// (ADR-0007). If a seeded row were read or saved under a listing key the AniList
    /// upgrade never touched, the fixture would carry a provisional twin — a Work with no
    /// snapshot, invisible to the taste profile. One Work per row, not two.
    @MainActor
    func testHistoryAndLibraryRowsReuseTheMintedWork() throws {
        let (works, _) = makeStore()
        let defaults = makeDefaults()

        SimulatorSeed.apply(SimulatorSeed.sampleRows, to: works,
                            history: HistoryStore(defaults: defaults, works: works,
                                                  saveInterval: 0),
                            library: LibraryStore(defaults: defaults, works: works))

        XCTAssertEqual(works.allWorkIds().count, SimulatorSeed.sampleRows.count)
        for row in SimulatorSeed.sampleRows where row.refusal == nil {
            let id = try XCTUnwrap(works.workId(for: ListingKey(sourceId: row.sourceId,
                                                               mangaId: row.mangaId)))
            XCTAssertNotNil(works.work(id)?.snapshot,
                            "\(row.title) has no snapshot; a duplicate was minted")
        }
    }

    /// The in-place run wipes the app's own defaults for these keys before seeding, so
    /// the list has to be exactly what the seed writes. Too short and stale state from a
    /// previous fixture survives underneath the new one; too long and the run deletes a
    /// key the app owns and the seed never sets.
    ///
    /// `taste.notInterested` / `taste.moreLikeThis` are deliberately excluded — they hold
    /// explicit user feedback, and a fixture that pre-dismisses titles would silently
    /// subtract from every recommendation run made against it.
    @MainActor
    func testSeededDefaultsKeysAreExactlyWhatTheSeedWrites() throws {
        let (works, _) = makeStore()
        let suite = TestDefaults("SimulatorSeedTests.keys")
        defer { suite.remove() }
        let name = suite.suiteName
        let defaults = suite.defaults
        SimulatorSeed.apply(SimulatorSeed.sampleRows, to: works,
                            history: HistoryStore(defaults: defaults, works: works,
                                                  saveInterval: 0),
                            library: LibraryStore(defaults: defaults, works: works))

        // The suite's *own* domain, not `dictionaryRepresentation()`: that one merges the
        // whole search list, so it answers with the simulator's globals as well as ours.
        let written = try XCTUnwrap(UserDefaults().persistentDomain(forName: name)).keys
        XCTAssertEqual(Set(written), Set(SimulatorSeed.seededDefaultsKeys),
                       "the seed writes a different set of keys than the run clears")
    }

    /// A fixture with nothing but successes cannot exercise the ADR-0018 guard: the
    /// interesting behaviour is a Work the queue has already refused, and whether an
    /// authoritative id releases it. So the seed carries both refusal shapes, and this
    /// asserts they actually suppress — a stored `knownTitlesCount` that no longer
    /// matches what `mint` produces would silently stop suppressing, and the fixture
    /// would look fine while testing nothing.
    @MainActor
    func testSeedRecordsRefusalsThatActuallySuppress() throws {
        let (works, dir) = makeStore()
        let memory = UpgradeAttemptMemory(directory: dir, saveDebounce: 0)

        SimulatorSeed.apply(SimulatorSeed.sampleRows, to: works, attempts: memory)

        let refused = SimulatorSeed.sampleRows.filter { $0.refusal != nil }
        XCTAssertFalse(refused.isEmpty, "the sample rows contain no refusal")
        XCTAssertTrue(refused.contains {
            if case .unmatched = $0.refusal { return true } else { return false }
        },
                      "no .unmatched refusal in the seed")
        XCTAssertTrue(refused.contains {
            if case .absentFromProvider = $0.refusal { return true } else { return false }
        },
                      "no .absentFromProvider refusal in the seed")

        for row in SimulatorSeed.sampleRows {
            let id = try XCTUnwrap(works.workId(for: ListingKey(sourceId: row.sourceId,
                                                               mangaId: row.mangaId)))
            let work = try XCTUnwrap(works.work(id))
            XCTAssertEqual(memory.suppresses(work), row.refusal != nil,
                           "\(row.title) suppression does not match its row")
        }
    }

    /// The refusals only reach the simulator if they land in `upgrade-attempts.json`, and
    /// `record` writes through a debounce — the same throttle that made the history half
    /// arrive empty until the seed learned to flush.
    @MainActor
    func testSeedFlushesUpgradeAttemptsToDisk() throws {
        let (works, dir) = makeStore()
        let memory = UpgradeAttemptMemory(directory: dir, saveDebounce: 60)

        SimulatorSeed.apply(SimulatorSeed.sampleRows, to: works, attempts: memory)

        let file = dir.appendingPathComponent("upgrade-attempts.json")
        let data = try XCTUnwrap(try? Data(contentsOf: file),
                                 "upgrade-attempts.json was never written")
        // Read back through a fresh memory rather than the JSON shape, which is private
        // to the store on purpose.
        let reloaded = UpgradeAttemptMemory(directory: dir, saveDebounce: 0)
        let refusedTitles = SimulatorSeed.sampleRows.filter { $0.refusal != nil }.map(\.title)
        for title in refusedTitles {
            let row = try XCTUnwrap(SimulatorSeed.sampleRows.first { $0.title == title })
            let id = try XCTUnwrap(works.workId(for: ListingKey(sourceId: row.sourceId,
                                                               mangaId: row.mangaId)))
            XCTAssertTrue(reloaded.suppresses(try XCTUnwrap(works.work(id))),
                          "\(title)'s refusal did not survive the round trip")
        }
        XCTAssertFalse(data.isEmpty)
    }

    /// A stale resolution cache answers every reverse target without a search, which
    /// silently disables the widening path any run against this fixture is there to
    /// exercise. Two ADR-0020 AniList-arm launches were lost to exactly that.
    @MainActor
    func testSeedClearsInheritedResolutionCaches() throws {
        let (works, _) = makeStore()
        let suite = TestDefaults("SimulatorSeedTests.clear")
        defer { suite.remove() }
        let defaults = suite.defaults
        for key in SimulatorSeed.clearedDefaultsKeys {
            defaults.set(Data("stale".utf8), forKey: key)
        }

        SimulatorSeed.clearInheritedState(in: defaults)

        for key in SimulatorSeed.clearedDefaultsKeys {
            XCTAssertNil(defaults.data(forKey: key),
                         "\(key) survived seeding and would answer every reverse target")
        }
        XCTAssertFalse(SimulatorSeed.clearedDefaultsKeys.isEmpty)
        _ = works
    }

    // MARK: - The harvested fixture

    /// The generated fixture is what actually reaches the simulator, and it is the half
    /// no unit test would otherwise touch — `sampleRows` covers the builder, and a
    /// regenerated `SimulatorSeedFixture.swift` could arrive empty, coverless or pointing
    /// at manga ids that 404 without a single test noticing.
    ///
    /// These assert the properties the fixture exists for, not its exact contents: the
    /// harvest is re-runnable and its numbers move with MangaDex and AniList.
    @MainActor
    func testHarvestedFixtureIsUsableAsAFixture() throws {
        let rows = SimulatorSeed.harvestedRows
        XCTAssertGreaterThanOrEqual(rows.count, 15,
                                    "too few Works to look like a real library")

        for row in rows {
            // Real MangaDex ids, so every seeded row opens in the app. A row minted from
            // an invented id is a Library card that 404s on tap.
            XCTAssertEqual(row.mangaId.count, 36, "\(row.title) has no UUID manga id")
            XCTAssertEqual(row.sourceId, "mangadex")
            XCTAssertNotNil(row.coverURL, "\(row.title) would show a grey rectangle")
            if row.refusal == nil {
                XCTAssertFalse(row.tags.isEmpty, "\(row.title) carries no ranked axis")
            } else {
                XCTAssertTrue(row.tags.isEmpty,
                              "\(row.title) is a refusal but carries a ranked axis")
            }
        }

        let read = rows.filter { !$0.reading.isEmpty }
        XCTAssertGreaterThanOrEqual(read.count, 5, "too little reading to weight a taste profile")
        XCTAssertGreaterThanOrEqual(rows.filter { $0.isSaved }.count, 5, "too small a library")
        // Both refusal shapes, for the ADR-0018 guard.
        XCTAssertEqual(rows.filter { $0.refusal != nil }.count, 2)

        // A history where nothing was ever finished is a state the app cannot reach:
        // "finished" is `page == pageCount - 1`, and Continue Reading, the in-progress
        // badge and the taste signals all read that comparison.
        let allReads = read.flatMap { $0.reading }
        XCTAssertTrue(allReads.contains { $0.page == $0.pageCount - 1 },
                      "nothing in the seeded history was ever finished")
        XCTAssertTrue(allReads.contains { $0.page < $0.pageCount - 1 },
                      "nothing in the seeded history is still in progress")
    }

    /// The gate the whole fixture exists to clear, asserted against the *harvested* rows
    /// rather than the samples — real AniList ranks, and the >= 60 floor is theirs to
    /// clear or miss.
    @MainActor
    func testHarvestedFixtureClearsTheTagPairGateWithRoom() throws {
        let (store, _) = makeStore()
        SimulatorSeed.apply(SimulatorSeed.harvestedRows, to: store)

        let works = store.allWorkIds().compactMap { store.work($0) }
        let weights = Dictionary(uniqueKeysWithValues: works.map { ($0.id, 1.0) })
        let pairs = seedPairs(works: works, weights: weights,
                              vocabulary: TagVocabulary(fetchedAt: Date(), entries: []))
        let gated = pairs.filter { $0.contributingWorks.count >= 3 }
        XCTAssertGreaterThanOrEqual(gated.count, 5,
                                    "only \(gated.count) pairs cleared the gate; the "
                                    + "AniList pool would query almost nothing")
    }

    // MARK: - The seeding run

    /// The run itself. **It writes into the live app container of whatever simulator it is
    /// running on**, which the script pins by device id rather than by `booted`, and
    /// is skipped unless `scripts/seed-simulator.sh` has dropped its marker file there.
    ///
    /// In place, rather than to a staging directory the script copies from: this target is
    /// hosted by the app, so the test process already runs inside the very container the
    /// fixture is for — `WorkStore()`'s default directory *is* the app's Application
    /// Support, and `UserDefaults.standard` *is* the app's domain. Writing anywhere else
    /// would mean re-deriving both locations in shell and copying between them, which is
    /// two more things to get wrong than seeding through the stores directly.
    ///
    /// The gate is a marker file rather than an environment variable because `xcodebuild`
    /// forwards no environment into the test process — verified, with and without the
    /// `TEST_RUNNER_` prefix. A marker the script drops into a container it located with
    /// `simctl get_app_container` cannot be tripped by an ordinary `xcodebuild test` or
    /// by CI, which is the property that matters for a destructive run.
    ///
    /// **Backing up the container is the script's job**, and it does that before writing
    /// the marker. By the time this runs, clobbering is the intent.
    @MainActor
    func testSeedTheSimulatorInPlace() throws {
        let marker = SimulatorSeed.markerURL()
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("no seeding marker; run scripts/seed-simulator.sh to seed")
        }
        // Consumed first, so a crash mid-seed cannot leave a marker that re-fires the
        // destructive path on the next ordinary test run.
        try FileManager.default.removeItem(at: marker)

        let support = WorkStore.applicationSupportDirectory()
        let defaults = UserDefaults.standard
        // Seeding *onto* an existing fixture would merge, not replace — the stores load
        // what is there and mint alongside it. Clear the halves the seed owns, and only
        // those: the caches half rebuilds itself and is not ours to touch.
        for name in ["works.json", "upgrade-attempts.json"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
        for key in SimulatorSeed.seededDefaultsKeys { defaults.removeObject(forKey: key) }
        SimulatorSeed.clearInheritedState(in: defaults)

        let works = WorkStore(directory: support, saveDebounce: 0)
        let attempts = UpgradeAttemptMemory(directory: support, saveDebounce: 0)
        SimulatorSeed.apply(SimulatorSeed.fixtureRows, to: works,
                            history: HistoryStore(defaults: defaults, works: works,
                                                  saveInterval: 0),
                            library: LibraryStore(defaults: defaults, works: works),
                            attempts: attempts)
        works.flush()
        defaults.synchronize()

        // Assert against the container, not the in-memory stores: the whole point of the
        // run is that the bytes reached the app's own locations.
        XCTAssertEqual(works.allWorkIds().count, SimulatorSeed.fixtureRows.count)
        for name in ["works.json", "upgrade-attempts.json"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: support.appendingPathComponent(name).path),
                "\(name) is missing from the app container after seeding")
        }
        for key in SimulatorSeed.seededDefaultsKeys {
            XCTAssertNotNil(defaults.data(forKey: key), "\(key) never reached the app's defaults")
        }
        print("seeded \(SimulatorSeed.fixtureRows.count) rows into \(support.path)")
    }
}
