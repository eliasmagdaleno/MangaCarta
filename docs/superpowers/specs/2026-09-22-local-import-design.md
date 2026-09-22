# Local import design

**Date:** 2026-09-22
**Status:** Draft for owner review. Nothing here is built. Open questions are numbered at the end.
**Evidence baseline:** `main` at `70317bc`, after the WeebCentral cutover (#201).

## Purpose and ownership

ADR-0003 Amendment 6 (drafted in parallel on `docs/adr-0003-a6-no-bundled-sources`) ships the
App Store build with **no built-in or bundled Source**. An empty reader has no obvious legitimate
purpose for App Review; Paperback, which is on the store, leads with "Komga client". This spec
gives MangaCarta its first-run purpose: **import your own CBZ, ZIP or PDF files through the Files
app and read them in the existing reader.**

This document owns *how* local import is built. The decision that the app ships empty belongs to
the ADR. Terms **Work**, **Listing**, **Listing key**, **Source** and **Pin** are the glossary's
and are used without redefinition. If the owner accepts decision 1 below (local files are a
Source), that choice is an architectural decision and should be promoted to an ADR (or an
ADR-0001 amendment) before slice 1 merges, not left living here.

**Non-goals:** Komga, OPDS, Kavita or any network library (future work, see §9); folder sync or
watch; CBR/RAR, CB7, EPUB; editing metadata beyond rename; cross-device sync of imported files.

## 1. Architecture — local files are a `MangaSource`

**Recommendation:** a compiled `LocalSource` conforming to `MangaSource`, id `local`, registered in
`builtInSources()` by `AppComposition` and always present. It is the one Source the release build
has on first launch.

Why:

- **Everything downstream keys on a Listing key `(sourceId, mangaId)`.** `LibraryStore`,
  `HistoryStore`, `WorkStore`, the reader and the detail page already work from that pair. A
  Source with id `local` and a stable per-item `mangaId` gets Library, History, read marks, the
  unread badge, collections and Work minting for free. A separate path would need a parallel copy
  of each.
- **ADR-0001 holds without a special case.** Importing mints a Work exactly as opening a remote
  title does; the Listing is `local`'s copy. A Work could later gain a MangaDex Listing through
  the existing manual-link path (ADR-0005) — nothing here forbids it.
- **The protocol already fits.** It is bridge-friendly — `String`/`Int` in, values out — and
  `LocalSource` needs nothing more: `mangaDetail(id:)`, `chapters(mangaId:)` and
  `pageURLs(chapterId:preferDataSaver:)` return values built from the on-disk store; `search`
  filters imported titles by name; `popular`/`newTitles`/`latestUpdates` throw
  `SourceError.unsupported` via the existing defaults (or `popular` returns "recently imported"
  — open question 3); `webURL` returns nil.
- **The reader needs no new renderer if pages are files.** `ReaderViewModel` asks for
  `pageURLs`; `ImageCache`'s default fetcher is `URLSession.shared.data(from:)`, which accepts
  `file://` URLs and simply skips the `HTTPURLResponse` status check. `LocalSource` therefore
  returns `file://` URLs to extracted page images (§2, §3).

Trade-offs accepted:

- **It is compiled, not an Extension.** It reads the app container, which the Host API
  deliberately cannot. That is fine: it is host code, not content, and ADR-0003's
  "no site baked in" rule is about remote Sources.
- **Source pickers and Home rails must not treat it as a browse Source.** A "Local" option in the
  Home source picker is acceptable only if its rails are meaningful; otherwise hide it with a
  capability flag. Open question 3.
- **`ImageCache` would copy local pages into its 500 MB disk cache.** Slice 2 adds an
  `isFileURL` bypass so local pages are read directly and never duplicated.
- **`SourceRegistry.sourceForRefresh` falls back to MangaDex for an unknown id.** Harmless today,
  but the refresh skip in §6 must not depend on that fallback.

## 2. Storage — copy into Application Support

**Recommendation:** copy on import into
`Application Support/LocalLibrary/<itemId>/`, where `itemId` is a UUID minted at import and is the
Listing's `mangaId`. Each item directory holds `original.<ext>` (kept, for re-extraction), `pages/`
(extracted images, zero-padded `0001.jpg` …), `cover.jpg` (thumbnail of page one) and
`item.json` (title, source filename, SHA-256, byte size, page count, import date, parsed
ComicInfo fields). A `LocalLibraryStore` owns the index.

Why copy rather than security-scoped bookmarks:

- **iCloud Drive files may be evicted.** A bookmark to a dataless file means every open must
  trigger a download through `NSFileCoordinator` and can fail offline. A copy is always
  readable, which is what a reader is for.
- **Bookmarks go stale** when the user moves or renames the file, and a provider (Google Drive,
  Dropbox) may not honour them at all. Recovering from a stale bookmark is UI nobody wants.
- **Importing from iCloud already requires the bytes.** `fileImporter` with `asCopy`-style
  handling (or `startAccessingSecurityScopedResource` + coordinated read) forces a download
  anyway; keeping the result costs only disk.

Application Support over Documents: Documents is user-visible once `UIFileSharingEnabled` /
`LSSupportsOpeningDocumentsInPlace` are set, which would let users delete `pages/` out from under
the index. Application Support is private, is backed up by iCloud/device backup by default, and is
where `WorkStore` already lives. **Survives reinstall:** no — deleting the app deletes the
container. Restoring from a device backup brings it back. Say so in the delete confirmation and in
Settings.

**Space.** Keeping both `original` and `pages/` roughly doubles use. MVP keeps both (simplest,
lets a better extractor re-run); open question 2 asks whether to drop the original after a
successful extraction. Settings shows total local-library size. `pages/` could instead be marked
`isExcludedFromBackup` since it is re-derivable — recommended.

**Deletion.** Deleting an item removes its directory, its `LibraryStore` entry and its Listing from
the Work; the Work is deleted if that was its only Listing. History entries are kept (as for an
uninstalled Source), so re-importing the same file (same SHA-256 → same `itemId`, see §5) restores
read state.

## 3. Formats

### CBZ / ZIP

No system framework on iOS 17.5 extracts ZIP archives:

- **AppleArchive** reads and writes the `.aar` format only. Its public API documents no ZIP decoder
  (from Apple docs as known to the author; not re-checked against the iOS 17.5 SDK headers).
- **`NSFileCoordinator` with `.forUploading`** zips a *directory* for upload — it creates, it
  does not extract. No reading option unzips.
- **`FileManager`** has no unzip API on iOS.

**Recommendation: a minimal ZIP reader in Swift (~300 lines).** ZIP is simple enough to read
honestly: find the End-of-Central-Directory record by scanning backwards for `0x06054b50`, walk the
central directory for names, sizes, offsets and methods, then for each entry skip its local header
and decode. Only two methods matter for comic archives:

- **0 (stored)** — copy the bytes.
- **8 (deflate)** — raw DEFLATE, which is exactly what `Compression`'s `COMPRESSION_ZLIB` decodes
  (Apple documents it as raw RFC 1951 without the zlib header). Stream with
  `compression_stream` so large entries do not load twice into memory. Verify CRC-32 (a 20-line
  table implementation; `zlib`'s `crc32` is also linkable via `libz`, a system library, which
  does not breach "no third-party dependencies").

Out of MVP, rejected with a clear error: encrypted entries (general-purpose bit 0), ZIP64
(archives or entries over 4 GB — rare for comics), methods other than 0/8 (bzip2, LZMA, zstd).

**Not verified in this document:** that `COMPRESSION_ZLIB` accepts every deflate stream real
CBZ tools emit (it should — it is standard DEFLATE), and streaming throughput on a 500 MB archive
on device. Slice 1's fixture set must include archives from at least two tools (macOS Archive
Utility, `zip` CLI, and ideally a Windows-made CBZ) before this is called done.

### PDF

PDFKit (`PDFDocument`, `PDFPage.thumbnail(of:for:)`) is on iOS 11+. **Recommendation:** rasterise
each page to JPEG at import into `pages/`, at a width of about 2× the largest device's point width
(≈ 2,600 px) so zoom stays sharp. This keeps the reader single-path (file URLs only) at the cost
of import time and disk; a vector-rendering reader path is future work. Password-protected PDFs
are rejected with a clear error in MVP.

### Page selection and ordering

Pure functions, unit-tested:

- Keep entries whose extension is `jpg`, `jpeg`, `png`, `webp`, `gif`, `heic`, `avif`
  (case-insensitive) — then confirm with `CGImageSourceCreateWithData` at extraction and drop
  any that fail to decode. (WebP decodes on iOS 14+; AVIF on iOS 16+.)
- Drop `__MACOSX/`, any path component starting with `.` (`.DS_Store`, `._foo.jpg`),
  `Thumbs.db`, and directories.
- **Nested folders are flattened** in path order: sort by full path using
  `localizedStandardCompare` (Finder's natural sort, so `page2` < `page10`). One archive with
  several chapter folders is still one chapter in MVP (open question 4).
- **Cover** is the first page after sorting, unless ComicInfo marks a page `Type="FrontCover"`.

## 4. Metadata

**Recommendation for MVP: one Work per file, one chapter per Work.** Title comes from the
filename with the extension stripped and underscores turned to spaces. If the CBZ contains
`ComicInfo.xml` at its root, parse (`XMLParser`, pure) `Series`, `Title`, `Number`, `Volume`,
`Summary`, `Writer`, `Genre`, `LanguageISO`, `Manga` (`YesAndRightToLeft` → default R→L) and
`Pages`. When `Series` is present it becomes the display title and `Number`/`Volume` label the
chapter.

**Grouping several files into one Work** (a series of volume CBZs) is the obvious next step and is
deferred to slice 6. When it lands, the rule is: files importing in the same batch **with the same
ComicInfo `Series`** join one Work, each a chapter, ordered by `Volume` then `Number` then natural
filename sort; files without ComicInfo stay one-per-Work unless the user explicitly merges them
("Add to series…"). Guessing series from filenames (`Berserk v01.cbz`) is a heuristic that will be
wrong silently; it should be a suggestion the user confirms, not an automatic merge.

Why not group from the start: one-per-file needs no merge UI, no "split" undo, and no rules for a
chapter later arriving in a different batch. It is enough for App Review and for a first user.

## 5. UX

Visual treatment follows DESIGN.md (Ink & Seal tokens, `InkComponents`); nothing here introduces
new tokens.

- **First-run empty state (Home and Library).** With zero remote Sources and zero imports, Home
  shows a single panel: heading "Read your own manga", body "Import CBZ, ZIP or PDF files from
  Files. MangaCarta does not provide or host content.", primary button **Import files**, secondary
  link **Add a repository** (to Settings). Library's empty state carries the same button and the
  same sentence.
- **Library.** A toolbar **Import** button (`plus`/`square.and.arrow.down`) opens `fileImporter`
  with `allowsMultipleSelection: true` and content types `.pdf`, `.zip`, and a declared
  `com.mangacarta.cbz` imported type conforming to `.zip` with extension `cbz`. Imported items
  land in Library automatically — importing is an explicit "I want this" — and carry a small
  "Local" badge in place of a source name.
- **Settings.** A "Local library" row: item count, disk used, "Import files", and a note that
  imported files are deleted with the app.
- **Open-in.** Declaring the document types also lets Files' "Share → MangaCarta" and
  `onOpenURL` import. Recommended for slice 5; not required for MVP.
- **Progress.** Import runs off the main actor; a non-blocking banner (`ReaderBanner`-style) shows
  "Importing 2 of 5 — Berserk v01" with a determinate bar per file (entries done / total, or PDF
  pages done / total). Cancel stops after the current file and removes its partial directory.
- **Errors** surface per file, never abort the batch: "Not a supported archive", "Encrypted
  archives aren't supported", "No images found", "Password-protected PDFs aren't supported",
  "Not enough storage". Errors become `errorMessage` strings in the view model, per convention.
- **Duplicates** are detected by SHA-256 of the original. A duplicate is skipped with "Already in
  your library" and a button that opens it. Same hash ⇒ same `itemId` across delete/re-import, so
  history reattaches.
- **Deleting.** Swipe or context menu on the Library cell and a "Delete from device" button on the
  detail page, with a confirmation naming the size freed. "Remove from Library" (existing action)
  is *not* delete for local items — open question 5 asks whether they should be merged.

## 6. Reading-state integration

Unchanged, because the Listing key is ordinary:

- **Read marks** use `HistoryStore.markRead/markUnread` with `(local, itemId)` and the chapter id
  `<itemId>/1` (or `<itemId>/<n>` once grouping lands).
- **`isRead`** keeps CLAUDE.md's meaning: read to the end (`ReadingEntry.isComplete`,
  `page >= pageCount - 1`) or manually marked. Page count is known exactly at import, so the
  reader's count and `item.json` always agree.
- **History** records on open like any chapter; the History tab shows local items with their
  cover from `cover.jpg`.
- **Unread badge** counts incomplete chapters as today; a freshly imported item shows "1".

**No update polling.** Local content never changes behind the app's back, so
`LibraryRefreshCoordinator` must never fetch a `local` Listing. Recommended mechanism: add a
protocol requirement `var participatesInUpdates: Bool { get }` (default `true`, `false` for
`LocalSource`) and filter in `eligibleListings(for:workId:)` by looking the Source up in the
registry — not by string-comparing `"local"`, and not by relying on `sourceForRefresh`'s MangaDex
fallback. A Work whose only Listing is local therefore yields no eligible listings, is never
enqueued for a fetch, and never produces an `UpdateEvent` or notification. `MetadataUpgradeQueue`
likewise skips it (no external ids to resolve) unless the owner wants local Works matched to
MangaDex/AniList metadata (open question 6).

## 7. Testing

**Unit (Swift Testing, `MangaCartaTests`; new files need the four pbxproj entries via `xcp`):**

- `ZipReaderTests` — fixtures built in-test from byte literals: stored entry, deflate entry,
  multiple entries, CRC mismatch rejected, encrypted flag rejected, ZIP64 rejected, truncated
  EOCD rejected, archive comment before EOCD handled.
- `PageOrderingTests` — natural sort (`2` < `10`), nested folders flattened, `__MACOSX`,
  `.DS_Store`, `._` files and non-images dropped, case-insensitive extensions.
- `ComicInfoParserTests` — full, partial, malformed XML (falls back to filename), `Manga`
  direction mapping.
- `LocalLibraryStoreTests` — import into a temp directory, duplicate by hash, delete removes
  directory and Listing, re-import restores `itemId`.
- `LocalSourceTests` — `chapters`/`pageURLs` return file URLs in order; unsupported feeds throw.
- `LibraryRefreshCoordinatorTests` — a Work with only a local Listing is never fetched.

**UI (hermetic, XCUITest):** there is no tap tool and `fileImporter`'s system picker is not
drivable reliably, so the test does not go through it. A launch argument
`-uitest-import-fixture <name>` (the pattern `UpdatesUITests` uses for `-uitest-updates-state`)
makes the app import a fixture CBZ bundled in the UI-test target through the *same*
`LocalLibraryStore.import(url:)` the picker calls. `LocalImportUITests` then asserts: the empty
state shows the "does not provide or host content" copy before import; the item appears in
Library; opening it shows page 1; paging to the end marks it read; screenshots attached at each
step. Fixture art is original or public domain (§9). Runs on iPhone 17 Pro locally; the test must
not depend on grid position (CI's UI device is iPhone 16 Pro).

## 8. Slices

Each slice is independently mergeable and leaves the app working.

1. **ZIP reader + page ordering (pure).** `ZipReader`, `PageSelector` in `Models/`. No UI.
   *Accept:* `ZipReaderTests` and `PageOrderingTests` green, including fixtures from two tools.
2. **Local library store + `LocalSource`, CBZ/ZIP only.** Storage layout (§2), SHA-256 dedupe,
   `LocalSource` registered, `ImageCache` file-URL bypass, `participatesInUpdates`.
   *Accept:* `LocalLibraryStoreTests`, `LocalSourceTests`, and the refresh-skip test in
   `LibraryRefreshCoordinatorTests` green.
3. **Import UI + empty states.** `fileImporter`, progress banner, per-file errors, delete,
   Settings row, first-run copy; `-uitest-import-fixture` hook.
   *Accept:* `LocalImportUITests` green on the hermetic CI suite.
4. **PDF.** PDFKit rasterisation into the same layout. *Accept:* `PDFImportTests` (a 3-page
   generated PDF yields 3 ordered pages and a cover).
5. **ComicInfo.xml + open-in.** Parser, title/number/direction; document types for Share-to.
   *Accept:* `ComicInfoParserTests` green; `LocalLibraryStoreTests` asserts Series wins over
   filename.
6. **Series grouping** (after owner sign-off on §4). *Accept:* a test that three CBZs with the
   same `Series` import as one Work with three chapters ordered by `Volume`.

## 9. App Store angle

The listing leads with the feature the app actually has on install: **"A reader for your own
manga and comics. Import CBZ, ZIP and PDF from Files, iCloud Drive or any storage provider."**
Repositories and Sources are described second and neutrally, as user-added. The description and
the review notes both repeat "MangaCarta does not provide or host content." The review notes
should include a small original CBZ the reviewer can import, so the first minute of review is a
working reader rather than an empty screen.

Screenshots: empty state with the import panel; Library with imported covers; the paged reader;
the webtoon reader; read marks and the unread badge. **All art must be public domain or
original** — e.g. pre-1929 public-domain comic strips, or pages drawn/commissioned for the
purpose — never a screenshot of a Source's catalog. The same fixtures serve the UI test.

A Komga/OPDS client is the natural next "legitimate purpose" and fits the same Source-shaped
seam; it is future work, not part of this spec.

## Open questions for the owner

1. Accept local files as a compiled `MangaSource` with id `local` (decision 1)? If yes, promote it
   to an ADR (or ADR-0001 amendment) before slice 1.
2. Keep `original.<ext>` after extraction (≈2× disk, allows re-extraction), or delete it?
3. Should `local` appear in the Home source picker with rails (e.g. "Recently imported",
   "Continue reading"), or be hidden from browse entirely and live only in Library?
4. An archive containing several chapter folders: one chapter (MVP), or one chapter per
   top-level folder?
5. For local items, should "Remove from Library" and "Delete from device" be one action?
6. Should a local Work be eligible for metadata resolution (MangaDex/AniList cover, synopsis,
   MAL progress sync) via `MetadataUpgradeQueue`, or stay purely local?
7. Series grouping (slice 6): ComicInfo `Series` only, or also a confirmed filename heuristic?
8. Is the ≈2,600 px PDF rasterisation width acceptable, or is a vector PDF reader path wanted
   before release?
9. Who produces the original/public-domain screenshot and review-fixture art?
