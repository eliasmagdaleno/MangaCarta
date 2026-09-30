# Per-title Reading Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each Work remembers its own reading mode (set from the reader), falling back to a global default set in Settings; a local import's ComicInfo `Manga` field seeds it.

**Architecture:** A new `@MainActor ObservableObject` `ReadingModeStore` (UserDefaults-backed, like `SourcePreferenceStore`) owns the default and a Work-id → mode map, resolving Work merges through `WorkStore.work(_:)`. `AppComposition` builds it; it is injected into the environment. `ReaderView` computes its mode from it; `SettingsView` edits the default; `LocalImportViewModel` seeds it after import.

**Tech Stack:** Swift 5 mode, SwiftUI, Swift Testing (unit), XCTest/XCUITest (UI). No dependencies.

**Spec:** `docs/superpowers/specs/2026-09-30-per-title-reading-mode-design.md` (decisions: `docs/adr/0026-reading-mode-is-per-work.md`). Read both first.

## Global Constraints

- CI builds with Xcode 16.4 / Swift 6.0: no isolated conformances, `nonisolated(nonsending)`, `@concurrent`, `Task.immediate`.
- Every `xcodebuild`: `-destination 'id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691'` (seeded iPhone 17 Pro) and `-derivedDataPath /tmp/mangacarta-290-dd`. Boot first: `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 2>/dev/null; xcrun simctl bootstatus ADDAB2F8-38C7-4D44-97EA-4E98281CF691 -b`.
- `Models/`, `Services/`, `Views/Components/` are synchronized groups (new files compile automatically). **`MangaCartaTests/` is not**: add a new test file with
  `xcp add-file "/tmp/mangacarta-290/MangaCarta.xcodeproj" --file "/tmp/mangacarta-290/MangaCartaTests/<File>.swift" --targets MangaCartaTests` (use the `/tmp/...` spelling, not `/private/tmp/...`).
- Tests isolate state with `TestDefaults("<prefix>")` + `defer { suite.remove() }` and `TestDirectory("<prefix>")` + `defer { dir.remove() }` (see `MangaCartaTests/TestDefaults.swift`, `TestDirectory.swift`).
- Stores are injected, never reached for: no `ReadingModeStore.shared`.
- The default key is exactly `readingMode` (raw values `leftToRight` / `rightToLeft` / `vertical`, default `.rightToLeft`). The per-Work key is exactly `reader.workModes`.
- Copy, verbatim: menu entry `Default (<label>)`; Settings header `InkSectionHeader("Reader", eyebrow: "Reading")`; picker `Default reading mode`; caption `Titles you've set a mode for in the reader keep it.`; accessibility values `"<label>, default"` / `"<label>, this title"`.
- String interpolation must be `"\(x)"` — never `"(x)"`.
- `swiftlint lint <changed files>` (explicit list) adds no warnings.
- Check `git diff --stat` right before every `git add`; if `project.pbxproj` changed beyond an `xcp` add, `git checkout` it.

## Review Focus

1. **A read after a merge must not publish.** `ReaderView.body` calls `effectiveMode`; mutating `@Published` there triggers "Publishing changes from within view updates". Pinned in Task 1, test `readAfterMergeDoesNotPublish`.
2. **Corrupt or unknown persisted values** (bad JSON, an unknown raw value such as `"sideways"`) must load as "no mode", not crash or wipe other entries. Pinned in Task 1, test `unknownRawValuesAreDropped`.
3. **ComicInfo values in odd case or with whitespace** (`" yesandrighttoleft "`, `"NO"`) must map like the canonical spelling. Pinned in Task 2, test `mangaValueMapsCaseInsensitively`.
4. **Upgrading with a non-default global value** (old `readingMode = vertical`) must keep vertical as the default for every title. Pinned in Task 1, test `existingGlobalValueBecomesTheDefault`.
5. **A later file in a series must not overwrite the first file's seeded mode**, even when it disagrees. Pinned in Task 3, test `laterSeriesFileDoesNotOverwriteSeededMode`.

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `MangaCarta/Models/ReadingMode.swift` | Create | `ReadingMode` enum (moved verbatim from `ReaderView.swift`) |
| `MangaCarta/Services/ReadingModeStore.swift` | Create | Default + per-Work modes, merge resolution, persistence |
| `MangaCarta/Models/ComicInfo.swift` | Modify | Parse `<Manga>`; `readingMode` mapping |
| `MangaCarta/Services/AppComposition.swift` | Modify | Build and expose `readingModes` |
| `MangaCarta/MangaCartaApp.swift` | Modify | `@StateObject`, `.environmentObject`, importer `configure` |
| `MangaCarta/Models/LocalImportViewModel.swift` | Modify | Seed after import |
| `MangaCarta/Views/ReaderView.swift` | Modify | Computed mode, four-entry menu, a11y |
| `MangaCarta/Views/SettingsView.swift` | Modify | Reader section; preview env |
| `MangaCartaTests/ReadingModeTests.swift` | Create (xcp) | Store, ComicInfo and seeding tests |
| `MangaCartaTests/LocalImportSlice2Tests.swift` | Modify | `configure` call gains `readingModes:` |
| `MangaCartaUITests/LocalImportUITests.swift` | Modify | Per-title mode UI test |
| `CLAUDE.md` | Modify | One line under "Current state" |

---

### Task 1: `ReadingMode` model and `ReadingModeStore`

**Files:**
- Create: `MangaCarta/Models/ReadingMode.swift`
- Modify: `MangaCarta/Views/ReaderView.swift:23-46` (delete the moved enum and its `// MARK: - Reading mode`)
- Create: `MangaCarta/Services/ReadingModeStore.swift`
- Create + xcp: `MangaCartaTests/ReadingModeTests.swift`

**Interfaces:**
- Produces:
  - `enum ReadingMode: String, CaseIterable, Identifiable { case leftToRight, rightToLeft, vertical }` with `label`, `symbol`, `isPaged` (unchanged).
  - `@MainActor final class ReadingModeStore: ObservableObject`
    - `static let defaultKey = "readingMode"`, `static let workModesKey = "reader.workModes"`
    - `init(defaults: UserDefaults = .standard, works: WorkStore)`
    - `@Published var defaultMode: ReadingMode`
    - `func mode(for workID: WorkID) -> ReadingMode?`
    - `func effectiveMode(for workID: WorkID?) -> ReadingMode`
    - `func set(_ mode: ReadingMode, for workID: WorkID)`
    - `func clear(for workID: WorkID)`
    - `@discardableResult func seed(_ mode: ReadingMode, for workID: WorkID) -> Bool`

- [ ] **Step 1: Move the enum.** Create `MangaCarta/Models/ReadingMode.swift` with the enum cut verbatim from `ReaderView.swift` lines 23–46:

```swift
import Foundation

/// How the reader lays out a chapter. A Work's own mode beats the default (ADR-0026).
enum ReadingMode: String, CaseIterable, Identifiable {
    case leftToRight, rightToLeft, vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftToRight: return "Left to Right"
        case .rightToLeft: return "Right to Left"
        case .vertical:    return "Webtoon (Vertical)"
        }
    }

    var symbol: String {
        switch self {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .vertical:    return "arrow.down"
        }
    }

    var isPaged: Bool { self != .vertical }
}
```

Delete the enum and its MARK from `ReaderView.swift`. Build: `xcodebuild -scheme MangaCarta -destination 'id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' -derivedDataPath /tmp/mangacarta-290-dd build 2>&1 | grep -E "error:|BUILD"` → `BUILD SUCCEEDED`.

- [ ] **Step 2: Write the failing tests.** Create `MangaCartaTests/ReadingModeTests.swift` and add it with `xcp add-file` (Global Constraints):

```swift
import Combine
import Foundation
import Testing
@testable import MangaCarta

@MainActor
private struct StoreHarness {
    let suite: TestDefaults
    let directory: TestDirectory
    let works: WorkStore
    let store: ReadingModeStore

    init(_ prefix: String, seedDefaults: (UserDefaults) -> Void = { _ in }) {
        suite = TestDefaults(prefix)
        directory = TestDirectory(prefix)
        seedDefaults(suite.defaults)
        works = WorkStore(directory: directory.url)
        store = ReadingModeStore(defaults: suite.defaults, works: works)
    }

    func mint(_ id: String) -> WorkID {
        works.mint(from: Manga(id: id, sourceId: "src", title: id, description: "",
                               status: "ongoing", year: nil, coverURL: nil, malId: nil))
    }

    /// A second store over the same defaults and Works: what the next launch sees.
    func reopened() -> ReadingModeStore { ReadingModeStore(defaults: suite.defaults, works: works) }

    func remove() { suite.remove(); directory.remove() }
}

@Suite("Reading mode store")
@MainActor
struct ReadingModeStoreTests {
    @Test func ownModeBeatsTheDefaultAndNilUsesTheDefault() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a"), b = h.mint("b")
        h.store.set(.leftToRight, for: a)
        #expect(h.store.effectiveMode(for: a) == .leftToRight)
        #expect(h.store.effectiveMode(for: b) == .rightToLeft)
        #expect(h.store.effectiveMode(for: nil) == .rightToLeft)
        h.store.defaultMode = .vertical
        #expect(h.store.effectiveMode(for: a) == .leftToRight)
        #expect(h.store.effectiveMode(for: b) == .vertical)
    }

    @Test func setClearAndSeed() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a")
        #expect(h.store.seed(.rightToLeft, for: a) == true)
        #expect(h.store.seed(.leftToRight, for: a) == false)
        #expect(h.store.mode(for: a) == .rightToLeft)
        h.store.clear(for: a)
        #expect(h.store.mode(for: a) == nil)
        h.store.set(.rightToLeft, for: a)            // equal to the default, still pinned
        #expect(h.store.mode(for: a) == .rightToLeft)
    }

    @Test func modesPersistAcrossStores() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a")
        h.store.set(.vertical, for: a)
        h.store.defaultMode = .leftToRight
        let next = h.reopened()
        #expect(next.mode(for: a) == .vertical)
        #expect(next.defaultMode == .leftToRight)
        #expect(h.suite.defaults.string(forKey: ReadingModeStore.defaultKey) == "leftToRight")
    }

    @Test func unknownRawValuesAreDropped() throws {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let good = h.mint("good"), bad = h.mint("bad")
        let data = try JSONEncoder().encode([good.raw.uuidString: "vertical", bad.raw.uuidString: "sideways"])
        h.suite.defaults.set(data, forKey: ReadingModeStore.workModesKey)
        let loaded = h.reopened()
        #expect(loaded.mode(for: good) == .vertical)        // the known entry survives
        #expect(loaded.mode(for: bad) == nil)               // the unknown one is dropped

        let garbage = StoreHarness("ReadingModeStore") {
            $0.set(Data("not json".utf8), forKey: ReadingModeStore.workModesKey)
        }
        defer { garbage.remove() }
        let a = garbage.mint("a")
        #expect(garbage.store.mode(for: a) == nil)
        garbage.store.set(.vertical, for: a)
        #expect(garbage.reopened().mode(for: a) == .vertical)
    }

    @Test func existingGlobalValueBecomesTheDefault() {
        let h = StoreHarness("ReadingModeStore") { $0.set("vertical", forKey: "readingMode") }
        defer { h.remove() }
        #expect(h.store.defaultMode == .vertical)
        #expect(h.store.effectiveMode(for: h.mint("a")) == .vertical)
    }

    @Test func mergedAwayModeFollowsTheSurvivor() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        #expect(h.store.mode(for: winner) == .leftToRight)
        #expect(h.store.mode(for: loser) == .leftToRight)   // a stale id resolves too
    }

    @Test func survivorsOwnModeWinsAMerge() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.vertical, for: winner)
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        #expect(h.store.mode(for: winner) == .vertical)
        h.store.set(.vertical, for: winner)                // a write re-keys and drops the loser
        let raw = h.suite.defaults.data(forKey: ReadingModeStore.workModesKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        #expect(raw == [winner.raw.uuidString: "vertical"])
    }

    @Test func aWriteDropsKeysThatResolveToNoWork() throws {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a")
        let orphan = UUID().uuidString                      // no Work has this id
        let data = try JSONEncoder().encode([orphan: "vertical"])
        h.suite.defaults.set(data, forKey: ReadingModeStore.workModesKey)
        let loaded = h.reopened()
        loaded.set(.leftToRight, for: a)
        let raw = h.suite.defaults.data(forKey: ReadingModeStore.workModesKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        #expect(raw == [a.raw.uuidString: "leftToRight"])
    }

    @Test func clearOnTheSurvivorAlsoClearsAMergedAwayMode() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        h.store.clear(for: winner)
        #expect(h.store.mode(for: winner) == nil)
        #expect(h.reopened().mode(for: winner) == nil)
    }

    @Test func readAfterMergeDoesNotPublish() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        var published = 0
        let sink = h.store.objectWillChange.sink { published += 1 }
        _ = h.store.effectiveMode(for: winner)
        _ = h.store.mode(for: winner)
        sink.cancel()
        #expect(published == 0)
    }
}
```

- [ ] **Step 3: Run to verify failure.**
`xcodebuild -scheme MangaCarta -destination 'id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691' -derivedDataPath /tmp/mangacarta-290-dd test -only-testing:MangaCartaTests/ReadingModeStoreTests 2>&1 | grep -E "error:|TEST"`
Expected: build error `cannot find 'ReadingModeStore' in scope`.

- [ ] **Step 4: Implement.** Create `MangaCarta/Services/ReadingModeStore.swift`:

```swift
//
//  ReadingModeStore.swift
//  MangaCarta
//
//  How each Work is read (ADR-0026). Two tiers: a Work's own mode, else the default.
//
//  UserDefaults rather than a file, for `SourcePreferenceStore`'s reason: small, flat,
//  and needed on the reader's first paint.
//
//  Merges follow `UpdateStateStore.reconcileMerges`' rule — a key belongs to the Work it
//  resolves to, the survivor's own entry wins, an unresolvable key is ignored — applied
//  in two places. Reads are pure, because `ReaderView.body` calls them and publishing
//  from there is a SwiftUI runtime error. Writes re-key the stored map first.
//

import Foundation

@MainActor
final class ReadingModeStore: ObservableObject {

    static let defaultKey = "readingMode"
    static let workModesKey = "reader.workModes"

    private let defaults: UserDefaults
    private let works: WorkStore

    /// Work id (uuidString) → that Work's own mode. Keys may be merged-away ids until the
    /// next write re-keys them.
    @Published private var modes: [String: ReadingMode] = [:]

    /// The mode every Work without its own follows. Keeps the key the reader's old
    /// `@AppStorage` used, so an update changes nobody's mode.
    @Published var defaultMode: ReadingMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Self.defaultKey) }
    }

    init(defaults: UserDefaults = .standard, works: WorkStore) {
        self.defaults = defaults
        self.works = works
        defaultMode = defaults.string(forKey: Self.defaultKey).flatMap(ReadingMode.init(rawValue:))
            ?? .rightToLeft
        if let data = defaults.data(forKey: Self.workModesKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            modes = raw.compactMapValues(ReadingMode.init(rawValue:))
        }
    }

    // MARK: - Reads (pure)

    /// The Work's own mode, or `nil` when it follows the default.
    func mode(for workID: WorkID) -> ReadingMode? {
        guard let target = resolvedKey(workID.raw.uuidString) else { return nil }
        if let own = modes[target] { return own }
        return modes.keys.sorted()
            .first { $0 != target && resolvedKey($0) == target }
            .flatMap { modes[$0] }
    }

    func effectiveMode(for workID: WorkID?) -> ReadingMode {
        workID.flatMap(mode(for:)) ?? defaultMode
    }

    // MARK: - Writes

    func set(_ mode: ReadingMode, for workID: WorkID) {
        var next = rekeyed()
        guard let target = resolvedKey(workID.raw.uuidString) else { return }
        next[target] = mode
        commit(next)
    }

    func clear(for workID: WorkID) {
        var next = rekeyed()
        guard let target = resolvedKey(workID.raw.uuidString) else { return }
        next[target] = nil
        commit(next)
    }

    @discardableResult
    func seed(_ mode: ReadingMode, for workID: WorkID) -> Bool {
        guard self.mode(for: workID) == nil else { return false }
        set(mode, for: workID)
        return true
    }

    // MARK: - Merge resolution

    /// The live Work id a stored key belongs to, or `nil` when it resolves to no Work.
    private func resolvedKey(_ key: String) -> String? {
        guard let uuid = UUID(uuidString: key) else { return nil }
        return works.work(WorkID(raw: uuid))?.id.raw.uuidString
    }

    /// `modes` with every key moved to the Work it resolves to. The survivor's own entry
    /// wins; among several merged-away keys the lexicographically smallest wins, matching
    /// the read path; unresolvable keys are dropped.
    private func rekeyed() -> [String: ReadingMode] {
        var result: [String: ReadingMode] = [:]
        for key in modes.keys.sorted() {
            guard let target = resolvedKey(key), let value = modes[key] else { continue }
            if key == target {
                result[target] = value
            } else if result[target] == nil, modes[target] == nil {
                result[target] = value
            }
        }
        return result
    }

    private func commit(_ next: [String: ReadingMode]) {
        modes = next
        guard let data = try? JSONEncoder().encode(next.mapValues(\.rawValue)) else { return }
        defaults.set(data, forKey: Self.workModesKey)
    }
}
```

- [ ] **Step 5: Run to verify pass.** Same command as Step 3. Expected: `** TEST SUCCEEDED **`, 10 tests.

- [ ] **Step 6: Mutation check.** Temporarily make `mode(for:)` return `modes[target]` only (drop the merged-key scan). Re-run: `mergedAwayModeFollowsTheSurvivor` must fail. Revert with the inverse edit (not `git checkout`, which discards uncommitted work).

- [ ] **Step 7: Commit.**

```bash
git add MangaCarta/Models/ReadingMode.swift MangaCarta/Services/ReadingModeStore.swift \
  MangaCarta/Views/ReaderView.swift MangaCartaTests/ReadingModeTests.swift MangaCarta.xcodeproj/project.pbxproj
git commit -m "feat(reader): ReadingModeStore — per-Work reading mode over a default (#290)"
```

---

### Task 2: ComicInfo `Manga` field

**Files:**
- Modify: `MangaCarta/Models/ComicInfo.swift`
- Test: `MangaCartaTests/ReadingModeTests.swift` (append)

**Interfaces:**
- Consumes: `ReadingMode` (Task 1).
- Produces: `ComicInfo.manga: String?`; `ComicInfo.readingMode: ReadingMode?`. The memberwise init gains `manga: String? = nil` as its **last** parameter so existing call sites compile unchanged.

- [ ] **Step 1: Write the failing tests** (append to `ReadingModeTests.swift`):

```swift
@Suite("ComicInfo reading mode")
struct ComicInfoReadingModeTests {
    private func info(_ manga: String?) -> ComicInfo? {
        let field = manga.map { "<Manga>\($0)</Manga>" } ?? ""
        return ComicInfo.parse(Data("<ComicInfo><Series>S</Series>\(field)</ComicInfo>".utf8))
    }

    @Test func mangaValuesMapToModes() {
        #expect(info("YesAndRightToLeft")?.readingMode == .rightToLeft)
        #expect(info("No")?.readingMode == .leftToRight)
        #expect(info("Yes")?.readingMode == nil)
        #expect(info("Unknown")?.readingMode == nil)
        #expect(info(nil)?.readingMode == nil)
        #expect(info("YesAndRightToLeft")?.manga == "YesAndRightToLeft")
    }

    @Test func mangaValueMapsCaseInsensitively() {
        #expect(info(" yesandrighttoleft ")?.readingMode == .rightToLeft)
        #expect(info("NO")?.readingMode == .leftToRight)
    }

    @Test func aRecordStoredBeforeTheFieldStillDecodes() throws {
        let old = Data(#"{"series":"S","genres":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ComicInfo.self, from: old)
        #expect(decoded.series == "S")
        #expect(decoded.manga == nil)
        #expect(decoded.readingMode == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure.** `... test -only-testing:MangaCartaTests/ComicInfoReadingModeTests` → build error `value of type 'ComicInfo' has no member 'readingMode'`.

- [ ] **Step 3: Implement** in `ComicInfo.swift`. The struct uses the synthesized memberwise init today, and tests in `ComicInfoTests.swift` and `LocalLibraryStoreTests.swift` call it without a `manga:` argument. A synthesized init gives a `let` no default, so write the explicit init below — it keeps every existing call site compiling:
  - add `let manga: String?` after `frontCoverPageIndex`;
  - add the explicit init (below);
  - in `parse`, pass `manga: value(delegate.values["Manga"])` as the last argument;
  - add the mapping:

```swift
    /// `Manga=YesAndRightToLeft` reads right to left; `Manga=No` is a Western comic, left to
    /// right. `Yes` says manga but not which way, so it — like `Unknown` — gives nothing
    /// (ADR-0026).
    var readingMode: ReadingMode? {
        switch manga?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yesandrighttoleft": return .rightToLeft
        case "no": return .leftToRight
        default: return nil
        }
    }
```

The explicit init:

```swift
    init(series: String?, title: String?, number: String?, volume: String?, summary: String?,
         writer: String?, genres: [String], frontCoverPageIndex: Int?, manga: String? = nil) {
        self.series = series; self.title = title; self.number = number; self.volume = volume
        self.summary = summary; self.writer = writer; self.genres = genres
        self.frontCoverPageIndex = frontCoverPageIndex; self.manga = manga
    }
```

`Codable` stays synthesized: a missing optional key decodes as `nil`.

- [ ] **Step 4: Run to verify pass.** Expected `** TEST SUCCEEDED **`. Also run `-only-testing:MangaCartaTests/LocalLibraryStoreTests` (existing ComicInfo coverage) → passes.

- [ ] **Step 5: Commit.**

```bash
git add MangaCarta/Models/ComicInfo.swift MangaCartaTests/ReadingModeTests.swift
git commit -m "feat(local-import): parse ComicInfo Manga into a reading mode (#290)"
```

---

### Task 3: Composition, environment, and import seeding

**Files:**
- Modify: `MangaCarta/Services/AppComposition.swift` (property near `sourcePreferences` ~line 70; assignment in `init` near line 490)
- Modify: `MangaCarta/MangaCartaApp.swift` (`@StateObject` near line 34; init near line 145–150; `.environmentObject` near line 180; UI-fixture `configure` near line 299)
- Modify: `MangaCarta/Models/LocalImportViewModel.swift` (`configure`, the `MainActor.run` block ~line 88–100)
- Modify: `MangaCartaTests/LocalImportSlice2Tests.swift:83-92` (`localImporter` helper)
- Test: `MangaCartaTests/ReadingModeTests.swift` (append)

**Interfaces:**
- Consumes: `ReadingModeStore` (Task 1), `ComicInfo.readingMode` (Task 2).
- Produces: `AppComposition.readingModes: ReadingModeStore`; `ReadingModeStore` in the SwiftUI environment; `LocalImportViewModel.configure(registry:library:works:readingModes:)`.

- [ ] **Step 1: Write the failing tests** (append to `ReadingModeTests.swift`):

```swift
@MainActor
private func seedingImporter(_ dir: TestDirectory, _ suite: TestDefaults)
    -> (LocalImportViewModel, WorkStore, ReadingModeStore) {
    let works = WorkStore(directory: dir.url.appendingPathComponent("works"))
    let store = LocalLibraryStore(root: dir.url.appendingPathComponent("library"))
    let registry = SourceRegistry(sources: [LocalSource(store: store)])
    let library = LibraryStore(defaults: suite.defaults, works: works, registry: registry)
    let modes = ReadingModeStore(defaults: suite.defaults, works: works)
    let importer = LocalImportViewModel()
    importer.configure(registry: registry, library: library, works: works, readingModes: modes)
    return (importer, works, modes)
}

@MainActor
private func archive(_ dir: TestDirectory, _ name: String, series: String, manga: String?) throws -> URL {
    try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    let url = dir.url.appendingPathComponent(name)
    let field = manga.map { "<Manga>\($0)</Manga>" } ?? ""
    let xml = "<ComicInfo><Series>\(series)</Series><Number>\(name)</Number>\(field)</ComicInfo>"
    try LocalTestZip.write([("001.png", LocalTestZip.png), ("ComicInfo.xml", Data(xml.utf8))], to: url)
    return url
}

@Suite("Reading mode seeding on import")
@MainActor
struct ReadingModeSeedingTests {
    private func workID(_ works: WorkStore, series: String) -> WorkID? {
        works.workId(for: ListingKey(sourceId: LocalSource.sourceID,
                                     mangaId: LocalSeriesIdentity.seriesID(for: series)))
    }

    @Test func rightToLeftImportSeedsTheWork() async throws {
        let dir = TestDirectory("ReadingModeSeeding"); defer { dir.remove() }
        let suite = TestDefaults("ReadingModeSeeding"); defer { suite.remove() }
        let (importer, works, modes) = seedingImporter(dir, suite)
        await importer.importFilesAndWait([try archive(dir, "1.cbz", series: "rtl", manga: "YesAndRightToLeft")])
        let id = try #require(workID(works, series: "rtl"))
        #expect(modes.mode(for: id) == .rightToLeft)
    }

    @Test func laterSeriesFileDoesNotOverwriteSeededMode() async throws {
        let dir = TestDirectory("ReadingModeSeeding"); defer { dir.remove() }
        let suite = TestDefaults("ReadingModeSeeding"); defer { suite.remove() }
        let (importer, works, modes) = seedingImporter(dir, suite)
        await importer.importFilesAndWait([try archive(dir, "1.cbz", series: "mixed", manga: "YesAndRightToLeft")])
        await importer.importFilesAndWait([try archive(dir, "2.cbz", series: "mixed", manga: "No")])
        let id = try #require(workID(works, series: "mixed"))
        #expect(modes.mode(for: id) == .rightToLeft)
    }

    @Test func importLeavesAnExistingModeAlone() async throws {
        let dir = TestDirectory("ReadingModeSeeding"); defer { dir.remove() }
        let suite = TestDefaults("ReadingModeSeeding"); defer { suite.remove() }
        let (importer, works, modes) = seedingImporter(dir, suite)
        await importer.importFilesAndWait([try archive(dir, "1.cbz", series: "chosen", manga: nil)])
        let id = try #require(workID(works, series: "chosen"))
        #expect(modes.mode(for: id) == nil)                 // no Manga field: nothing seeded
        modes.set(.vertical, for: id)
        await importer.importFilesAndWait([try archive(dir, "2.cbz", series: "chosen", manga: "No")])
        #expect(modes.mode(for: id) == .vertical)
    }
}
```

- [ ] **Step 2: Run to verify failure.** `... -only-testing:MangaCartaTests/ReadingModeSeedingTests` → `extra argument 'readingModes' in call`.

- [ ] **Step 3: `LocalImportViewModel`.** Add a stored `private weak var readingModes: ReadingModeStore?`; change `configure` to

```swift
    func configure(registry: SourceRegistry, library: LibraryStore, works: WorkStore,
                   readingModes: ReadingModeStore) {
        if let source = registry.source(id: LocalSource.sourceID) as? LocalSource {
            local = source.store
        }
        self.library = library
        self.works = works
        self.readingModes = readingModes
    }
```

In the `MainActor.run` block, after the `if library.contains(mangaID) { … } else { … }` statement, add:

```swift
                    // The Work exists now (adding to the Library minted it). ComicInfo seeds
                    // its mode only if it has none, so the first file of a series with a
                    // usable `Manga` value wins (ADR-0026).
                    if let mode = record.comicInfo?.readingMode,
                       let workID = self.works?.workId(for: ListingKey(sourceId: LocalSource.sourceID,
                                                                       mangaId: mangaID)) {
                        self.readingModes?.seed(mode, for: workID)
                    }
```

- [ ] **Step 4: `AppComposition`.** Next to `let sourcePreferences: SourcePreferenceStore` add

```swift
    /// Per-Work reading mode over a default (ADR-0026). Observable and written from the
    /// reader and Settings, so it belongs in the environment.
    let readingModes: ReadingModeStore
```

and in `init`, after the `makeFulfillment` assignment: `self.readingModes = ReadingModeStore(defaults: defaults, works: wk)`.

- [ ] **Step 5: `MangaCartaApp`.**
  - Add `@StateObject private var readingModes: ReadingModeStore` beside `sourcePreferences`.
  - In `init`: `_readingModes = StateObject(wrappedValue: composed.readingModes)`, and change the importer line to `localImporter.configure(registry: composed.registry, library: composed.library, works: composed.works, readingModes: composed.readingModes)`.
  - Add `.environmentObject(readingModes)` after `.environmentObject(sourcePreferences)`.
  - `importUITestFixtureIfRequested(library:works:registry:)` (DEBUG, ~line 288) gains a `readingModes: ReadingModeStore` parameter and calls `importer.configure(registry: registry, library: library, works: works, readingModes: readingModes)`. Its one call site (~line 195) passes `readingModes: readingModes` (the `@StateObject` above).

- [ ] **Step 6: Existing test helper.** In `LocalImportSlice2Tests.swift`'s `localImporter(root:store:suite:)`, pass `readingModes: ReadingModeStore(defaults: defaults, works: works)` to `configure`. Leave the helper's return type alone. The importer holds the store `weak`ly (like `library` and `works`), so this one is released at once and seeding is a no-op in those tests — correct, since none of them is about reading mode.

- [ ] **Step 7: Run to verify pass.** `... -only-testing:MangaCartaTests/ReadingModeSeedingTests -only-testing:MangaCartaTests/LocalImportSlice2Tests` → `** TEST SUCCEEDED **`. Note `seedingImporter` returns `modes`, so the tests hold it strongly.

- [ ] **Step 8: Mutation check.** Remove the `self.mode(for: workID) == nil` guard from `seed` (always `set`). `laterSeriesFileDoesNotOverwriteSeededMode` and `importLeavesAnExistingModeAlone` must fail. Restore with the inverse edit.

- [ ] **Step 9: Commit.**

```bash
git add MangaCarta/Services/AppComposition.swift MangaCarta/MangaCartaApp.swift \
  MangaCarta/Models/LocalImportViewModel.swift MangaCartaTests/LocalImportSlice2Tests.swift \
  MangaCartaTests/ReadingModeTests.swift
git commit -m "feat(local-import): seed a Work's reading mode from ComicInfo (#290)"
```

---

### Task 4: Reader menu, Settings section, UI test, docs

**Files:**
- Modify: `MangaCarta/Views/ReaderView.swift` (line ~140 `@AppStorage`; the `Menu` at ~636–648)
- Modify: `MangaCarta/Views/SettingsView.swift` (env objects ~17–30; between the Appearance and Updates `VStack`s ~86–96; `#Preview` ~589)
- Modify: `MangaCartaUITests/LocalImportUITests.swift`
- Modify: `CLAUDE.md` ("Current state")

**Interfaces:**
- Consumes: `ReadingModeStore` from the environment (Task 3), `WorkStore` from the environment (already injected).

- [ ] **Step 1: Write the failing UI test** (add to `LocalImportUITests`). The spec's version opens two titles; the hermetic fixture hook imports exactly one, and title-to-title isolation is already pinned by `ownModeBeatsTheDefaultAndNilUsesTheDefault`. So this test proves per-title vs global with one title: setting its mode leaves the Settings default alone, and the title keeps its mode on reopen.

```swift
    func testReaderModeIsPerTitle() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-local-import", "-uitest-import-fixture", "deflated"]
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = storageID
        app.launchEnvironment["MANGACARTA_UI_FIXTURE_BASE64"] = Self.fixtureBase64
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let card = app.buttons["libraryCoverCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()

        let read = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'Start Reading' OR label CONTAINS[c] 'Continue'")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        let menu = app.buttons["readerModeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(menu.value as? String, "Right to Left, default")
        menu.tap()
        app.buttons["Left to Right"].tap()
        XCTAssertEqual(menu.value as? String, "Left to Right, this title")
        attach(app, name: "reader-mode-this-title")
        app.buttons["Close reader"].tap()

        app.tabBars.buttons["Settings"].tap()
        let picker = app.buttons["defaultReadingModePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.label.contains("Right to Left") || (picker.value as? String)?.contains("Right to Left") == true)

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(menu.value as? String, "Left to Right, this title")
    }
```

- [ ] **Step 2: Run to verify failure.** `xcodebuild … test -only-testing:MangaCartaUITests/LocalImportUITests/testReaderModeIsPerTitle` → fails at `readerModeMenu` not found.

- [ ] **Step 3: Reader.** In `ReaderView`, replace `@AppStorage("readingMode") private var mode: ReadingMode = .rightToLeft` with:

```swift
    @EnvironmentObject private var readingModes: ReadingModeStore
    @EnvironmentObject private var works: WorkStore

    /// The open title's Work. Opening a chapter mints it, so `nil` is not expected; when it
    /// happens the menu edits the default instead (ADR-0026).
    private var workID: WorkID? {
        works.workId(for: ListingKey(sourceId: manga.sourceId, mangaId: manga.id))
    }

    /// The mode in force: the Work's own, else the default. Every existing read of `mode`
    /// (layout, `.onChange(of: mode)`, page order) keeps working against it.
    private var mode: ReadingMode { readingModes.effectiveMode(for: workID) }

    /// The menu's selection: `nil` is "Default".
    private var modeSelection: Binding<ReadingMode?> {
        Binding(
            get: { workID.map { readingModes.mode(for: $0) } ?? readingModes.defaultMode },
            set: { newValue in
                if let id = workID {
                    if let newValue { readingModes.set(newValue, for: id) } else { readingModes.clear(for: id) }
                } else if let newValue {
                    readingModes.defaultMode = newValue
                }
            }
        )
    }

    private var modeAccessibilityValue: String {
        let own = workID.flatMap { readingModes.mode(for: $0) } != nil
        return "\(mode.label), \(own ? "this title" : "default")"
    }
```

(`ReaderView` has no `works` property today; `history` is its only other environment object.) Replace the menu's picker and modifiers:

```swift
            Menu {
                Picker("Reading Mode", selection: modeSelection) {
                    if workID != nil {
                        Label("Default (\(readingModes.defaultMode.label))", systemImage: "circle.dashed")
                            .tag(ReadingMode?.none)
                    }
                    ForEach(ReadingMode.allCases) { m in
                        Label(m.label, systemImage: m.symbol).tag(Optional(m))
                    }
                }
            } label: {
                chromeIcon("book.pages", tint: Ink.seal)
            }
            .accessibilityLabel("Reading mode")
            .accessibilityInputLabels(["Reading mode", "Mode"])
            .accessibilityValue(modeAccessibilityValue)
            .accessibilityIdentifier("readerModeMenu")
```

Update the file header comment's "The chosen mode is persisted" sentence to say the mode is per Work, via `ReadingModeStore` (ADR-0026).

- [ ] **Step 4: Settings.** Add `@EnvironmentObject private var readingModes: ReadingModeStore` with the other environment objects, and between the Appearance and Updates `VStack`s:

```swift
                    VStack(alignment: .leading, spacing: 14) {
                        InkSectionHeader("Reader", eyebrow: "Reading")
                        Picker("Default reading mode", selection: $readingModes.defaultMode) {
                            ForEach(ReadingMode.allCases) { m in
                                Label(m.label, systemImage: m.symbol).tag(m)
                            }
                        }
                        .accessibilityIdentifier("defaultReadingModePicker")
                        .padding(.horizontal, Gutter.page)
                        Text("Titles you've set a mode for in the reader keep it.")
                            .font(.footnote)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, Gutter.page)
                    }
```

In `#Preview`, add `.environmentObject(ReadingModeStore(works: works))`.

- [ ] **Step 5: Run to verify pass.**
  - `… test -only-testing:MangaCartaUITests/LocalImportUITests` → all three tests pass (run twice; UI tests here can flake once — see memory "flaky live-network UI tests" — a second red is real).
  - Full unit suite: `… test -only-testing:MangaCartaTests` → passes.

- [ ] **Step 6: Mutation check.** Make `modeSelection`'s setter always write `readingModes.defaultMode = newValue` (the old global behaviour). `testReaderModeIsPerTitle` must fail on the value `"Left to Right, default"` / the Settings assertion. Restore with the inverse edit.

- [ ] **Step 7: Docs.** In `CLAUDE.md` "Current state", after the Reader bullet's R→L sentence, add: `Reading mode is **per Work** (ADR-0026): \`ReadingModeStore\` holds each Work's own mode over a default set in Settings; the reader's mode menu sets or clears the Work's own, and a local import's ComicInfo \`Manga\` seeds it.`

- [ ] **Step 8: Lint and commit.**

```bash
swiftlint lint MangaCarta/Views/ReaderView.swift MangaCarta/Views/SettingsView.swift \
  MangaCarta/Services/ReadingModeStore.swift MangaCarta/Models/ReadingMode.swift \
  MangaCarta/Models/ComicInfo.swift MangaCarta/Models/LocalImportViewModel.swift \
  MangaCartaTests/ReadingModeTests.swift MangaCartaUITests/LocalImportUITests.swift
git diff --stat
git add MangaCarta/Views/ReaderView.swift MangaCarta/Views/SettingsView.swift \
  MangaCartaUITests/LocalImportUITests.swift CLAUDE.md
git commit -m "feat(reader): per-title reading mode menu and Settings default (#290)"
```
