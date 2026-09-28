# Mixed-Source Title Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Installed `mixed` Sources are visible by default; the adult switch hides `erotica`/`pornographic` titles from discovery instead of hiding whole Sources.

**Architecture:**
- One pure predicate, `AdultContentFilter.admits`, decides whether a title may appear in discovery.
- It is applied at two points, and no view checks it:
  - `ExtensionSource`'s five listing methods, which covers every live feed, search and tag browse;
  - `SourceRegistry.admitsForDiscovery`, which covers the recommendation outputs. Those resolve titles through `manga(id:)` and a persisted pool, so the listing filter never sees them.
- Whole-Source hiding (`isNSFW`) narrows to `adultOnly` plus the reader's "Treat as adult" elevation. A new `declaresAdultTitles` flag carries "this Source said it has adult titles".

**Tech Stack:** Swift 6.0-compatible Swift, SwiftUI, XCTest and Swift Testing, `xcodebuild`, `xcp`.

**Spec:** `docs/adr/0022-no-adult-source-in-the-release-build.md`, Amendment 6 (PR #262).

## Global Constraints

- CI builds with Xcode 16.4 / Swift 6.0. Do not use isolated conformances, `nonisolated(nonsending)`, `@concurrent` or `Task.immediate`.
- Every `xcodebuild` uses `-destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691'` with parallel testing left on.
- New files in `MangaCartaTests/` need `xcp add-file "$PWD/MangaCarta.xcodeproj" --file "$PWD/MangaCartaTests/<File>.swift" --targets MangaCartaTests`. Inside `/private/tmp`, pass the `/tmp/...` spelling of the path. `Models/` and `Services/` are synchronized groups and need nothing.
- Check `git diff --stat -- MangaCarta.xcodeproj` right before every `git add`.
- **The persisted key stays `settings.showAdultSources`.** Only the label changes, to "Show adult content", so readers who turned it on keep it on.
- The adult ratings are exactly `erotica` and `pornographic`. `suggestive` and `safe` always pass.
- Library, history and new-chapter notifications are never filtered.
- `MangaSource` stays bridge-friendly. The new requirement is a `Bool` with a default.
- End every commit message with the repository's attribution lines.

## Review Focus

1. **The reader flips the switch while Home or Search is on screen.** Rails and results must refetch, not keep showing what the old setting allowed. Task 6 adds the `onChange` handlers.
2. **A saved adult title while the switch is off.** It must still open, refresh and resolve to MAL. `manga(id:)`, `chapters` and `mangaDetail` stay unfiltered, and `MALEntityResolver` gets an unfiltered search (Task 4).
3. **A recommendation from an uninstalled Source, or from a whole-Source-hidden one.** It must be rejected: `admitsForDiscovery` fails closed on an unknown Source (Task 5).
4. **Only `adultOnly` Sources installed, switch off.** `active` must be nil and Home must show its no-Source state, not the adult Source (Task 3).
5. **A feed page whose every title is adult.** `PagedMangaLoader` ends a feed on an empty page, so an all-adult page ends that feed while the switch is off. This is accepted, since the rest of such a feed would mostly be hidden too. Task 4 pins it with a test so the choice stays visible.

---

### Task 1: The predicate and the setting accessor

**Files:**
- Create: `MangaCarta/Models/AdultContentFilter.swift`
- Create: `MangaCartaTests/AdultContentFilterTests.swift` (register it with `xcp`)

**Interfaces:**
- Produces: `enum AdultContentFilter { static func admits(rating: String?, sourceDeclaresAdultTitles: Bool, showAdultContent: Bool) -> Bool }`
- Produces: `enum AdultContentSetting { static let key: String; static func current() -> Bool }`, where `current` reads `UserDefaults.standard`. It is nonisolated and `@Sendable`-safe.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MangaCarta

@Suite("AdultContentFilter")
struct AdultContentFilterTests {
    @Test(arguments: ["erotica", "pornographic"])
    func adultRatingsAreHiddenWhenTheSwitchIsOff(rating: String) {
        #expect(!AdultContentFilter.admits(rating: rating, sourceDeclaresAdultTitles: false, showAdultContent: false))
        #expect(!AdultContentFilter.admits(rating: rating, sourceDeclaresAdultTitles: true, showAdultContent: false))
    }

    @Test(arguments: ["safe", "suggestive"])
    func generalRatingsAlwaysPass(rating: String) {
        #expect(AdultContentFilter.admits(rating: rating, sourceDeclaresAdultTitles: true, showAdultContent: false))
    }

    @Test func unratedTitleFollowsTheSourcesDeclaration() {
        #expect(!AdultContentFilter.admits(rating: nil, sourceDeclaresAdultTitles: true, showAdultContent: false))
        #expect(AdultContentFilter.admits(rating: nil, sourceDeclaresAdultTitles: false, showAdultContent: false))
    }

    @Test func switchOnAdmitsEverything() {
        #expect(AdultContentFilter.admits(rating: "pornographic", sourceDeclaresAdultTitles: true, showAdultContent: true))
        #expect(AdultContentFilter.admits(rating: nil, sourceDeclaresAdultTitles: true, showAdultContent: true))
    }

    @Test func settingKeyIsThePersistedOne() {
        // Renaming the key would silently switch adult content off for every reader who had it on.
        #expect(AdultContentSetting.key == "settings.showAdultSources")
        #expect(AdultContentSetting.key == RepositorySettingsViewModel.showAdultSourcesKey)
    }
}
```

- [ ] **Step 2: Register the test file and run it to verify it fails**

```sh
xcp add-file "$PWD/MangaCarta.xcodeproj" --file "$PWD/MangaCartaTests/AdultContentFilterTests.swift" --targets MangaCartaTests
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/AdultContentFilterTests
```

Expected: build failure, "cannot find 'AdultContentFilter' in scope".

- [ ] **Step 3: Implement**

```swift
//
//  AdultContentFilter.swift
//  MangaCarta
//
//  Whether a title may appear in discovery (ADR-0022 Amendment 6). With the switch off,
//  `erotica` and `pornographic` titles are hidden from every Source. An unrated title
//  is settled by its Source's own declaration: a `mixed` Source said it carries adult
//  titles, so its unknowns are hidden; a `none` Source vouched for all of its titles.
//

import Foundation

enum AdultContentFilter {
    static let adultRatings: Set<String> = ["erotica", "pornographic"]

    static func admits(rating: String?, sourceDeclaresAdultTitles: Bool, showAdultContent: Bool) -> Bool {
        if showAdultContent { return true }
        guard let rating else { return !sourceDeclaresAdultTitles }
        return !adultRatings.contains(rating)
    }
}

/// The reader's "Show adult content" switch. The key predates the rename and is kept so
/// that turning the switch on survives the upgrade.
enum AdultContentSetting {
    static let key = "settings.showAdultSources"

    @Sendable static func current() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
```

Then point `RepositorySettingsViewModel.showAdultSourcesKey` at it:

```swift
static let showAdultSourcesKey = AdultContentSetting.key
```

- [ ] **Step 4: Run the test to verify it passes.** Use the same command as Step 2. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add MangaCarta/Models/AdultContentFilter.swift MangaCarta/Models/RepositorySettingsViewModel.swift MangaCartaTests/AdultContentFilterTests.swift MangaCarta.xcodeproj/project.pbxproj
git commit -m "feat(adult): add the discovery title predicate (ADR-0022 A6)"
```

---

### Task 2: Split "hidden whole" from "declares adult titles"

**Files:**
- Modify: `MangaCarta/Models/MangaSource.swift` (protocol near `isNSFW`, line 24; default extension near line 125)
- Modify: `MangaCarta/Models/ExtensionSource.swift:116-131`
- Modify: `MangaCarta/Services/ExtensionSourceRegistrar.swift:79-91`
- Modify: `MangaCarta/Services/SourceRegistry.swift`, `hasAdultSource`
- Test: `MangaCartaTests/ExtensionSourceTests.swift`, class `InstalledSourceRegistrationTests`

**Interfaces:**
- Produces: `MangaSource.declaresAdultTitles: Bool`, defaulting to `false`.
- Produces: `ExtensionSource.init(declaration:script:isNSFW:lifecycle:host:declaresAdultTitles: Bool = false, showAdultContent: @escaping @Sendable () -> Bool = AdultContentSetting.current)`. The new parameters are last and defaulted, so no existing construction site changes. Task 4 uses `showAdultContent`.
- Produces: `SourceRegistry.hasAdultSource == sources.contains { $0.isNSFW || $0.declaresAdultTitles }`

- [ ] **Step 1: Find the existing tests that encode the old meaning**

```sh
grep -n "isNSFW\|adult" MangaCartaTests/ExtensionSourceTests.swift MangaCartaTests/*Registrar* MangaCartaTests/*Repository* | grep -i "mixed\|isNSFW"
```

Any assertion that a `mixed` install is `isNSFW == true` is now wrong by the spec. Change it to the new expectation in Step 2, and cite ADR-0022 A6 in its comment. Do not delete it.

- [ ] **Step 2: Write the failing tests.** Add them to `InstalledSourceRegistrationTests` and reuse that class's existing install helper. Read the class first: it installs through `FakeRepositoryTransport` with a declaration JSON whose `"adult"` field you can set.

```swift
/// ADR-0022 A6: a `mixed` Source is visible; only its adult titles are filtered.
func testAMixedInstallIsNotHiddenWholeButDeclaresAdultTitles() async throws {
    let source = try await installedSource(adult: "mixed")   // the class's install helper
    XCTAssertFalse(source.isNSFW)
    XCTAssertTrue(source.declaresAdultTitles)
    XCTAssertTrue(registry.hasAdultSource)
    XCTAssertTrue(registry.visibleSources(includeAdult: false).contains { $0.id == source.id })
}

func testAnAdultOnlyInstallIsHiddenWhole() async throws {
    let source = try await installedSource(adult: "adultOnly")
    XCTAssertTrue(source.isNSFW)
    XCTAssertTrue(source.declaresAdultTitles)
    XCTAssertFalse(registry.visibleSources(includeAdult: false).contains { $0.id == source.id })
}

/// "Treat as adult" is the reader calling the Source adult; it still hides it whole.
func testALocalElevationHidesTheSourceWhole() async throws {
    let source = try await installedSource(adult: "none", elevated: true)
    XCTAssertTrue(source.isNSFW)
    XCTAssertTrue(source.declaresAdultTitles)
}
```

If the class has no helper that takes `adult:` and `elevated:`, extract one from the nearest existing install test in the same class, and keep it private to the class.

- [ ] **Step 3: Run them to verify they fail**

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/InstalledSourceRegistrationTests
```

Expected: the compile fails on `declaresAdultTitles`.

- [ ] **Step 4: Implement**

In `MangaSource.swift`, add this to the protocol under `isNSFW`:

```swift
    /// The Source declared that some of its titles are adult (`mixed`, `adultOnly`, or a
    /// reader's elevation). Decides how an unrated title is treated (ADR-0022 A6).
    var declaresAdultTitles: Bool { get }
```

Add this to the default extension:

```swift
    var declaresAdultTitles: Bool { false }
```

In `ExtensionSource.swift`, replace the `isNSFW` doc comment and add the stored properties:

```swift
    /// Hidden whole while the adult switch is off: `adultOnly`, or the reader's local
    /// elevation (ADR-0022 A6). A `mixed` Source is visible and only its titles filter.
    let isNSFW: Bool
    /// Effective class ≠ `none` (repository format design §7.2).
    let declaresAdultTitles: Bool
    /// Read at call time, so flipping the switch takes effect on the next fetch.
    private let showAdultContent: @Sendable () -> Bool
```

Extend `init` with `declaresAdultTitles: Bool = false, showAdultContent: @escaping @Sendable () -> Bool = AdultContentSetting.current` after `host:`, and assign both.

In `ExtensionSourceRegistrar.swift`, replace lines 79-81 and the reuse check:

```swift
            // ADR-0022 A6: `mixed` is visible and filters its titles; `adultOnly`, or the
            // reader's elevation, hides the Source whole.
            let elevated = record.localAdultElevation != nil
            let isNSFW = declaration.adult == .adultOnly || elevated
            let declaresAdultTitles = declaration.adult != .none || elevated
```

Add `existing.declaresAdultTitles == declaresAdultTitles` to the `if let existing` condition, and pass `declaresAdultTitles: declaresAdultTitles` to the `ExtensionSource(...)` call.

In `SourceRegistry.swift`:

```swift
    var hasAdultSource: Bool {
        sources.contains { $0.isNSFW || $0.declaresAdultTitles }
    }
```

Update its doc comment: the switch now appears for a `mixed` Source too, which is how it was before, and it now hides titles.

- [ ] **Step 5: Run the test to verify it passes.** Use the same command as Step 3, then the full `MangaCartaTests` target. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A MangaCarta MangaCartaTests
git commit -m "feat(adult): mixed Sources are visible; adultOnly and elevation hide whole"
```

---

### Task 3: The active browse Source respects the switch

**Files:**
- Modify: `MangaCarta/Services/SourceRegistry.swift` (`init`, `active`, `firstBrowsable`)
- Test: `MangaCartaTests/SourceRegistryTests.swift`

**Interfaces:**
- Produces: `SourceRegistry.init(sources: [MangaSource]? = nil, showAdultContent: @escaping () -> Bool = AdultContentSetting.current)`

- [ ] **Step 1: Write the failing tests**

```swift
private struct StubSource: MangaSource {
    let id: String
    var name: String { id }
    var isNSFW = false
    var declaresAdultTitles = false
    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] { [] }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

@Test func onlyAnAdultOnlySourceAndSwitchOffMeansNoActiveSource() {
    let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "a", isNSFW: true)],
                                  showAdultContent: { false })
    #expect(registry.active == nil)
}

@Test func onlyAnAdultOnlySourceAndSwitchOnMakesItActive() {
    let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "a", isNSFW: true)],
                                  showAdultContent: { true })
    #expect(registry.active?.id == "a")
}

@Test func aStoredAdultOnlyChoiceIsNotHonouredWhileTheSwitchIsOff() {
    var show = true
    let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "safe"), StubSource(id: "a", isNSFW: true)],
                                  showAdultContent: { show })
    registry.activeSourceID = "a"
    show = false
    #expect(registry.active?.id == "safe")
}

@Test func aMixedSourceIsActiveWithTheSwitchOff() {
    let registry = SourceRegistry(sources: [LocalSource(), StubSource(id: "m", declaresAdultTitles: true)],
                                  showAdultContent: { false })
    #expect(registry.active?.id == "m")
}
```

Check `MangaSource` for other requirements that have no default, and add them to `StubSource` if the compiler asks.

- [ ] **Step 2: Run them to verify they fail**

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/SourceRegistryTests
```

Expected: the compile fails on `showAdultContent:`.

- [ ] **Step 3: Implement**

```swift
    private let showAdultContent: () -> Bool

    init(sources: [MangaSource]? = nil, showAdultContent: @escaping () -> Bool = AdultContentSetting.current) {
        self.showAdultContent = showAdultContent
        // ... existing body unchanged ...
    }

    /// Browsable now: a Source hidden whole is out while the adult switch is off (ADR-0022 A6).
    private func isBrowsableNow(_ source: MangaSource) -> Bool {
        source.isBrowsable && (!source.isNSFW || showAdultContent())
    }

    var active: MangaSource? {
        source(id: activeSourceID).flatMap { isBrowsableNow($0) ? $0 : nil } ?? firstBrowsable
    }

    /// The fallback browse Source. It never picks one that is hidden whole while the switch
    /// is off; if nothing else is eligible there is no active Source (ADR-0022 A6, point 7).
    private var firstBrowsable: MangaSource? {
        sources.first(where: isBrowsableNow)
    }
```

`showAdultContent` must be assigned before any use in `init`. Assign it first, as shown.

- [ ] **Step 4: Run the tests to verify they pass.** Use the Step 2 command, then the whole `MangaCartaTests` target.

- [ ] **Step 5: Commit**

```bash
git add MangaCarta/Services/SourceRegistry.swift MangaCartaTests/SourceRegistryTests.swift
git commit -m "fix(registry): never fall back to a hidden adult Source (ADR-0022 A6)"
```

---

### Task 4: `ExtensionSource` filters its listings

**Files:**
- Modify: `MangaCarta/Models/ExtensionSource.swift`, `latestUpdates` and `listings` (lines ~220-243)
- Modify: `MangaCarta/Services/SourceRegistry.swift` (add `externalIdResolutionSource`)
- Modify: `MangaCarta/Services/AppComposition.swift:260-262`
- Create: `MangaCartaTests/AdultListingFilterTests.swift` (register it with `xcp`)

**Interfaces:**
- Consumes: `AdultContentFilter.admits` (Task 1); `ExtensionSource.declaresAdultTitles` and `showAdultContent` (Task 2).
- Produces: `ExtensionSource.unfilteredForResolution() -> ExtensionSource`, the same Source with `showAdultContent` fixed to `true`.
- Produces: `SourceRegistry.externalIdResolutionSource: MangaSource?`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MangaCarta

/// ADR-0022 A6: an installed Source's discovery results are filtered by title rating.
@MainActor
final class AdultListingFilterTests: XCTestCase {
    private static let id = "6f1d9c2e-4b7a-4c1e-9e3d-2a8b5c7d1f00:rated"
    private var lifecycle: SourceLifecycleRegistry!

    override func setUp() {
        super.setUp()
        lifecycle = SourceLifecycleRegistry()
    }

    /// Every page carries one title per rating, plus one unrated title.
    private func rated(adult: String, declares: Bool, show: Bool) throws -> ExtensionSource {
        let script = """
        registerEngine("rated", {
          invoke: function (operation, request, context) {
            var items = [
              { id: "safe", title: "S", contentRating: "safe" },
              { id: "sugg", title: "G", contentRating: "suggestive" },
              { id: "ero", title: "E", contentRating: "erotica" },
              { id: "porn", title: "P", contentRating: "pornographic" },
              { id: "none", title: "U" }
            ];
            if (operation === "latestUpdates") {
              items = items.map(function (l) { return { chapterId: "c-" + l.id, listing: l }; });
            }
            return { ok: true, value: { items: items, nextCursor: null, exhausted: true } };
          }
        });
        """
        let declaration = try PortFixtures.declaration("""
        {
          "localId": "rated", "name": "Rated", "engine": "rated", "adult": "\(adult)",
          "capabilities": { "search": true, "popular": true, "newTitles": true, "latestUpdates": true,
                            "tagBrowse": true, "detail": true, "chapters": true, "pages": true },
          "languages": { "mode": "fixed", "values": ["en"] },
          "network": { "httpOrigins": [], "browserOrigins": [], "assetOrigins": [] },
          "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" },
          "configuration": {}
        }
        """, qualifiedId: Self.id)
        try lifecycle.register(declaration)
        return ExtensionSource(declaration: declaration, script: script, isNSFW: false,
                               lifecycle: lifecycle, host: FixtureSourceHost(site: PortFixtures.weebCentralSite),
                               declaresAdultTitles: declares, showAdultContent: { show })
    }

    func testMixedSwitchOffHidesAdultAndUnratedEverywhere() async throws {
        let source = try rated(adult: "mixed", declares: true, show: false)
        let expected = ["safe", "sugg"]
        let search = try await source.search(title: "x", limit: 20, offset: 0).map(\.id)
        let popular = try await source.popular(limit: 20, offset: 0).map(\.id)
        let newTitles = try await source.newTitles(limit: 20, offset: 0).map(\.id)
        let tag = try await source.mangaByTag(tag: "t", limit: 20, offset: 0).map(\.id)
        let latest = try await source.latestUpdates(limitTitles: 20, language: "en", offset: 0).map(\.manga.id)
        XCTAssertEqual(search, expected)
        XCTAssertEqual(popular, expected)
        XCTAssertEqual(newTitles, expected)
        XCTAssertEqual(tag, expected)
        XCTAssertEqual(latest, expected)
    }

    func testNoneSourceSwitchOffKeepsUnratedButHidesAdultLabelledListings() async throws {
        let source = try rated(adult: "none", declares: false, show: false)
        let ids = try await source.popular(limit: 20, offset: 0).map(\.id)
        XCTAssertEqual(ids, ["safe", "sugg", "none"])
    }

    func testSwitchOnReturnsEverything() async throws {
        let source = try rated(adult: "mixed", declares: true, show: true)
        let ids = try await source.popular(limit: 20, offset: 0).map(\.id)
        XCTAssertEqual(ids.count, 5)
    }

    /// Review Focus 2: resolving a saved adult title to MAL must not be filtered.
    func testTheResolutionCopyIsUnfiltered() async throws {
        let source = try rated(adult: "mixed", declares: true, show: false)
        let ids = try await source.unfilteredForResolution().search(title: "x", limit: 20, offset: 0).map(\.id)
        XCTAssertEqual(ids.count, 5)
    }
}
```

Fixture checks, to do before running:
- The `latestUpdates` item shape, `{ chapterId, listing }`, must match `validateUpdatePage` in `ExtensionDomainSchemas.swift`. Read it and adjust the script if the key names differ.
- If any capability name above is not in `SourceOperation`, correct it.
- If the validator rejects a Listing with no `contentRating`, the "unrated" item needs whatever minimal form the validator accepts. Do not change the validator.

- [ ] **Step 2: Register the file and run to verify it fails**

```sh
xcp add-file "$PWD/MangaCarta.xcodeproj" --file "$PWD/MangaCartaTests/AdultListingFilterTests.swift" --targets MangaCartaTests
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/AdultListingFilterTests
```

Expected: the compile fails on `unfilteredForResolution`. Once that stub exists, the assertions fail with all 5 ids returned.

- [ ] **Step 3: Implement.** In `ExtensionSource.swift`:

```swift
    func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] {
        // ... existing body up to `page` unchanged ...
        return page.map { $0.toMangaUpdate(sourceID: id) }.filter { admits($0.manga) }
    }

    private func listings(/* unchanged signature */) async throws -> [Manga] {
        // ... existing body unchanged ...
        return page.map { $0.toManga(sourceID: id) }.filter(admits)
    }

    /// Discovery only (ADR-0022 A6). `manga(id:)`, detail, chapters and pages are never
    /// filtered: a saved title must open whatever the switch says.
    private func admits(_ manga: Manga) -> Bool {
        AdultContentFilter.admits(rating: manga.contentRating,
                                  sourceDeclaresAdultTitles: declaresAdultTitles,
                                  showAdultContent: showAdultContent())
    }

    /// The same Source with filtering off, for matching a saved title against the catalogue
    /// (`MALEntityResolver`). Hiding an adult match there would cache a false miss.
    func unfilteredForResolution() -> ExtensionSource {
        ExtensionSource(declaration: declaration, script: script, isNSFW: isNSFW,
                        lifecycle: lifecycle, host: host,
                        declaresAdultTitles: declaresAdultTitles, showAdultContent: { true })
    }
```

The copy has its own `CursorLedger`. That is correct here: resolution asks for offset 0 only.

In `SourceRegistry.swift`, add this beside `externalIdSource`:

```swift
    /// `externalIdSource` without adult filtering, for resolving titles the reader already
    /// has. Discovery must keep using the filtered one.
    var externalIdResolutionSource: MangaSource? {
        guard let source = externalIdSource else { return nil }
        return (source as? ExtensionSource)?.unfilteredForResolution() ?? source
    }
```

In `AppComposition.swift:260-262`, change only the `MALEntityResolver` closure to `source: { resolvedRegistry.externalIdResolutionSource }`. Leave `MALReverseResolver`, `MoreLikeThisProvider` and `RecommendationEngine` on `externalIdSource`, because those are discovery.

- [ ] **Step 4: Pin Review Focus 5.** Add a test to `MangaCartaTests/PagedMangaLoaderTests.swift`, or to the file that already tests `PagedMangaLoader`: find it with `grep -ln PagedMangaLoader MangaCartaTests`. Build the loader over a fetch closure that returns `[]` for offset 0, and assert `hasMore == false` after the first load. Title it `testAFullyFilteredPageEndsTheFeed_acceptedByADR0022A6`, with this comment:

```swift
    // ADR-0022 A6: a feed page whose every title is adult arrives empty while the switch is
    // off, and an empty page ends the feed. Accepted: such a feed is mostly hidden anyway.
    // If this ever changes, the loader needs a raw-vs-filtered signal, not a looser rule here.
```

- [ ] **Step 5: Run.** Use the Step 2 command, then the whole `MangaCartaTests` target. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A MangaCarta MangaCartaTests MangaCarta.xcodeproj/project.pbxproj
git commit -m "feat(adult): filter adult titles from installed Source discovery (ADR-0022 A6)"
```

---

### Task 5: Recommendations pass through the same predicate

**Files:**
- Modify: `MangaCarta/Services/SourceRegistry.swift` (add `admitsForDiscovery`)
- Modify: `MangaCarta/Models/RecommendationEngine.swift` (`init`, `rebuild`, `rankedRecommendations`)
- Modify: `MangaCarta/Models/MoreLikeThisViewModel.swift`
- Modify: `MangaCarta/Services/AppComposition.swift:395-397`
- Test: `MangaCartaTests/SourceRegistryTests.swift`, plus the existing `RecommendationEngine` test file (`grep -ln "RecommendationEngine(" MangaCartaTests`)

**Interfaces:**
- Consumes: `StubSource` (Task 3) and `AdultContentFilter` (Task 1).
- Produces: `SourceRegistry.admitsForDiscovery(_ manga: Manga) -> Bool`
- Produces: `RecommendationEngine.init(..., admits: @escaping (Manga) -> Bool = { _ in true })`

- [ ] **Step 1: Write the failing registry tests**

```swift
private func manga(_ id: String, source: String, rating: String?) -> Manga {
    var m = Manga(id: id, title: id, coverURL: nil, sourceId: source)  // match Manga's memberwise init
    m.contentRating = rating
    return m
}

@Test func discoveryRejectsAdultTitlesAndUnknownOrHiddenSources() {
    let registry = SourceRegistry(sources: [LocalSource(),
                                            StubSource(id: "m", declaresAdultTitles: true),
                                            StubSource(id: "a", isNSFW: true, declaresAdultTitles: true)],
                                  showAdultContent: { false })
    #expect(registry.admitsForDiscovery(manga("1", source: "m", rating: "safe")))
    #expect(!registry.admitsForDiscovery(manga("2", source: "m", rating: "erotica")))
    #expect(!registry.admitsForDiscovery(manga("3", source: "m", rating: nil)))
    #expect(!registry.admitsForDiscovery(manga("4", source: "a", rating: "safe")))      // hidden whole
    #expect(!registry.admitsForDiscovery(manga("5", source: "gone", rating: nil)))      // fails closed
    #expect(registry.admitsForDiscovery(manga("6", source: "gone", rating: "safe")))
}
```

Use `Manga`'s real memberwise initializer (see `MangaModels.swift`). The call above is a sketch of the fields.

- [ ] **Step 2: Write the failing engine test.** In the existing `RecommendationEngine` test file, copy the nearest test that builds an engine with a stub provider returning a fixed pool. Give it a pool of two `ScoredManga`, one rated `erotica`, pass `admits: { $0.contentRating != "erotica" }`, and assert that both `recommendations` after `refresh()` and `rankedRecommendations()` contain only the other title.

- [ ] **Step 3: Run to verify both fail**

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaTests/SourceRegistryTests -only-testing:MangaCartaTests/<RecommendationEngineTestClass>
```

- [ ] **Step 4: Implement.** In `SourceRegistry.swift`:

```swift
    /// Whether a title may appear in a discovery surface that did not come through a
    /// Source's own filtered listing: recommendations resolve through `manga(id:)` and
    /// persisted pools. An unknown Source fails closed (ADR-0022 A6).
    func admitsForDiscovery(_ manga: Manga) -> Bool {
        let show = showAdultContent()
        guard let source = source(id: manga.sourceId) else {
            return AdultContentFilter.admits(rating: manga.contentRating,
                                             sourceDeclaresAdultTitles: true, showAdultContent: show)
        }
        if source.isNSFW && !show { return false }
        return AdultContentFilter.admits(rating: manga.contentRating,
                                         sourceDeclaresAdultTitles: source.declaresAdultTitles,
                                         showAdultContent: show)
    }
```

In `RecommendationEngine.swift`, add `admits: @escaping (Manga) -> Bool = { _ in true }` as the last init parameter and store it in `private let admits`. Filter the pool in both places:

```swift
        let pool = ((try? await makeProvider(source)
            .candidates(for: profile, excluding: excluding, limit: poolLimit)) ?? [])
            .filter { admits($0.manga) }
```

Make the same change in `rankedRecommendations`, with `limit`.

In `AppComposition.swift`, pass `admits: { resolvedRegistry.admitsForDiscovery($0) }` to `RecommendationEngine(...)`.

In `MoreLikeThisViewModel.swift`, store the registry and filter:

```swift
    private let registry: SourceRegistry

    init(registry: SourceRegistry, provider: MoreLikeThisProvider? = nil) {
        self.registry = registry
        self.provider = provider ?? MoreLikeThisProvider(source: { registry.externalIdSource })
    }
    // in load(for:):
        items = await provider.recommendations(for: manga).filter { registry.admitsForDiscovery($0) }
```

- [ ] **Step 5: Run.** Use the Step 3 command, then the whole `MangaCartaTests` target.

- [ ] **Step 6: Commit**

```bash
git add -A MangaCarta MangaCartaTests
git commit -m "feat(adult): filter recommendations through the discovery predicate (ADR-0022 A6)"
```

---

### Task 6: The switch's label, live refetch, and docs

**Files:**
- Modify: `MangaCarta/Views/SettingsView.swift:189`
- Modify: `MangaCarta/Views/HomeView.swift` (add `onChange`)
- Modify: `MangaCarta/Views/SearchView.swift:72-80`
- Modify: `MangaCartaUITests/RepositorySettingsUITests.swift:24,42`
- Modify: `CLAUDE.md` ("Current state", Phase 4 bullet), `docs/app-store/submission-copy.md` (the review-notes sentence about adult classes), `docs/glossary.md` (only if it defines the switch's name; check with `grep -n "adult" docs/glossary.md`)

- [ ] **Step 1: Update the UI test to the new label first,** so that it fails:

```sh
sed -i '' 's/"Show adult sources"/"Show adult content"/g' MangaCartaUITests/RepositorySettingsUITests.swift
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' test -only-testing:MangaCartaUITests/RepositorySettingsUITests
```

Expected: FAIL, with the switch not found. This suite clears two real settings; afterwards, restore `settings.declaredAgeOver18` and `settings.showAdultSources` on the seeded simulator with `xcrun simctl spawn ADDAB2F8-38C7-4D44-97EA-4E98281CF691 defaults write Elias-Magdaleno.Manga-Reader <key> -bool true`.

- [ ] **Step 2: Rename the label.** In `SettingsView.swift:189`, write `Toggle("Show adult content", isOn: $showAdultSources)`. Update the comment above it: the switch now hides adult titles, and hides whole only the Sources that are adult throughout (ADR-0022 A6).

- [ ] **Step 3: Refetch on change.** In `HomeView.swift`, next to the existing modifiers on the root content:

```swift
            .onChange(of: showAdultSources) { _, _ in
                // ADR-0022 A6: the switch changes which titles discovery may show.
                vm.refresh()
                Task { await engine.refresh() }
            }
```

In `SearchView.swift`, append `vm.retry()` at the end of the existing `onChange(of: showAdultSources)` closure, so the current query re-runs under the new setting.

- [ ] **Step 4: Run the UI suite** (the Step 1 command) **and the full unit target.** Expected: pass. Restore the two simulator settings afterwards.

- [ ] **Step 5: Docs, owner by owner.**
  - `CLAUDE.md`, "Current state": change the sentence starting "a `mixed`/`adultOnly` install always shows the declared-age sheet" by appending "; a `mixed` Source is then visible and the "Show adult content" switch filters its adult titles (ADR-0022 A6)."
  - `docs/app-store/submission-copy.md`: change the review-notes sentence that says the adult class is hidden by default to "adult-rated titles, and Sources that are adult throughout, are hidden by default and require the reader's declared age".
  - Nothing else restates the rule. Grep for `Show adult sources` across `docs/` and fix any remaining label references, linking to the ADR rather than restating it.

- [ ] **Step 6: Commit**

```bash
git diff --stat -- MangaCarta.xcodeproj
git add -A MangaCarta MangaCartaUITests CLAUDE.md docs
git commit -m "feat(settings): rename to Show adult content and refetch on change (ADR-0022 A6)"
```

---

## Done when

- `MangaCartaTests` is fully green locally, and `RepositorySettingsUITests` passes.
- On the seeded simulator, with the switch off and MangaDex installed, Home shows MangaDex rails. Search for a known erotica-rated title returns nothing. Turning the switch on and returning to Search shows it.
- The PR is open against main, and CI (build and unit, SwiftLint, hermetic UI) is green.
