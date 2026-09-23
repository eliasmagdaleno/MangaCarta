//
//  RecommendationGoldenTests.swift
//  MangaCartaTests
//
//  A golden-file harness for the "For You" blend.
//
//  WHY THIS EXISTS
//  The blend has tuning constants (wTag, wMal, agreementBonus in CompositeCandidateProvider;
//  seed cap; perSeedLimit) that were chosen a priori and have never been validated. There is
//  no labeled relevance data for this app — one user, no ground truth — so we cannot *prove*
//  a ranking change is an improvement. What we can do is make every ranking change show up as
//  a readable diff in a pull request. That is what this file buys: change a constant or swap
//  the agreement formula, re-run, and the golden diff shows exactly which titles moved, by how
//  much, and why.
//
//  WHAT IS GOLDENED
//  `CompositeCandidateProvider.candidates(...)` — the deterministic ranked pool.
//  Deliberately NOT `RecommendationEngine.compose()`, which mixes in a seeded exploration
//  reshuffle (`SeededRNG`) that is designed to differ between sessions and can never be
//  goldened.
//
//  WHY THE FIXTURE IS SYNTHETIC
//  Hand-written titles with hand-chosen feed positions, so every number in the golden file is
//  derivable with a calculator. This proves the *mechanics* of the blend, not the *quality* of
//  real recommendations — a recorded-from-real-API fixture would be a separate, larger case,
//  and would bake personal reading history into a public repo.
//
//  FIXTURE INVARIANT — NO TIED SCORES
//  `TagCandidateProvider` and `MALCandidateProvider` both finish with
//  `scores.sorted { $0.value > $1.value }.prefix(limit)` and no secondary tie-break. Swift's
//  sort is not guaranteed stable, so exactly-tied scores could reorder run to run, and a tie
//  straddling `limit` could change pool membership. (`CompositeCandidateProvider` does have an
//  explicit id tie-break; the two sub-providers do not.) The tag weights and seed weights below
//  are therefore chosen so that no two candidates ever tie. If you edit the fixture, preserve
//  that property or the golden will flake.
//
//  REGENERATING
//      TEST_RUNNER_REGENERATE_GOLDENS=1 xcodebuild -scheme MangaCarta \
//        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO \
//        test -only-testing:MangaCartaTests/RecommendationGoldenTests
//
//  The `TEST_RUNNER_` prefix is required and is not decoration: tests run in a separate process
//  inside the simulator, and xcodebuild forwards only variables carrying that prefix, stripping
//  it before handing them to the runner. A bare `REGENERATE_GOLDENS=1` is silently ignored.
//
//  Read the diff before committing it. A golden regenerated without being read is worth nothing.
//

import XCTest
@testable import MangaCarta

final class RecommendationGoldenTests: XCTestCase {

    // MARK: - Synthetic fixture

    // The fixture literals are column-aligned so they can be read as the tables they represent;
    // that is the whole point of a hand-traceable fixture. Alignment padding trips `colon` and
    // `comma`, so those two rules are off for this block only.
    // swiftlint:disable colon comma

    /// Tag feeds keyed by tag *name* (what `TagCandidateProvider` queries with), in rank order.
    /// Position matters: provenance scoring weights by `1 / (1 + position)`.
    private static let tagFeeds: [String: [String]] = [
        "Action":  ["A", "B", "C", "D", "Z"],
        "Romance": ["C", "E", "F"],
        "Isekai":  ["B", "G"],
        // Tie-break fixtures, used only by the tie-break tests — never queried by the main
        // profile, which has only the three tags above. Deliberately listed b-then-a so that
        // "id ascending" is not the same as "insertion order".
        "TieX":    ["tie-b"],
        "TieY":    ["tie-a"],
    ]

    /// Per-seed MAL recommendation lists, in rank order.
    private static let malRecs: [String: [String]] = [
        "seed-berserk": ["C", "H", "A"],
        "seed-vinland": ["I", "C"],
        // Tie-break fixtures; not reachable from the main profile's two seeds.
        "seed-tie-1":   ["tie-b"],
        "seed-tie-2":   ["tie-a"],
    ]

    /// Display titles, so the golden reads like a rail and not like a hash dump.
    private static let titles: [String: String] = [
        "A": "Alpha Blade",       "B": "Blue Sentinel",   "C": "Crimson Vow",
        "D": "Dawnbreaker",       "E": "Everlight",       "F": "Fallow Season",
        "G": "Gilded Cage",       "H": "Hollow Court",    "I": "Ivory Requiem",
        "J": "Jade Lantern",
        "Z": "Zenith (excluded)",
        "tie-a": "Tie Alpha",     "tie-b": "Tie Beta",
    ]

    // swiftlint:enable colon comma

    /// Titles the user has already read/saved/dismissed — must never appear in the output.
    private static let excluded: Set<String> = ["Z"]

    /// Built directly rather than via `TasteProfile.build` so every weight in the golden is a
    /// stated input rather than a derived one. Profile *construction* (recency half-life,
    /// engagement weighting, seed materialization) is covered by its own unit tests; this
    /// harness isolates the *ranking*.
    private static func makeProfile() -> TasteProfile {
        let weights = ["t-action": 1.0, "t-romance": 0.7, "t-isekai": 0.4]
        let names = ["t-action": "Action", "t-romance": "Romance", "t-isekai": "Isekai"]
        return TasteProfile(
            weights: weights,
            tagName: names,
            orderedTagKeys: weights.sorted { $0.value > $1.value }.map(\.key),
            taggedMangaCount: 6,
            seeds: [
                SeedManga(manga: manga("seed-berserk", title: "Berserk"), weight: 3.0),
                SeedManga(manga: manga("seed-vinland", title: "Vinland Saga"), weight: 1.2),
            ]
        )
    }

    private static func manga(_ id: String, title: String? = nil) -> Manga {
        Manga(id: id, sourceId: "mangadex", title: title ?? titles[id] ?? id,
              description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
    }

    /// Serves the canned tag feeds. Only `mangaByTag` is exercised.
    private struct FixtureSource: MangaSource {
        let id = "fixture"
        let name = "Fixture"
        var supportsTagBrowse: Bool { true }

        func mangaByTag(tag: String, limit: Int, offset: Int) async throws -> [Manga] {
            (RecommendationGoldenTests.tagFeeds[tag] ?? []).prefix(limit).map {
                RecommendationGoldenTests.manga($0)
            }
        }
        func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
        func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
        func mangaDetail(id: String) async throws -> MangaDetail {
            MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
        }
        func chapters(mangaId: String) async throws -> [Chapter] { [] }
        func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
    }

    /// Serves the canned MAL recommendation lists, keyed by seed id.
    private struct FixtureSimilar: SimilarTitlesProviding {
        func recommendations(for manga: Manga, limit: Int) async -> [Manga] {
            (RecommendationGoldenTests.malRecs[manga.id] ?? [])
                .prefix(limit)
                .map { RecommendationGoldenTests.manga($0) }
        }
    }

    // MARK: - The golden test

    // `SimilarTitlesProviding` is @MainActor, so anything that constructs `FixtureSimilar` must
    // be too. Isolation is applied per-member rather than to the whole class on purpose: the
    // static fixtures must stay nonisolated so `FixtureSource` (a plain, nonisolated
    // `MangaSource`) can read them from its async methods.
    @MainActor
    func testForYouBlendRankingGolden() async throws {
        let rendered = try await renderRanking()
        try assertMatchesGolden(rendered, named: "foryou-ranking.txt")
    }

    // MARK: - Agreement semantics

    /// A pool of pre-scored candidates, for asserting blend behaviour directly.
    private struct StubPool: CandidateProvider {
        let items: [ScoredManga]
        func candidates(for profile: TasteProfile,
                        excluding: Set<String>, limit: Int) async throws -> [ScoredManga] { items }
    }

    /// The point of the geometric agreement term: a title ranked mid-pack in *both* pools must
    /// not outrank a title ranked at the top of *one*. Under the flat `+0.25` this failed —
    /// "mid" scored 0.37 + 0.85·0.37 + 0.25 = 0.9345 and came second, ahead of "maltop" at 0.85,
    /// because a flat 0.25 is enormous against scores that live in [0, 1]. With
    /// 0.25·sqrt(0.37·0.37) = 0.0925 it scores 0.7770 and lands where its strength says it should.
    ///
    /// This is deliberately a behaviour test rather than a golden: the main fixture has no title
    /// sitting in the window where the old rule flipped an ordering, so its golden shows the
    /// change in margins but not in rank.
    @MainActor
    func testAgreementDoesNotPromoteMidRankedTitleOverStrongSingleSignal() async throws {
        func scored(_ id: String, _ score: Double) -> ScoredManga {
            ScoredManga(manga: Self.manga(id, title: id), score: score, reason: "r")
        }
        let composite = CompositeCandidateProvider(
            tag: StubPool(items: [scored("strong", 1.0), scored("mid", 0.37)]),
            mal: StubPool(items: [scored("maltop", 1.0), scored("mid", 0.37)]))

        let blended = try await composite.candidates(
            for: Self.makeProfile(), excluding: [], limit: 10)

        XCTAssertEqual(blended.map(\.manga.id), ["strong", "maltop", "mid"])
        XCTAssertEqual(blended[2].score, 0.7770, accuracy: 1e-4)
    }

    // MARK: - Tie-break regression tests
    //
    // The sub-providers now break exactly-tied scores on manga id, matching what
    // CompositeCandidateProvider has done since 5fb47f9. Without it, tied candidates come out in
    // whatever order Swift's (unstable) sort produced from a dictionary whose iteration order is
    // randomized per process — so the rail could reorder between launches, and a tie straddling
    // `limit` could change which titles were in the pool at all.

    /// Two tags of equal weight, each surfacing one distinct title at position 0, produce two
    /// exactly-tied scores. The tie must resolve id-ascending, every time.
    @MainActor
    func testTagProviderBreaksTiesOnIdAscending() async throws {
        let profile = TasteProfile(
            weights: ["t-x": 1.0, "t-y": 1.0],
            tagName: ["t-x": "TieX", "t-y": "TieY"],
            orderedTagKeys: ["t-x", "t-y"],
            taggedMangaCount: 3,
            seeds: []
        )
        let pool = try await tagProvider().candidates(for: profile, excluding: [], limit: 10)

        XCTAssertEqual(pool.map(\.manga.id), ["tie-a", "tie-b"])
        XCTAssertEqual(pool[0].score, pool[1].score, accuracy: 1e-12,
                       "fixture bug: these candidates are supposed to tie")
    }

    /// Same property for the MAL pool: two equally-weighted seeds each recommending one distinct
    /// title at position 0.
    @MainActor
    func testMALProviderBreaksTiesOnIdAscending() async throws {
        let profile = TasteProfile(
            weights: ["t-x": 1.0], tagName: ["t-x": "TieX"], orderedTagKeys: ["t-x"],
            taggedMangaCount: 3,
            seeds: [
                SeedManga(manga: Self.manga("seed-tie-1", title: "Tie Seed One"), weight: 2.0),
                SeedManga(manga: Self.manga("seed-tie-2", title: "Tie Seed Two"), weight: 2.0),
            ]
        )
        let pool = try await malProvider().candidates(for: profile, excluding: [], limit: 10)

        XCTAssertEqual(pool.map(\.manga.id), ["tie-a", "tie-b"])
        XCTAssertEqual(pool[0].score, pool[1].score, accuracy: 1e-12,
                       "fixture bug: these candidates are supposed to tie")
    }

    /// Guards the main fixture's no-ties invariant. Now that ties are broken deterministically
    /// this is belt-and-braces rather than load-bearing, but a tied main fixture would still make
    /// the golden depend on tie-break behaviour instead of on the blend it is meant to document.
    @MainActor
    func testFixtureProducesNoTiedScores() async throws {
        let tagPool = try await tagProvider().candidates(for: Self.makeProfile(),
                                                         excluding: Self.excluded, limit: 20)
        let malPool = try await malProvider().candidates(for: Self.makeProfile(),
                                                         excluding: Self.excluded, limit: 20)
        let aniPool = try await aniProvider().candidates(for: Self.makeProfile(),
                                                         excluding: Self.excluded, limit: 20)
        for (label, pool) in [("tag", tagPool), ("mal", malPool), ("ani", aniPool)] {
            let scores = pool.map { ($0.score * 1e9).rounded() }
            XCTAssertEqual(Set(scores).count, scores.count,
                           "\(label) pool has tied scores — sub-providers have no stable "
                           + "tie-break, so the golden can reorder between runs")
        }
    }

    // MARK: - Rendering

    private func tagProvider() -> TagCandidateProvider {
        TagCandidateProvider(source: FixtureSource(), topK: 6, perTagLimit: 20)
    }

    @MainActor
    private func malProvider() -> MALCandidateProvider {
        MALCandidateProvider(similar: FixtureSimilar(), perSeedLimit: 8)
    }

    /// The AniList pool, as a `StubPool` of hand-chosen scores rather than a real
    /// `AniListCandidateProvider`.
    ///
    /// The golden's job is the *blend* — its tuning constants and the shape of the agreement
    /// term — and the fixture principle is that every number in the file is derivable with a
    /// calculator (see the header). A real provider would put `withinPool` arithmetic, two
    /// cache TTLs, and a read-through that returns empty on first call into the golden's
    /// blast radius, making it a worse instrument, not a better one. Everything it would add
    /// is already pinned deterministically by `AniListPoolTests`; the wire between the real
    /// provider and this composite is covered by `testTheAniListPoolReachesTheComposite`
    /// there.
    ///
    private func aniProvider() -> StubPool {
        StubPool(items: Self.aniScores.map { id, score, reason in
            ScoredManga(manga: Self.manga(id), score: score, reason: reason)
        })
    }

    /// `(id, raw score, reason)`. Raw, not normalized — the composite divides by this pool's
    /// own max, exactly as it does for the live one.
    ///
    /// Four cases, each chosen to make one decision visible in the golden:
    ///
    /// - **C, Crimson Vow** — already in *both* other pools, so it is the only row where the
    ///   agreement term runs at `n = 3`. This is where the rejected pairwise-sum alternative
    ///   would have differed: three terms would have paid up to `3 × agreementBonus`, and the
    ///   geometric mean pays 0.25 exactly once. C also tops all three pools, which is the
    ///   only configuration that earns the full bonus.
    /// - **A, Alpha Blade** — deliberately *absent* here. It is in tag + MAL only, so its
    ///   `agree` and `final` must stay byte-identical to the two-pool era. It is the control.
    /// - **J, Jade Lantern** — AniList-only, so `wAniList = 0.6` is visible in isolation with
    ///   no agreement term at all.
    /// - **B, Blue Sentinel** — tag + AniList. Its reason must flip from `"More Action"` to
    ///   the AniList conjunction (precedence: tag < AniList), while C's must stay
    ///   `"Because you read Berserk"` despite AniList contributing (AniList < MAL). Those two
    ///   rows pin the whole precedence rule in the golden rather than only in a unit test.
    ///   B also overtakes A once the third pool contributes — the first ranking change the
    ///   AniList pool causes, and the reason this fixture is worth reading.
    ///
    /// Scores are chosen to preserve the no-ties invariant stated in the header; the closest
    /// pair after blending is B at 1.4117 against A at 1.3335.
    private static let aniScores: [(String, Double, String)] = [
        ("C", 2.300, "More Dungeon + Necromancy"),
        ("B", 1.380, "More Demons + Magic"),
        ("J", 1.035, "More Dungeon + Revenge"),
    ]

    /// Renders the ranking as a fixed-width table.
    ///
    /// The `final` and `reason` columns come from `CompositeCandidateProvider` — the system
    /// under test. The `tagNorm` / `malNorm` / `agree` columns are re-derived here from the two
    /// sub-pools, so they are *observed inputs*, not restatements of the implementation. If the
    /// composite's formula changes, `final` moves while the component columns hold still, and
    /// the diff shows precisely what the new formula did.
    @MainActor
    private func renderRanking() async throws -> String {
        let profile = Self.makeProfile()
        let composite = CompositeCandidateProvider(tag: tagProvider(),
                                                   mal: malProvider(),
                                                   ani: aniProvider())

        let blended = try await composite.candidates(for: profile,
                                                     excluding: Self.excluded, limit: 20)
        let tagNorm = Self.normalized(
            try await tagProvider().candidates(for: profile, excluding: Self.excluded, limit: 20))
        let malNorm = Self.normalized(
            try await malProvider().candidates(for: profile, excluding: Self.excluded, limit: 20))
        let aniNorm = Self.normalized(
            try await aniProvider().candidates(for: profile, excluding: Self.excluded, limit: 20))

        var out = """
        For You — blended candidate ranking (synthetic fixture)

        Generated by RecommendationGoldenTests. Do not hand-edit; regenerate with
        TEST_RUNNER_REGENERATE_GOLDENS=1 and read the diff.

        weights: wTag=\(fmt(composite.wTag)) wAniList=\(fmt(composite.wAniList)) \
        wMal=\(fmt(composite.wMal)) agreementBonus=\(fmt(composite.agreementBonus))
          (read off the provider under test, so this line can never disagree with the code)

        tagNorm / aniNorm / malNorm : each pool's score divided by that pool's own maximum.
        agree : the agreement bonus actually applied — agreementBonus·(∏ contributing)^(1/n)
                over the pools that scored the title, so it is 0 for a single-pool title and
                reduces to sqrt(a·b) when exactly two contribute.
        final : CompositeCandidateProvider's output score.


        """

        out += Self.pad("rank", 5) + Self.pad("title", 22) + Self.pad("tagNorm", 9)
            + Self.pad("aniNorm", 9) + Self.pad("malNorm", 9)
            + Self.pad("agree", 8) + Self.pad("final", 9) + "reason\n"
        out += String(repeating: "-", count: 105) + "\n"

        for (i, c) in blended.enumerated() {
            let t = tagNorm[c.manga.id]
            let a = aniNorm[c.manga.id]
            let m = malNorm[c.manga.id]
            // Whatever the composite added beyond the weighted sum of the three pools. Uses
            // the provider's OWN weights, not literals — deriving this with hardcoded
            // 1.0/0.6/0.85 makes the column silently wrong the moment someone tunes a weight,
            // which is exactly when the column matters most.
            let agree = c.score - (t ?? 0) * composite.wTag
                - (a ?? 0) * composite.wAniList - (m ?? 0) * composite.wMal
            out += Self.pad(String(i + 1), 5)
                + Self.pad(c.manga.title, 22)
                + Self.pad(t.map { String(format: "%.4f", $0) } ?? "-", 9)
                + Self.pad(a.map { String(format: "%.4f", $0) } ?? "-", 9)
                + Self.pad(m.map { String(format: "%.4f", $0) } ?? "-", 9)
                + Self.pad(String(format: "%.4f", agree), 8)
                + Self.pad(String(format: "%.4f", c.score), 9)
                + c.reason + "\n"
        }

        out += "\nexcluded (already read/saved/dismissed): "
            + Self.excluded.sorted().map { Self.titles[$0] ?? $0 }.joined(separator: ", ") + "\n"
        return out
    }

    private static func normalized(_ pool: [ScoredManga]) -> [String: Double] {
        guard let max = pool.map(\.score).max(), max > 0 else { return [:] }
        return Dictionary(pool.map { ($0.manga.id, $0.score / max) },
                          uniquingKeysWith: { first, _ in first })
    }

    private func fmt(_ d: Double) -> String { String(format: "%g", d) }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - Golden file plumbing

    /// Goldens live next to their test file and are resolved from `#filePath`, so no Xcode
    /// resource-bundle wiring is needed — `MangaCartaTests` is a plain PBXGroup, not a
    /// synchronized one, and adding bundled resources to it would mean hand-editing pbxproj.
    private func assertMatchesGolden(_ actual: String, named name: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let dir = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .appendingPathComponent("__Goldens__")
        let url = dir.appendingPathComponent(name)
        let fm = FileManager.default

        if ProcessInfo.processInfo.environment["REGENERATE_GOLDENS"] == "1" {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            XCTFail("Golden '\(name)' did not exist — wrote it. Review it, then re-run.",
                    file: file, line: line)
            return
        }

        if actual != expected {
            XCTFail("""
                Golden '\(name)' mismatch. If this change is intended, regenerate with \
                TEST_RUNNER_REGENERATE_GOLDENS=1 and review the diff.

                --- expected ---
                \(expected)
                --- actual ---
                \(actual)
                """, file: file, line: line)
        }
    }
}
