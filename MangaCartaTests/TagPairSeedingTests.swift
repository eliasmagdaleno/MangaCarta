//
//  TagPairSeedingTests.swift
//  MangaCartaTests
//
//  Slice 2 of ADR-0011: the tag pairs that seed the AniList pool.
//
//  A pair is a claim someone actually made — both legs ranked >= 60 **in one Work** — so
//  every test here is written against Works, never against a flat tag list. Pure function,
//  no store, no network: the seeder is handed `workWeights` rather than a `TasteProfile`
//  precisely so it cannot compute a second definition of engagement (ADR-0009).
//

import XCTest
@testable import MangaCarta

final class TagPairSeedingTests: XCTestCase {

    // MARK: - Fixtures

    private static let vocabulary = TagVocabulary(
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
        entries: [
            TagVocabularyEntry(name: "Dungeon", category: "Theme-Fantasy",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Iyashikei", category: "Theme-Slice of Life",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Revenge", category: "Theme-Drama",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Full Color", category: "Technical",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Male Protagonist", category: "Cast-Main Cast",
                               isGeneralSpoiler: false, isAdult: false),
            TagVocabularyEntry(name: "Time Manipulation", category: "Theme-Sci Fi",
                               isGeneralSpoiler: true, isAdult: false),
            TagVocabularyEntry(name: "Tentacles", category: "Sexual Content",
                               isGeneralSpoiler: false, isAdult: true),
            TagVocabularyEntry(name: "Seinen", category: "Demographic",
                               isGeneralSpoiler: false, isAdult: false)
        ])

    /// A Work carrying `tags`, with an AniList snapshot — the only provider that ranks.
    private func work(_ title: String, _ tags: [(String, Int?)]) -> Work {
        var w = Work(id: WorkID(), displayTitle: title, knownTitles: [title],
                     externalIds: ExternalIDs(), listings: [], snapshot: nil)
        w.snapshot = MetadataSnapshot(provider: .anilist,
                                      fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      genres: [],
                                      tags: tags.map { RankedTag(name: $0.0, rank: $0.1) },
                                      publicationStatus: .finished,
                                      chapterTotal: nil)
        return w
    }

    private func seed(_ works: [Work],
                      weights: [WorkID: Double],
                      limit: Int = 5,
                      excludeAdultTags: Bool = true) -> [SeededTagPair] {
        seedPairs(works: works, weights: weights, vocabulary: Self.vocabulary,
                  limit: limit, excludeAdultTags: excludeAdultTags)
    }

    // MARK: - The formula

    /// `engagement(w) x min(rank_a, rank_b) / 100`, straight off ADR-0011.
    func testAPairIsWeightedByEngagementTimesTheWeakerLeg() {
        let berserk = work("Berserk", [("Dungeon", 90), ("Revenge", 70)])
        let pairs = seed([berserk], weights: [berserk.id: 2.0])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].pair, TagPair("Dungeon", "Revenge"))
        XCTAssertEqual(pairs[0].weight, 2.0 * 0.70, accuracy: 0.0001,
                       "the weaker leg sets the multiplier, not the stronger one")
    }

    /// The floor applies to **every** leg: `tag_in` is AND, so a conjunction is only as
    /// searchable as its weakest tag.
    func testALegBelowTheFloorTakesThePairWithIt() {
        let w = work("Below", [("Dungeon", 90), ("Revenge", 59)])
        XCTAssertEqual(seed([w], weights: [w.id: 1.0]), [])
    }

    /// MangaDex provisional snapshots land on the ranked axis with `rank == nil`
    /// (`AniListAPI.swift:50`). Unranked is not "ranked 0" and not "ranked high" — it is
    /// simply not a claim, so it cannot be half of one.
    func testAnUnrankedTagNeverSeeds() {
        let w = work("Provisional", [("Dungeon", nil), ("Revenge", 80)])
        XCTAssertEqual(seed([w], weights: [w.id: 1.0]), [])
    }

    /// Pairs that *recur* beat pairs that happened once — that is the entire reason the
    /// weight sums over Works rather than taking a maximum.
    func testWeightAccumulatesAcrossTheWorksCarryingThePair() {
        let one = work("One", [("Dungeon", 80), ("Revenge", 80)])
        let two = work("Two", [("Dungeon", 80), ("Revenge", 80)])
        let pairs = seed([one, two], weights: [one.id: 1.0, two.id: 1.0])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].weight, 2 * 0.80, accuracy: 0.0001)
    }

    /// A conjunction assembled across two Works is a claim nobody made.
    func testTagsInDifferentWorksDoNotFormAPair() {
        let one = work("One", [("Dungeon", 90)])
        let two = work("Two", [("Revenge", 90)])
        XCTAssertEqual(seed([one, two], weights: [one.id: 1.0, two.id: 1.0]), [])
    }

    /// `workWeights` only contains Works with reading history. No engagement, no vote —
    /// and the seeder must not invent one, which is what taking the whole `TasteProfile`
    /// would eventually tempt someone into.
    func testAWorkWithNoEngagementWeightContributesNothing() {
        let unread = work("Unread", [("Dungeon", 90), ("Revenge", 90)])
        XCTAssertEqual(seed([unread], weights: [:]), [])
    }

    // MARK: - Provenance (the >= 3 Works gate, ADR-0011 slice 3)

    /// The pair carries the Works that actually contributed a term to its weight. The gate
    /// counts *these*, not Works with a non-empty ranked axis: a Work can carry ranked tags
    /// where none clears 60, or where every one that does sits in an excluded category, and
    /// counting those opens the gate on a store that then produces no pairs at all.
    func testAPairCarriesTheWorksThatContributedToIt() {
        let one = work("One", [("Dungeon", 80), ("Revenge", 80)])
        let two = work("Two", [("Dungeon", 90), ("Revenge", 70)])
        // Ranked axis, nothing admissible: below the floor and an excluded category.
        let neither = work("Neither", [("Dungeon", 59), ("Full Color", 95)])

        let pairs = seed([one, two, neither],
                         weights: [one.id: 1.0, two.id: 1.0, neither.id: 1.0])

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].contributingWorks, [one.id, two.id],
                       "a Work whose tags are all inadmissible contributed nothing")
        XCTAssertEqual(Set(pairs.flatMap(\.contributingWorks)).count, 2,
                       "which is what the gate counts — and here it would correctly stay shut")
    }

    /// Provenance is per-pair, not a summary union, so overlapping pairs are visibly drawn
    /// on the same Works. This is the 2026-08-03 triangle made inspectable rather than
    /// inferred.
    func testOverlappingPairsShowTheySharTheirWorks() {
        let w = work("Triangle", [("Dungeon", 80), ("Iyashikei", 80), ("Revenge", 80)])
        let pairs = seed([w], weights: [w.id: 1.0])

        XCTAssertEqual(pairs.count, 3)
        XCTAssertTrue(pairs.allSatisfy { $0.contributingWorks == [w.id] })
    }

    // MARK: - Canonicalisation

    /// `Dungeon AND Revenge` and `Revenge AND Dungeon` are one pair. If the type did not
    /// canonicalise, two Works listing their tags in different orders would split one
    /// pair's weight across two keys and the top 5 would quietly become a top 4.
    func testPairOrderIsNotPartOfThePairsIdentity() {
        XCTAssertEqual(TagPair("Dungeon", "Revenge"), TagPair("Revenge", "Dungeon"))
        XCTAssertEqual(Set([TagPair("Dungeon", "Revenge"), TagPair("Revenge", "Dungeon")]).count, 1)

        let one = work("One", [("Dungeon", 80), ("Revenge", 80)])
        let two = work("Two", [("Revenge", 80), ("Dungeon", 80)])
        let pairs = seed([one, two], weights: [one.id: 1.0, two.id: 1.0])

        XCTAssertEqual(pairs.count, 1, "reversed order must not fragment the accumulation")
        XCTAssertEqual(pairs[0].weight, 2 * 0.80, accuracy: 0.0001)
    }

    // MARK: - Exclusions (deny list)

    /// Format facts and near-universal traits make bad queries everywhere. Excluded from
    /// **seeding only** — they stay available for scoring.
    func testTechnicalAndMainCastTagsDoNotSeed() {
        let w = work("Formatted", [("Dungeon", 90), ("Full Color", 90), ("Male Protagonist", 90)])
        let pairs = seed([w], weights: [w.id: 1.0])
        XCTAssertEqual(pairs, [], "Dungeon has no admissible partner left")
    }

    /// Added to the set on evidence, not on principle: the real store seeded four
    /// demographic pairs in its top 20. A demographic covers an enormous slice of the
    /// catalogue, so as a leg of an AND it barely narrows anything.
    func testDemographicTagsDoNotSeed() {
        let w = work("Demographic", [("Dungeon", 90), ("Seinen", 90)])
        XCTAssertEqual(seed([w], weights: [w.id: 1.0]), [])
    }

    /// The mutation-sensitive one. The exclusion set is a **deny list**: a tag the
    /// vocabulary has never heard of stays seedable. A permit-list
    /// (`guard let category = ... else { continue }`) would drop every tag AniList added
    /// since the cache was written — and a vocabulary up to 30 days behind is the
    /// *designed* steady state, not a failure mode.
    func testATagMissingFromTheVocabularyStaysSeedable() {
        let w = work("New", [("Dungeon", 90), ("Tag AniList Added Last Week", 90)])
        let pairs = seed([w], weights: [w.id: 1.0])

        XCTAssertEqual(pairs.map(\.pair), [TagPair("Dungeon", "Tag AniList Added Last Week")])
    }

    /// `isGeneralSpoiler` suppresses *reason strings*, never seeding. Easy to over-filter
    /// by pattern-matching the three vocabulary flags together.
    func testSpoilerTagsStillSeed() {
        let w = work("Spoilery", [("Dungeon", 90), ("Time Manipulation", 90)])
        XCTAssertEqual(seed([w], weights: [w.id: 1.0]).map(\.pair),
                       [TagPair("Dungeon", "Time Manipulation")])
    }

    /// Adult exclusion is a property of *which branch this is*, not of the domain — so it
    /// is a parameter, and the private branch flips it at the call site rather than
    /// carrying a diff in the body that every merge from `main` has to re-resolve.
    func testAdultTagsAreExcludedByDefaultAndAdmittedOnRequest() {
        let w = work("Adult", [("Dungeon", 90), ("Tentacles", 90)])

        XCTAssertEqual(seed([w], weights: [w.id: 1.0]), [])
        XCTAssertEqual(seed([w], weights: [w.id: 1.0], excludeAdultTags: false).map(\.pair),
                       [TagPair("Dungeon", "Tentacles")])
    }

    // MARK: - Ordering and the cut

    /// Ties are the common case, not an edge case: every pair inside one Work shares that
    /// Work's engagement, and any two with the same weaker leg produce an identical weight.
    /// Swift's sort is not stable, so without a total order the top-N cut through a tie
    /// block is arbitrary and next slice's golden file diffs on nothing.
    func testTiesBreakLexicographically() {
        let w = work("Tied", [("Dungeon", 80), ("Iyashikei", 80), ("Revenge", 80)])
        let pairs = seed([w], weights: [w.id: 1.0])

        XCTAssertEqual(pairs.map(\.pair), [TagPair("Dungeon", "Iyashikei"),
                                           TagPair("Dungeon", "Revenge"),
                                           TagPair("Iyashikei", "Revenge")])
    }

    func testHeavierPairsSortAboveLighterOnes() {
        let light = work("Light", [("Dungeon", 90), ("Iyashikei", 90)])
        let heavy = work("Heavy", [("Revenge", 60), ("Time Manipulation", 60)])
        let pairs = seed([light, heavy], weights: [light.id: 1.0, heavy.id: 10.0])

        XCTAssertEqual(pairs.map(\.pair), [TagPair("Revenge", "Time Manipulation"),
                                           TagPair("Dungeon", "Iyashikei")],
                       "engagement dominates: the multiplier band is only [0.60, 1.00]")
    }

    func testTheCutTakesTheTopN() {
        let w = work("Many", [("Dungeon", 80), ("Iyashikei", 80), ("Revenge", 80),
                              ("Time Manipulation", 80)])
        XCTAssertEqual(seed([w], weights: [w.id: 1.0]).count, 5, "C(4,2) = 6, capped at 5")
        XCTAssertEqual(seed([w], weights: [w.id: 1.0], limit: 2).count, 2)
    }
}

/// Runs the **real** seeder over the **real** store, pulled off the device.
///
/// Not a test: it asserts almost nothing and prints. It lives in the test target purely
/// for `@testable` access to app types, and it decodes with the app's own decoders so the
/// numbers it reports are the numbers the app would compute — the reason this is Swift and
/// not a sibling of `scripts/queue-status.sh`. A python reimplementation of the formula
/// would be a *second* definition of the thing we are trying to make a decision about.
///
/// Skips unless `MANGA_READER_APP_DATA` points at a copied app data container:
///
///     xcrun devicectl device copy from --device <udid> \
///       --domain-type appDataContainer --domain-identifier Elias-Magdaleno.Manga-Reader \
///       --source . --destination /tmp/appdata
///     MANGA_READER_APP_DATA=/tmp/appdata xcodebuild ... \
///       -only-testing:MangaCartaTests/TagPairSeedingDiagnostic
///
/// The simulator has no `works.json` at all, so running this against a simulator container
/// reports a false empty rather than a failure.
final class TagPairSeedingDiagnostic: XCTestCase {

    @MainActor
    func testDiagnosticPrintTopPairsFromTheRealStore() async throws {
        guard let root = ProcessInfo.processInfo.environment["MANGA_READER_APP_DATA"] else {
            throw XCTSkip("set MANGA_READER_APP_DATA to a copied app data container")
        }
        let base = URL(fileURLWithPath: root)
        let appSupport = base.appendingPathComponent("Library/Application Support")
        let caches = base.appendingPathComponent("Library/Caches")

        // Engagement is not persisted -- it is derived from history, which lives in
        // UserDefaults, not Application Support. So the prefs plist is loaded into a
        // throwaway suite and the profile is rebuilt exactly as a rail build would.
        let prefs = try Self.preferences(in: base)
        let defaults = makeTestDefaults("TagPairSeedingDiagnostic")
        for (key, value) in prefs { defaults.set(value, forKey: key) }

        let history = HistoryStore(defaults: defaults)
        let library = LibraryStore(defaults: defaults)
        let profileStore = TasteProfileStore(defaults: defaults)
        let workStore = WorkStore(directory: appSupport)

        let works = workStore.allWorkIds().compactMap { workStore.work($0) }
        print("\n=== store: \(works.count) Works, \(history.entries.count) history entries")

        // Same seam as `RecommendationEngine.resolveSignals`: mint from each history entry
        // so Listing-keyed history lands on Work identity.
        var entriesByWork: [WorkID: [ReadingEntry]] = [:]
        for entry in history.entries {
            let listing = Manga(id: entry.mangaId, sourceId: entry.sourceId ?? "mangadex",
                                title: entry.mangaTitle, description: "", status: "unknown",
                                year: nil, coverURL: entry.coverURL, malId: nil)
            entriesByWork[workStore.mint(from: listing), default: []].append(entry)
        }
        let signals = entriesByWork.map {
            TasteProfile.WorkSignal(workId: $0.key, entries: $0.value,
                                    tags: workStore.work($0.key)?.snapshot?.genres ?? [])
        }
        let profile = TasteProfile.build(signals: signals,
                                         savedIds: Set(library.items.map(\.id)),
                                         moreLikeThis: Set(profileStore.moreLikeThis),
                                         now: Date())

        let vocabularyURL = caches.appendingPathComponent("anilist-tag-vocabulary.json")
        let vocabulary: TagVocabulary
        if let data = try? Data(contentsOf: vocabularyURL),
           let decoded = try? JSONDecoder().decode(TagVocabulary.self, from: data) {
            vocabulary = decoded
            print("=== vocabulary: \(decoded.entries.count) tags")
        } else {
            // Loud, because an empty vocabulary excludes nothing: Technical and
            // Cast-Main Cast tags would seed and the top N would be wrong in a way that
            // looks entirely plausible.
            vocabulary = TagVocabulary(fetchedAt: Date(), entries: [])
            print("=== !!! NO VOCABULARY at \(vocabularyURL.path) — NOTHING IS EXCLUDED, "
                  + "these pairs are NOT what the app would seed")
        }

        // How lopsided is the input, before looking at any pair.
        let seedable = works.filter { work in
            (work.snapshot?.tags ?? []).contains { ($0.rank ?? 0) >= minimumSeedTagRank }
        }
        print("=== \(seedable.count) Works carry a tag at rank >= \(minimumSeedTagRank); "
              + "\(profile.workWeights.count) Works have engagement\n")
        for carrier in seedable.sorted(by: { (profile.workWeights[$0.id] ?? 0) > (profile.workWeights[$1.id] ?? 0) }) {
            let admissible: [RankedTag] = (carrier.snapshot?.tags ?? [])
                .filter { ($0.rank ?? 0) >= minimumSeedTagRank }
            let n = admissible.count
            print(String(format: "  %-40@  engagement %7.3f  %3d tags >= 60  -> %4d pairs",
                         carrier.displayTitle as NSString,
                         profile.workWeights[carrier.id] ?? 0, n, n * (n - 1) / 2))
        }

        // Top 20, not top 5: the question is whether the cut at 5 is dominated by one Work.
        let pairs = seedPairs(works: works, weights: profile.workWeights,
                              vocabulary: vocabulary, limit: 20)
        print("\n=== top \(pairs.count) pairs (the app would take the first 5)")
        for (i, seeded) in pairs.enumerated() {
            let carriers: [Work] = works.filter { candidate in
                guard profile.workWeights[candidate.id] != nil else { return false }
                let admissible: [RankedTag] = (candidate.snapshot?.tags ?? [])
                    .filter { ($0.rank ?? 0) >= minimumSeedTagRank }
                let names = Set(admissible.map { $0.name.lowercased() })
                return names.contains(seeded.pair.a.lowercased())
                    && names.contains(seeded.pair.b.lowercased())
            }
            print(String(format: "  %2d. %7.3f  %@ AND %@   <- %@",
                         i + 1, seeded.weight, seeded.pair.a as NSString, seeded.pair.b as NSString,
                         carriers.map(\.displayTitle).joined(separator: ", ") as NSString))
        }
        print("")
    }

    /// The app's `UserDefaults` as a plain dictionary. The plist name is the bundle id,
    /// but the container may hold others, so anything else is ignored.
    private static func preferences(in base: URL) throws -> [String: Any] {
        let dir = base.appendingPathComponent("Library/Preferences")
        let plists = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                   includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "plist" } ?? []
        for url in plists where url.lastPathComponent.contains("MangaCarta") {
            if let dict = NSDictionary(contentsOf: url) as? [String: Any] { return dict }
        }
        throw XCTSkip("no MangaCarta preferences plist under \(dir.path) — found \(plists.map(\.lastPathComponent))")
    }
}
