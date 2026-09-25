# Local import design

**Date:** 2026-09-22
**Status:** Accepted design decisions from 2026-09-22 (see "Decisions" at the end); one owner item remains. For current implementation status, see `CLAUDE.md` and the live handoff.
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
Source) — the architectural decision is
[ADR-0025](../../adr/0025-local-files-as-a-source.md), which also records why it is compatible with
ADR-0003 Amendment 6 ([#215](https://github.com/eliasmagdaleno/MangaCarta/pull/215)).

**Non-goals:** Komga, OPDS, Kavita or any network library (future work, see §9); folder sync or
watch; CBR/RAR, CB7, EPUB; editing metadata beyond rename; cross-device sync of imported files;
matching local Works to MangaDex/AniList/MAL; a vector PDF reader. See §10.

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
  `SourceError.unsupported`; `webURL` returns nil.
- **The reader needs no new renderer if pages are files.** `ReaderViewModel` asks for
  `pageURLs`; `ImageCache`'s default fetcher is `URLSession.shared.data(from:)`, which accepts
  `file://` URLs and simply skips the `HTTPURLResponse` status check. `LocalSource` therefore
  returns `file://` URLs to extracted page images (§2, §3).

Trade-offs accepted:

- **It is compiled, not an Extension.** It reads the app container, which the Host API
  deliberately cannot. That is fine: it is host code, not content, and ADR-0003's
  "no site baked in" rule is about remote Sources.
- **It is not a browse Source.** Decided: `local` appears in Library only, never in the Home
  source picker. `SourceRegistry.visibleSources` excludes it through a declared capability
  (`isBrowsable`, default `true`) rather than an id comparison, and the Home empty state must not
  treat "`local` is registered" as "a browse Source exists".
- **`ImageCache` would copy local pages into its 500 MB disk cache.** Slice 2 adds an
  `isFileURL` bypass so local pages are read directly and never duplicated.
- **Refresh eligibility must use the Source's declared capability.** An unknown Source and a
  local Listing must not be sent through a fallback Source.

## 2. Storage — copy into Application Support

**Recommendation:** copy on import into
`Application Support/LocalLibrary/<itemId>/`, where `itemId` is the first 16 bytes of the
imported file's SHA-256 digest, encoded as 32 hexadecimal characters, and is the Listing's `mangaId`. Each item directory holds `pages/<chapter>/` (extracted images, zero-padded
`0001.jpg` …, one subdirectory per chapter), `cover.jpg` (thumbnail of page one) and
`item.json` (title, source filename, SHA-256, byte size, page count, import date, parsed
ComicInfo fields). A `LocalLibraryStore` owns the index. **The original archive is not kept:**
it is unpacked from a temporary copy, which is deleted once extraction succeeds.

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

**Space.** Only unpacked pages are kept (decided), so an item costs roughly its archive's size.
Settings shows total local-library size. Because `pages/` is now the *only* copy, it is **not**
excluded from backup — a device restore is the one path that survives a reinstall. Consequences
of not keeping the original: a better extractor cannot re-run on old imports (re-import instead),
and the SHA-256 used for duplicate detection is computed during import and stored in `item.json`.
Extraction writes to a staging directory moved into place only on success, so a failed import
leaves nothing behind.

**Deletion.** Decided: for local items, "Remove from Library" *is* "Delete from device" — one
action. It removes the item's directory, its `LibraryStore` entry and its Listing from the Work;
the Work is deleted if that was its only Listing (a local Work outside Library would be an
unreachable orphan). History entries are kept (as for an
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
- **Chapters from top-level folders (decided).** After junk is dropped, if the images sit in
  **two or more top-level folders**, each top-level folder is one chapter, ordered by natural sort
  of folder name and titled by it. Root images beside such folders form a leading chapter. With a
  single top-level folder (the common `Title/001.jpg` wrapper) or none, the archive is one
  chapter. Deeper nesting inside a chapter folder is flattened in path order.
- **Natural sort** everywhere: `localizedStandardCompare` (Finder's order, so `page2` < `page10`).
  It is locale-sensitive, so tests pin the locale.
- **Cover** is the first page after sorting, unless ComicInfo marks a page `Type="FrontCover"`.

## 4. Metadata

**MVP: one Work per file; one chapter per file, or one per top-level folder (§3).** Title comes from the
filename with the extension stripped and underscores turned to spaces. If the CBZ contains
`ComicInfo.xml` at its root, parse (`XMLParser`, pure) `Series`, `Title`, `Number`, `Volume`,
`Summary`, `Writer`, `Genre`, `LanguageISO`, `Manga` (`YesAndRightToLeft` → default R→L) and
`Pages`. When `Series` is present it becomes the display title and `Number`/`Volume` label the
chapter.

**Grouping several files into one Work** is slice 6 and uses **ComicInfo `Series` only**
(decided). A file whose `Series` equals (case- and whitespace-normalised) that of an existing local
Work joins it — in the same batch or later — with chapters ordered by `Volume`, then `Number`,
then natural filename sort. Files without ComicInfo `Series` are always one Work each. No filename
heuristic and no manual merge in v1.

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
- **Duplicates** are detected by the SHA-256 of the imported file, stored at import. A duplicate is skipped with "Already in
  your library" and a button that opens it. Same hash ⇒ same `itemId` across delete/re-import, so
  history reattaches.
- **Deleting.** For a local item the existing "Remove from Library" action (Library context menu
  and detail page) is relabelled **"Delete from Device"**, destructive-styled, and always confirms:
  "Delete *Title* from this iPhone? The imported file (N MB) is removed from MangaCarta and can't
  be recovered. Reading history is kept." Removing a local item from a *collection* only
  (ADR-0006) stays non-destructive; only leaving Library deletes.

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
likewise skips it: decided, v1 does no MAL/AniList/MangaDex matching for local Works, so the
queue excludes `local` Listings (same capability-based check) and `MALProgressCoordinator` never
syncs them.

## 7. Testing

**Unit (Swift Testing, `MangaCartaTests`; new files need the four pbxproj entries via `xcp`):**

- `ZipReaderTests` — fixtures built in-test from byte literals: stored entry, deflate entry,
  multiple entries, CRC mismatch rejected, encrypted flag rejected, ZIP64 rejected, truncated
  EOCD rejected, archive comment before EOCD handled.
- `PageOrderingTests` — natural sort (`2` < `10`), `__MACOSX`, `.DS_Store`, `._` files and
  non-images dropped, case-insensitive extensions; **chapter splitting**: two top-level folders →
  two chapters in natural order, a single wrapper folder → one chapter, root images beside folders
  → a leading chapter, deeper nesting flattened.
- `ComicInfoParserTests` — full, partial, malformed XML (falls back to filename), `Manga`
  direction mapping.
- `LocalLibraryStoreTests` — import leaves no archive behind, duplicate by hash, a failed
  extraction leaves no directory, delete removes directory, Library entry and Listing, re-import
  restores `itemId`.
- `LocalSourceTests` — `chapters`/`pageURLs` return file URLs in order; unsupported feeds throw.
- `LibraryRefreshCoordinatorTests` — a Work with only a local Listing is never fetched.
- `SourceRegistryTests` — `visibleSources` never includes `local`.
- `MetadataUpgradeQueueTests` — a local-only Work is never enqueued.

**UI (hermetic, XCUITest):** the system `fileImporter` picker is not reliably drivable, so the
launch fixture supplies a CBZ to the same `LocalImportViewModel` path the picker uses. The fixture
is supplied by the UI test and is not bundled in the release app. A launch argument
`-uitest-import-fixture <name>` (the pattern `UpdatesUITests` uses for `-uitest-updates-state`)
triggers that path. `LocalImportUITests` then asserts: the empty
state shows the "does not provide or host content" copy before import; the item appears in
Library; opening it shows page 1; paging to the end marks it read; "Delete from Device" shows
the warning and, confirmed, returns Library to the empty state; screenshots attached at each step. Fixture art is original or public domain (§9). Runs on iPhone 17 Pro locally; the test must
not depend on grid position (CI's UI device is iPhone 16 Pro).

## 8. Slices

Each slice is independently mergeable and leaves the app working.

1. **ZIP reader + page selection (pure).** `ZipReader`, `PageSelector` (junk filtering, natural
   sort, top-level-folder chapter splitting) in `Models/`. No UI.
   *Accept:* `ZipReaderTests` and `PageOrderingTests` green, including the chapter-splitting cases
   and fixtures from two tools.
2. **Local library store + `LocalSource`, CBZ/ZIP.** Storage layout (§2) with staging and no kept
   archive, SHA-256 dedupe, multi-chapter items, `LocalSource` registered, `ImageCache` file-URL
   bypass, `participatesInUpdates` and `isBrowsable` capabilities.
   *Accept:* `LocalLibraryStoreTests`, `LocalSourceTests` (a two-folder archive yields two
   chapters), `SourceRegistryTests`, `MetadataUpgradeQueueTests` and the refresh-skip test in
   `LibraryRefreshCoordinatorTests` green.
3. **Import UI + empty states + delete.** `fileImporter`, progress banner, per-file errors, the
   single "Delete from Device" action with its warning, Settings row, first-run copy;
   `-uitest-import-fixture` hook.
   *Accept:* `LocalImportUITests` green on the hermetic CI suite, including the delete step.
4. **PDF.** PDFKit rasterisation at ≈2,600 px into the same layout (one chapter per PDF).
   *Accept:* `PDFImportTests` (a 3-page generated PDF yields 3 ordered pages, a cover, and no
   retained PDF).
5. **ComicInfo.xml + open-in.** Parser, title/number/direction; document types for Share-to.
   *Accept:* `ComicInfoParserTests` green; `LocalLibraryStoreTests` asserts Series wins over
   filename.
6. **Series grouping by ComicInfo `Series`.** *Accept:* a `LocalLibraryStoreTests` case where
   three CBZs sharing a `Series` — two in one batch, one imported later — form one Work with
   chapters ordered by `Volume`, and a CBZ without ComicInfo stays its own Work.

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

## 10. Future work

- A Komga/OPDS client — the next "legitimate purpose", fitting the same Source-shaped seam.
- Matching local Works to MangaDex/AniList/MAL for metadata and progress sync.
- A vector PDF reader path (v1 rasterises).
- Folder watching, CBR/RAR, EPUB.

## Decisions (2026-09-22)

The owner answered the draft's open questions on #216:

1. **Local files are a compiled `LocalSource`, id `local`, always registered** — recorded in
   [ADR-0025](../../adr/0025-local-files-as-a-source.md), compatible with ADR-0003 Amendment 6
   ([#215](https://github.com/eliasmagdaleno/MangaCarta/pull/215)). (§1)
2. **The original archive is deleted after unpacking;** only pages are kept. (§2)
3. **`local` appears in Library only**, not in the Home source picker, for now. (§1)
4. **Several top-level chapter folders → one chapter per folder.** (§3, slices 1–2)
5. **Remove from Library and Delete from device are one action**, with a clear warning. (§2, §5)
6. **No MAL/AniList/MangaDex matching** for local Works in v1. (§6, §10)
7. **Series grouping uses ComicInfo `Series` only.** (§4, slice 6)
8. **≈2,600 px PDF rasterisation is fine for v1;** a vector reader is future work. (§3, §10)

Still open (owner item):

9. Who produces the original or public-domain art for the App Store screenshots and the App
   Review sample file? (§9)
