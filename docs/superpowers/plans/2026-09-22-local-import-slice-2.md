# Local import slice 2 — `LocalLibraryStore` + `LocalSource` (CBZ/ZIP)

**Status (2026-09-25): implemented by #225.** This is the plan as written against the
2026-09-22 baseline, retained as an implementation record. Later local-import UI, PDF,
and follow-up work landed in #236, #235, and #246; consult the
[local import spec](../specs/2026-09-22-local-import-design.md) and current code for
remaining work.

**Date:** 2026-09-22
**Spec:** [`docs/superpowers/specs/2026-09-22-local-import-design.md`](../specs/2026-09-22-local-import-design.md) (PR #216), §§1–3, 6, 7, slice 2 in §8.
**Decision:** [ADR-0025](../../adr/0025-local-files-as-a-source.md) (PR #216). Owner answers are recorded in the spec's "Decisions" section; this plan does not restate them, it builds them.
**Depends on:** slice 1, PR #217 (`ZipArchiveReader` + `PageSelector`, branch `eliasmagdaleno/local-import-zip-reader`) — **being reworked**. This plan is written against its public API as of 2026-09-22 (quoted in "Slice 1 contract" below). Re-check that section against the merged #217 before Task 4; only Task 4 touches it.
**Evidence baseline:** `main` at `8e8f256`. Every `file:line` below was grepped at that commit.

## Decisions (owner, 2026-09-22)

Answers to the five questions this plan first raised on #222:

1. **`itemId` = lowercase hex of the first 16 bytes of the file's SHA-256.** Re-import of the same bytes restores the same id, so history reattaches. This resolves the spec's §2 ("UUID minted at import") vs §5 ("same hash ⇒ same `itemId`") contradiction in favour of §5.
2. **One top-level folder plus loose root images → two chapters:** the root images as the leading chapter, then the folder. A single folder with no root images stays one chapter.
3. **"Original deleted after unpacking" means the app's staged copy only.** The user's file in Files is never modified or deleted.
4. **`local` Works are kept out of the MAL update queue entirely** — no enqueued and no deferred outbox row (guard + test in Task 8).
5. **Settings › About › Sources lists browsable Sources only**, so "Local" is hidden (Task 6).

## Scope

In: `LocalLibraryStore` (import into `Application Support/LocalLibrary/`, staging-then-move, temp copy deleted, SHA-256 dedupe, delete), `LocalSource` (id `local`, compiled, always registered), two new `MangaSource` capabilities (`isBrowsable`, `participatesInUpdates`), registry/refresh/metadata-queue exclusions, `ImageCache` file-URL bypass, `WorkStore` listing removal.

Out (slice 3+): `fileImporter`, progress banner, the "Delete from Device" button and its confirmation copy, empty-state copy, Settings row, `-uitest-import-fixture`, PDF, ComicInfo, series grouping. Slice 2 ships the store-level `delete(itemId:)` that slice 3's button will call.

## Conventions for every task

- TDD: write the test, run it red, implement, run it green, commit. One commit per task.
- Run a single suite: `xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:MangaCartaTests/<Suite>`. Parallel testing stays on.
- **New files in `MangaCartaTests/` need `xcp`** (`xcp add-file "$PWD/MangaCarta.xcodeproj" --file "$PWD/MangaCartaTests/X.swift" --targets MangaCartaTests`). New files in `MangaCarta/Models/` and `MangaCarta/Services/` are synchronized — no pbxproj edit. Check `git diff --stat` on `project.pbxproj` **immediately before** `git add` (CLAUDE.md, "Adding files").
- **CI is Swift 6.0 / Xcode 16.4.** No isolated conformances (`extension X: @MainActor P`), no `nonisolated(nonsending)`, no `@concurrent`, no `Task.immediate`. Use an `actor` or a lock-protected `final class ... : @unchecked Sendable` for the store.
- **"Real on-disk path"** means: tests build a real archive file in a per-test temporary directory (`FileManager.default.temporaryDirectory/UUID`), give the store that directory as its root, and assert on what `FileManager` finds afterwards. No in-memory fakes of the file system. Every test removes its temp root in `deinit`/`defer`.
- Test framework: match the file you extend; new suites use Swift Testing (`@Test`, `#expect`, `#require`).

## Integration points (verified)

| Point | Where | What slice 2 does |
|---|---|---|
| `MangaSource` protocol | `MangaCarta/Models/MangaSource.swift:18` (requirements to `:72`) | Add `isBrowsable` and `participatesInUpdates` as **protocol requirements** — the note at `:58-60` says extension-only members dispatch statically through `any MangaSource` and always hit the default. Defaults (`true`) go in the extension at `:106`. |
| Default feeds | `MangaSource.swift:115`, `:119`, `:131` | `newTitles`/`latestUpdates`/`webURL` defaults already fit `local`; `popular` and `mangaByTag` must be implemented to throw / use default. |
| Built-in set | `MangaCarta/Services/SourceRegistry.swift:73-75` (`builtInSources()` = `[MangaDexSource()]`) | Append `LocalSource(store: .shared)`. |
| Active-source fallback | `SourceRegistry.swift:49-70` (`sources[0].id` at `:68`), `:84-88` (`setInstalledSources`), `:92-94` (`active`), `:103-106` (`source(for:)`) | Fallback must pick the first **browsable** source, never `local`. |
| Picker list | `SourceRegistry.swift:115-117` (`visibleSources`) — consumed by Home `MangaCarta/Views/HomeView.swift:57`, Search `Views/SearchView.swift:44,73`, Settings `Views/SettingsView.swift:113,173` | Filter `isBrowsable`. |
| Refresh fallback | `SourceRegistry.swift:109-112` (`sourceForRefresh` falls back to MangaDex) | Untouched; the refresh skip must not depend on it (spec §1). |
| Update polling | `MangaCarta/Services/LibraryRefreshCoordinator.swift:103` → `eligibleListings(for:workId:)` at `:196-201`; fetch at `:166-168` | Filter out listings whose registered Source has `participatesInUpdates == false`. |
| Legacy refresh path | `MangaCarta/Services/LibraryStore.swift:282-298` (used only when no coordinator is configured) | Same skip, so the fallback path cannot fetch `local` either. |
| Metadata queue | `MangaCarta/Services/MetadataUpgradeQueue.swift:56-79` (init, **no registry**), `nextCandidate` at `:337-349` | Inject a `listingParticipates: (ListingKey) -> Bool` (default `{ _ in true }`); skip a Work none of whose listings participate. Wired at `MangaCarta/Services/AppComposition.swift:367`. |
| MAL sync | `MangaCarta/Services/MALProgressCoordinator.swift:125-146` (`chapterCompleted`) | Guard added: `local` completions are never enqueued or deferred (decision 4, Task 8). |
| Image loading | `MangaCarta/Services/ImageCache.swift:136-137` (default fetcher), `:163-177` (`loadImage` stores to disk at `:175`) | `isFileURL` → read file, memory tier only, never `disk.store`. |
| Composition | `AppComposition.swift:245` (`registry:` param), `:333-334` (refresh coordinator), `:367` (metadata queue), `:433` (`registry ?? .shared`) | Pass registry lookups into the queue. |
| Work removal | `MangaCarta/Services/WorkStore.swift` — has `mint(from:)` `:111`, `workId(for:)` `:78`, `merge` `:268`, **no removal API** | Add `removeListing(_:)` (deletes the Work when it was the last Listing). |
| Library removal | `LibraryStore.swift:139` (`toggle(_ manga:)`), `:106` (`contains`) | Store-level delete calls it; no new API. |
| Source names | `Views/MangaDetailView.swift:56`, `Views/SettingsView.swift:192` (About row lists every `registry.sources` name) | `local`'s `name` is "Local". Settings About lists browsable Sources only (decision 5, Task 6). |

## Slice 1 contract (PR #217, subject to rework)

`MangaCarta/Services/ZipArchiveReader.swift` (#217):

- `ZipArchiveReader(url:limits:) throws` / `(data:limits:)` — **reads the whole archive into memory** (`Data(contentsOf:)`); default `Limits` cap total uncompressed at 512 MB.
- `chapters() throws -> [ZipArchiveReader.Chapter]` — `Chapter { name: String; pages: [Entry] }`, built by `PageSelector.chapters` (junk dropped, extension + magic-byte check, natural sort, grouped by first path component; root images become a chapter named `"Root"`).
- `data(for: Entry) throws -> Data` — CRC-checked bytes.
- `extract(_:to:)` writes entries under their **archive paths** — slice 2 does **not** use it, because the layout needs `pages/<n>/0001.<ext>`.
- `ZipArchiveError`: `.truncated`, `.corrupt`, `.zip64`, `.encrypted`, `.unsupportedCompression`, `.pathTraversal`, `.sizeLimit`, `.compressionBomb`, `.invalidImage`.

Two gaps between #217 and the spec that slice 2 closes locally (Task 4), so it does not block on the rework:

1. **Chapter rule.** #217 makes every top-level folder its own group. The spec (§3) wants a *single* wrapper folder to be one chapter and "Root" only as a *leading* chapter beside two-or-more folders. `LocalChapterLayout.normalize(_:)` applies that plus decision 2: a single folder with no root images → one chapter; root images beside one or more folders → a leading root chapter, then one chapter per folder.
2. **`heic`** is in the spec's extension list but not #217's. Not added here; flag to #217.

If the reworked #217 already returns the spec's chapter shape, Task 4 shrinks to an assertion that it does.

## Storage layout (spec §2)

```
Application Support/LocalLibrary/
  .staging/<uuid>/            — in-flight import; never read by LocalSource
  <itemId>/
    item.json                 — LocalItemRecord (below)
    cover.jpg                 — ImageIO thumbnail of chapter 1 page 1, 512 px long edge
    pages/1/0001.jpg …        — chapter n (1-based), pages zero-padded, original extension kept
    pages/2/0001.png …
```

`itemId` = lowercase hex of the first 16 bytes of the file's SHA-256 (32 chars). Spec §5 requires "same hash ⇒ same `itemId` across delete/re-import" so History reattaches; §2's "UUID minted at import" cannot deliver that, so the id is derived from the hash (decision 1).

`LocalItemRecord: Codable` — `itemId`, `title` (filename, extension stripped, `_` → space), `sourceFilename`, `sha256` (full hex), `byteSize`, `importedAt`, `chapters: [{ number: Int, title: String, pageCount: Int, pageFiles: [String] }]`.

Chapter id = `"<itemId>/<n>"` (spec §6).

---

## Tasks

### Task 1 — `MangaSource` gains `isBrowsable` and `participatesInUpdates`

Files: `MangaCarta/Models/MangaSource.swift`; test `MangaCartaTests/SourceCapabilityTests.swift` (**new, `xcp`**).

- Add both as `{ get }` requirements in the protocol body (after `latestRailShowsNewBadge`, `:72`), with a doc comment repeating why they are requirements. Default `true` in the extension at `:106`.
- Tests:
  - `defaultsAreTrueThroughExistential` — a minimal test `MangaSource` that does not override: `(source as any MangaSource).isBrowsable == true`, same for `participatesInUpdates`.
  - `overrideIsReachedThroughExistential` — a source overriding both to `false`, read through `any MangaSource`, reports `false`. **This is the regression test for the `:58-60` trap**: it fails if someone moves the members to extension-only.

### Task 2 — `LocalLibraryStore`: import one CBZ into the real layout

Files: `MangaCarta/Services/LocalLibraryStore.swift` (new, synchronized), `MangaCarta/Models/LocalItemRecord.swift` (new, synchronized); tests `MangaCartaTests/LocalLibraryStoreTests.swift` (**new, `xcp`**), `MangaCartaTests/ZipFixtureWriter.swift` (**new, `xcp`**) — a test-only stored-method (method 0) ZIP writer with CRC-32 that writes `[path: Data]` to a URL, plus a tiny valid 1×1 PNG and JPEG byte constant. (#217's `makeArchive` is `private` to its suite; if the rework exposes a shared helper, use it instead.)

API (an `actor`, root injectable, `static let shared` rooted at `WorkStore.applicationSupportDirectory()/LocalLibrary`):

```swift
actor LocalLibraryStore {
    init(root: URL)
    func importArchive(at source: URL) throws -> LocalImportResult   // .imported(record) | .duplicate(itemId)
    func record(itemId: String) -> LocalItemRecord?                   // reads item.json from disk
    func allRecords() -> [LocalItemRecord]
    func pageURLs(itemId: String, chapter: Int) -> [URL]
    func coverURL(itemId: String) -> URL?
    func delete(itemId: String) throws
}
```

Flow of `importArchive`: create `.staging/<uuid>/`; **copy** `source` to `.staging/<uuid>/archive` (decision 3: the user's file in Files is never modified or deleted — the picker's URL may be the original, security-scoped; only this staged copy is deleted); hash the copy (CryptoKit `SHA256`, streamed in 1 MB chunks); if `<root>/<itemId>/item.json` exists → delete staging, return `.duplicate`; else open `ZipArchiveReader(url:)` on the copy, write pages via `data(for:)` into `.staging/<uuid>/item/pages/<n>/NNNN.<ext>`, write `cover.jpg` and `item.json`, **delete the archive copy**, `moveItem` `.staging/<uuid>/item` → `<root>/<itemId>`, remove `.staging/<uuid>`. Any throw → remove `.staging/<uuid>` and rethrow. The UUID is only the staging name; the persistent id is the hash-derived `itemId`.

Tests (each on a real temp root and a real `.cbz` written by `ZipFixtureWriter`):
- `importWritesPagesCoverAndRecord` — 3-page flat CBZ → `<root>/<itemId>/pages/1/0001.png…0003.png` exist, `cover.jpg` decodes with `UIImage(contentsOfFile:)`, `item.json` decodes with `pageCount == 3` and `sha256` equal to an independently computed hash of the fixture.
- `importKeepsNoArchive` — after import, enumerate `<root>` recursively: no file with extension `cbz`/`zip`, and no file named `archive`; `.staging` is empty or absent.
- `importLeavesUserFileUntouched` — the source URL still exists with identical bytes.
- `itemIdIsDerivedFromContentHash` — same bytes under two filenames → same `itemId`.

### Task 3 — duplicates, failures and delete

Files: same as Task 2.

- `duplicateImportIsSkipped` — import the same bytes twice (different filenames): second returns `.duplicate(itemId)`, directory count under `<root>` (excluding `.staging`) is 1, `item.json` unchanged (compare modification date).
- `failedExtractionLeavesNothingBehind` — a CBZ whose second entry has a corrupted CRC (writer flag) → `importArchive` throws; `<root>` contains no `<itemId>` directory and `.staging` is empty. Repeat with a zero-image archive (only `ComicInfo.xml` + `.DS_Store`) → throws `LocalImportError.noImages`, same assertions.
- `stagingIsNeverListed` — plant a stray `.staging/<uuid>/item/item.json`; `allRecords()` does not return it. `init` removes leftover `.staging` contents (crash recovery) — assert the directory is empty after a fresh `LocalLibraryStore(root:)`.
- `deleteRemovesItemDirectory` — import, `delete(itemId:)`, `<root>/<itemId>` gone, `record(itemId:)` nil.
- `reimportAfterDeleteRestoresItemId` — import, delete, import same bytes → `.imported` with the same `itemId`.

`LocalImportError`: `.noImages`, `.unreadableArchive(ZipArchiveError)`, `.insufficientSpace`. Slice 3 maps these to the spec §5 strings.

### Task 4 — chapter layout from `ZipArchiveReader.chapters()`

Files: `MangaCarta/Models/LocalChapterLayout.swift` (new, synchronized); tests `MangaCartaTests/LocalChapterLayoutTests.swift` (**new, `xcp`**) plus cases in `LocalLibraryStoreTests`.

`LocalChapterLayout.normalize(_ chapters: [ZipArchiveReader.Chapter]) -> [LocalChapter]` — pure. Rules from spec §3: two or more folder groups → one chapter each, natural order, titled by folder name, a `"Root"` group first if present; root images beside a *single* folder → two chapters, root first then the folder (decision 2); one folder with no root images, or root images only → a single chapter titled by the item title, pages in natural path order (deeper nesting already flattened by path sort).

Pure tests (entries built from `ZipArchiveReader(data:)` over `ZipFixtureWriter` bytes — `Entry`'s init is not public):
- `twoTopLevelFoldersYieldTwoChapters` — `Ch 10/…`, `Ch 2/…` → `["Ch 2", "Ch 10"]`.
- `singleWrapperFolderYieldsOneChapter` — `Title/001.png, Title/002.png` → one chapter, 2 pages.
- `rootImagesBesideSingleFolderFormLeadingChapter` — `cover.png`, `Title/001.png`, `Title/002.png` → 2 chapters: root (1 page), then `Title` (2 pages) (decision 2).
- `rootImagesBesideFoldersFormLeadingChapter` — `cover.png`, `A/…`, `B/…` → 3 chapters, first is root.
- `deeperNestingIsFlattenedInPathOrder` — `A/x/1.png, A/y/1.png`, `B/1.png` → chapter A has 2 pages in `x` then `y` order.

On-disk test (`LocalLibraryStoreTests`):
- `twoFolderArchiveWritesTwoChapterDirectories` — `pages/1/` and `pages/2/` both exist with the right counts, `item.json.chapters.count == 2`.

### Task 5 — `LocalSource`

Files: `MangaCarta/Models/LocalSource.swift` (new, synchronized); tests `MangaCartaTests/LocalSourceTests.swift` (**new, `xcp`**).

`struct LocalSource: MangaSource` — `static let sourceID = "local"`, `name = "Local"`, `isBrowsable = false`, `participatesInUpdates = false`, `homeFeedCapabilities = []`, `imagePrefetchConcurrency` high (local reads are cheap). Methods read through the injected `LocalLibraryStore`:
- `mangaDetail(id:)` / `search(title:…)` build `Manga` with `sourceId: "local"` (CLAUDE.md's "stamp `sourceId` on every conversion path" rule), `coverURL` = file URL of `cover.jpg`, `malId: nil`.
- `chapters(mangaId:)` → `Chapter(id: "<itemId>/<n>", number: "\(n)", title: chapter title)`.
- `pageURLs(chapterId:preferDataSaver:)` → `file://` URLs in page order; unknown id throws.
- `popular`, `mangaByTag` throw `SourceError.unsupported`; `newTitles`/`latestUpdates`/`webURL` use defaults.

Tests (store on a temp root, populated by a real `importArchive`):
- `chaptersAndPageURLsAreFileURLsInOrder` — two-folder archive: 2 chapters; each `pageURLs` is `isFileURL`, exists on disk, names ascend `0001…`.
- `everyConversionStampsLocalSourceId` — `search` and `mangaDetail` results have `sourceId == "local"`.
- `searchFiltersImportedTitlesByName` — two imports, query matches one.
- `unsupportedFeedsThrow` — `popular`, `newTitles`, `latestUpdates` throw `SourceError.unsupported`.
- `deletedItemFailsAsMissing` — after `store.delete`, `chapters(mangaId:)` throws (not an empty list).

### Task 6 — registry: always registered, never browsed

Files: `MangaCarta/Services/SourceRegistry.swift`, `MangaCarta/Views/SettingsView.swift` (About row, `:192` — change `registry.sources` to `registry.visibleSources(includeAdult: showAdultSources)` or a `isBrowsable` filter, so "Local" is hidden; decision 5); tests: add to `MangaCartaTests/RegistryInjectionTests.swift` (exists — no `xcp`) or a new `SourceRegistryTests.swift` (**`xcp`**; spec §7 names this suite).

- `builtInSources()` (`:73`) → `[MangaDexSource(), LocalSource(store: .shared)]`.
- Add `private var firstBrowsable: MangaSource?`; replace the three `sources[0]` fallbacks (`:68`, `:87`, `:93`) with it. `visibleSources` (`:115`) filters `$0.isBrowsable`. `enforceAdultGating` already goes through `visibleSources`.
- Tests:
  - `visibleSourcesNeverIncludesLocal` — registry of `[LocalSource, MockSource]` (local **first**, the worst case) → `visibleSources(includeAdult: true)` ids == `["mock"]`.
  - `activeFallbackSkipsNonBrowsable` — same registry, stored active id `"local"` (via `UserDefaults` suite or `-uitest-source` equivalent) → `active.id == "mock"`.
  - `localIsResolvableById` — `source(id: "local")` is the `LocalSource`; `source(for: manga)` with `sourceId "local"` returns it, not the active source.
  - `aboutSourceNamesExcludeLocal` — the name list the About row renders (extract it to a small registry helper, e.g. `browsableSourceNames`, so it is testable without UI) omits "Local".
  - `productionBuiltInsContainLocal` — `SourceRegistry()` (no injection) contains `"local"`.

**Conflict with zero-sources slice 1** (branch `eliasmagdaleno/zero-sources-slice-1`, not yet committed as of this plan): it makes `active` optional and removes MangaDex from `builtInSources()`. Both branches edit `:49-117`. Whichever lands second must (a) keep `LocalSource` in `builtInSources()` so the `precondition(!sources.isEmpty)` at `:50` still holds — or drop the precondition if zero-sources already did; (b) express `firstBrowsable` as the optional `active` — `local` must never become the non-nil answer; (c) make "is there a browse Source" mean `!visibleSources(includeAdult: true).isEmpty`, **never** `!sources.isEmpty`, since `local` is always there (spec §1: not "a Source installed"). Call-sites that read `registry.active` today: `Models/HomeViewModel.swift:36`, `Models/SearchViewModel.swift:67`, `SourceRegistry.swift:104`, `:110`. Recommend landing zero-sources first and rebasing this task onto it.

### Task 7 — update polling skips `local`

Files: `MangaCarta/Services/LibraryRefreshCoordinator.swift` (`:196-201`), `MangaCarta/Services/LibraryStore.swift` (`:295-299`); tests: `MangaCartaTests/LibraryRefreshCoordinatorTests.swift` (exists).

- `eligibleListings` additionally requires `registry.source(id: listing.sourceId)?.participatesInUpdates ?? true` — unknown ids keep today's behaviour (MangaDex fallback), and the check is on the capability, not the string `"local"`.
- Legacy path in `LibraryStore.refresh()` filters the same way before building `current`.
- Tests (registry with a counting mock source and a `LocalSource` over a temp store with one real import; Work minted via `WorkStore.mint(from:)` for the local `Manga`; item added to Library):
  - `localOnlyWorkIsNeverFetched` — `refreshLibrary()` → `LocalSource` spy/wrapper reports zero `chapters` calls; `UpdateStateStore` has no entry for the Work; no `UpdateEvent` returned.
  - `nonParticipatingMockIsSkippedByCapability` — a mock with id `"not-local"` and `participatesInUpdates = false` is skipped too (proves no id string match).
  - `remoteListingsStillFetched` — the mock remote Work in the same run is fetched once.

### Task 8 — metadata queue and MAL skip `local`

Files: `MangaCarta/Services/MetadataUpgradeQueue.swift` (`:56-79`, `:337-349`), `MangaCarta/Services/AppComposition.swift` (`:367`); tests: `MangaCartaTests/MetadataUpgradeQueueTests.swift` (exists), `MangaCartaTests/AppCompositionTests.swift` (exists).

- Add init param `listingParticipates: @escaping (ListingKey) -> Bool = { _ in true }`; `nextCandidate` drops Works where `!work.listings.contains(where: listingParticipates)`. Keep the closure non-`@Sendable`/main-actor like the rest of the queue — no isolated-conformance tricks.
- Composition passes `{ [registry] key in registry.source(id: key.sourceId)?.participatesInUpdates ?? true }` using the graph's registry (not `.shared`; CLAUDE.md "injected, not reached for").
- Tests:
  - `localOnlyWorkIsNeverEnqueued` — `WorkStore` on a temp directory with one local-only Work, stubbed AniList that records calls → `drainOnce` returns `.idle`-equivalent, zero AniList calls.
  - `mixedStoreStillUpgradesRemoteWork` — plus one remote Work → exactly the remote one is attempted.
  - `compositionWiresRegistryIntoQueue` (AppCompositionTests) — build the graph with a temp directory, mint a local Work, drain once; no AniList request.
- **MAL guard (decision 4):** `local` Works are kept out of the MAL queue entirely. `MALProgressCoordinator.chapterCompleted` (`MALProgressCoordinator.swift:125`) gains an injected `listingParticipates`-style predicate (same composition closure, default `{ _ in true }`) and returns before `outbox.enqueue`/`outbox.defer` when the completion's listing (`ListingKey(completion.manga)`) does not participate. This supersedes the earlier "no code change" note in the integration table.
  - `localCompletionNeverReachesMALOutbox` (in the existing MAL coordinator tests file — grep for it; else new, **`xcp`**) — signed-in stand-in account with a real `MALProgressOutbox` on a temp directory, `chapterCompleted` for a local Work (`malId` nil) → the outbox on disk holds **no** item, neither enqueued nor deferred; a remote completion in the same test still defers.

### Task 9 — `ImageCache` reads file URLs directly

Files: `MangaCarta/Services/ImageCache.swift` (`:163-177`); tests: `MangaCartaTests/ImageCacheTests.swift` if it exists (grep), else new (**`xcp`**).

- In `loadImage(for:)` (and the prefetch path that calls it), `if url.isFileURL` → `Data(contentsOf:)` off the main actor, `UIImage(data:)`, set memory tier, **return before** `disk.data`/`disk.store`.
- Tests (disk cache rooted in a temp directory):
  - `fileURLIsNotCopiedIntoDiskCache` — load a real PNG written to temp → image non-nil; the disk-cache directory has no new file.
  - `fileURLDoesNotHitFetcher` — injected `fetcher` that records calls → zero calls.
  - `missingFileReturnsNil` — no crash, nil.

### Task 10 — `WorkStore.removeListing` and the store-level delete

Files: `MangaCarta/Services/WorkStore.swift`; `MangaCarta/Services/LocalLibraryStore.swift` stays file-only; a small `@MainActor` coordinator `MangaCarta/Services/LocalLibraryDeletion.swift` (new, synchronized) that performs spec §2's delete in order: `LocalLibraryStore.delete(itemId:)` → `LibraryStore.toggle` if `contains` → `WorkStore.removeListing(ListingKey(sourceId: "local", mangaId: itemId))`. History is **not** touched. Slice 3's button calls this.

Tests: `MangaCartaTests/WorkStoreTests.swift` (exists), `MangaCartaTests/LocalLibraryDeletionTests.swift` (**new, `xcp`**).
- `removeListingDeletesWorkWhenLast` — mint a local Work, remove its only Listing → `workId(for:)` nil, `work(id)` nil, and after `flush()` a fresh `WorkStore(directory:)` on the same directory agrees (proves persistence).
- `removeListingKeepsWorkWithOtherListings` — Work with two Listings → one remains.
- `deleteRemovesDirectoryLibraryEntryAndListing` — real import into temp store, Library add, Work mint, `HistoryStore` record → after delete: directory gone, `LibraryStore.contains` false, Work gone, **history entry still present**.
- `reimportReattachesHistory` — continuing the above, re-import → same `itemId`, `HistoryStore` read state for `"<itemId>/1"` is back.

### Task 11 — composition smoke and full suite

Files: `MangaCartaTests/AppCompositionTests.swift`.
- `graphRegistryContainsLocalSource` — `AppComposition(directory: temp, …).registry.source(id: "local")` non-nil and not in `visibleSources`.
- Then run the whole unit suite on iPhone 17 Pro. Expect registry-count assertions elsewhere (e.g. `BundledWeebCentralCutoverTests`, `AdultSourceGatingTests`, `RegistryInjectionTests`) to need `local` accounted for — fix by asserting on `visibleSources`, not by special-casing `local`. Re-run once before blaming this branch (memory: shared-simulator contention).

## Acceptance (spec §8, slice 2)

`LocalLibraryStoreTests`, `LocalChapterLayoutTests`, `LocalSourceTests` (two-folder archive → two chapters), `SourceRegistryTests`/`RegistryInjectionTests`, `MetadataUpgradeQueueTests`, the refresh-skip tests in `LibraryRefreshCoordinatorTests`, and the full unit suite green locally; CI green on Xcode 16.4. No UI change is visible yet except that "Local" never appears in any picker.

## Docs owed on landing

- `CLAUDE.md` "Current state": one bullet that `LocalSource` exists and is always registered (it owns implementation state).
- `docs/glossary.md`: nothing new unless "Local library" is adopted as a term.
- The live handoff carries slices 3–6.
