# Local library formats: CBR/RAR, fixed-layout EPUB, and folder watching

**Date:** 2026-11-09  
**Status:** Accepted — owner sign-off 2026-11-10.  
**Slug:** `local-formats-cbr-epub-folders`

## Goal

Extend the existing `local` `MangaSource` so a reader can import image-based CBR/RAR and
fixed-layout comic EPUB files, and can opt into a remembered Files folder that is reconciled
when MangaCarta launches or returns to the foreground. Existing CBZ/ZIP/PDF imports, Work and
Listing identity, reading history, and the reader remain the same.

This is a design for three independently mergeable slices: CBR/RAR, fixed-layout EPUB, and
folder reconciliation. The project has no package manager today; the CBR slice deliberately
adds the first Swift Package dependency to the Xcode project.

## Non-goals

- Reflowable, text-first EPUBs, EPUB text selection, CSS layout, fonts, or an HTML reader.
- RAR creation, archive editing, multi-volume set authoring, or password entry/storage.
- CB7/7z, TAR, encrypted ZIP, or arbitrary archive extraction.
- Continuous background watching, filesystem event subscriptions, or a sync service.
- Keeping external archives as the canonical library. Imports still copy content into the app's
  Application Support library as specified by the existing local-import design.
- Automatic matching of local Works to MangaDex, AniList, or MAL.

## Current code this builds on

The earlier design established `LocalSource` as a compiled `MangaSource`, with stable local
Listing ids and unpacked pages under `Application Support/LocalLibrary/<itemId>`
([2026-09-22 local import design](2026-09-22-local-import-design.md), §1–2). That architecture
is accepted by ADR-0025: imported files are Listings of source `local`, which is always
registered, not browsable, and excluded from update polling
([ADR-0025](../../adr/0025-local-files-as-a-source.md), lines 17–27).

The implementation was checked before writing this spec:

- `MangaCarta/Services/LocalLibraryStore.swift:52–75` defines the actor, Application Support
  root, and coordinated external-file copy; `:77–167` stages an import, hashes it, extracts
  pages, writes `item.json`, and removes staging on failure.
- `MangaCarta/Services/LocalLibraryStore.swift:170–180` reads only a root-level
  `ComicInfo.xml`; `:217–265` reloads records, resolves series records, and enumerates
  chapters.
- `MangaCarta/Models/LocalItemRecord.swift:4–25` stores a file hash, byte size, import date,
  chapter records, and optional `ComicInfo`; `:30–43` derives the stable normalized-series id.
- `MangaCarta/Services/ZipArchiveReader.swift:16–33` has explicit archive, entry, total-output,
  and compression-ratio limits; `:55–117` reads stored/deflate entries with CRC validation;
  `:197–243` rejects ZIP64, encrypted entries, unsupported methods, traversal, and limits;
  `:246–280` filters image entries and groups pages by top-level folder.
- `MangaCarta/Models/ComicInfo.swift:21–47` parses XML metadata and already exposes
  `readingMode`; this spec keeps the existing `Series`, `Title`, `Number`, `Volume`, metadata,
  `Manga`, and `FrontCover` behavior.
- `MangaCarta/Models/LocalImportViewModel.swift:5–7` declares `com.mangacarta.cbz` as an
  imported type conforming to `.zip`; `:78–125` starts/stops security-scoped access and routes
  per-file errors; `:128–139` handles open-in URLs and only deletes copies inside the app
  container.
- `MangaCarta/Services/LocalLibraryDeletion.swift:15–29` deletes local storage, Library state,
  and the local Work Listing while retaining history behavior.
- `MangaCarta/Info.plist:9–29` declares the CBZ imported UTI, ZIP/PDF document types, and
  `LSSupportsOpeningDocumentsInPlace=true`. The existing `.cbz` entry is `Owner`; public ZIP and
  PDF remain `Alternate`.
- `MangaCarta/ContentView.swift:110` receives open-in URLs. `MangaCarta/Views/BookmarksView.swift:187–222`,
  `MangaCarta/Views/HomeView.swift:232–241`, and `MangaCarta/Views/SettingsView.swift:257`
  expose the existing file importer and local deletion flows.
- `MangaCarta.xcodeproj/project.pbxproj:13–32, 146–188, 713–727` confirms that test files are
  explicit project entries. New files in `MangaCartaTests/` therefore require `xcp add-file`
  (four project entries); files in synchronized `Models/` or `Services/` do not.

## Design

### 1. One archive-ingestion contract

Factor the format-specific readers behind a small internal contract used by
`LocalLibraryStore`:

```swift
struct LocalArchiveEntry: Sendable {
    let path: String
    let isDirectory: Bool
    let compressedSize: UInt64
    let uncompressedSize: UInt64
}

protocol LocalArchiveReading: Sendable {
    func entries() throws -> [LocalArchiveEntry]
    func data(for entry: LocalArchiveEntry) throws -> Data
}
```

The protocol is an implementation seam, not a new public extension API. ZIP keeps its current
reader and limits. RAR gets a file-backed adapter. EPUB deliberately uses the current ZIP
reader, followed by an EPUB-specific spine parser, rather than another archive dependency.

All formats use the current staging directory and per-page writes. The reader must never ask a
RAR adapter for the whole archive's decompressed contents. It asks for one metadata entry or one
page at a time, validates the byte budget, writes the page, and releases the `Data` before the
next page. A page that is too large or cannot decode is an import error, not a partially usable
chapter.

### 2. CBR/RAR: dependency choice

Two realistic options were evaluated from their own repositories:

| Option | RAR4/RAR5 | Swift Package | Maintenance/licence finding | Decision |
| --- | --- | --- | --- | --- |
| `mtgto/Unrar.swift` | Yes. Its pinned 0.5.4 source contains the RAR5 reader (`unpack50.cpp` and RAR 5.0 handling). | Yes; its README documents SPM and its manifest is `swift-tools-version:5.3`. | Latest 0.5.4 commit updates UnRAR to v7.23 on 2026-06-30. Swift wrapper is MIT; bundled UnRAR source is the official freeware UnRAR licence. | **Choose** |
| `UnrarKit` | The repository describes broad RAR support, but its own Unrar.swift README says it has no SPM support. | No SPM package in the cited repository. | Would require vendoring/converting a package and creates an avoidable maintenance fork. | Reject |
| `merenkoff/Unarchiver` | Its app README claims RAR4/RAR5, but it is an iOS application, not a focused library. | It tells users to add an Unrar.swift branch plus several unrelated packages. | The app is under an OwnNet Source License whose README says commercial embedding requires permission. | Reject |

Primary sources recorded in the design:

- [Unrar.swift README](https://github.com/mtgto/Unrar.swift) — features, SPM installation,
  comparison to UnrarKit, and licence split.
- [Unrar.swift 0.5.4 Package.swift](https://github.com/mtgto/Unrar.swift/blob/0.5.4/Package.swift)
  — exact package manifest, C++11 target, and source list including the RAR5 implementation.
- [Unrar.swift 0.5.4 Swift licence](https://github.com/mtgto/Unrar.swift/blob/0.5.4/LICENSE.txt)
  — MIT terms and attribution requirement.
- [UnRAR licence shipped by 0.5.4](https://github.com/mtgto/Unrar.swift/blob/0.5.4/Sources/Cunrar/license.txt)
  and [UnRAR legal readme](https://github.com/mtgto/Unrar.swift/blob/0.5.4/Sources/Cunrar/readme.txt)
  — decompression is permitted without charge, redistribution is permitted, and use to create
  a RAR/WinRAR compressor is forbidden.
- [Unarchiver README](https://github.com/merenkoff/Unarchiver) — rejected app-level alternative.

Pin the package to exact tag **0.5.4** and record the resolved revision
`7216007a38ac122dbdeae26cfdaf7f10775c868f` in `Package.resolved`. Add the package to the
`MangaCarta` application target only; do not expose `Unrar` from the app's public model layer.
The adapter should be the only file importing the package.

This is compatible with App Store distribution: the UnRAR terms permit distributing the
decompressor inside another software package and handling RAR archives, while forbidding only a
RAR compressor. MangaCarta does not create or edit archives. Settings → About → Acknowledgements
must include the MIT notice for `Unrar.swift` and the complete UnRAR legal paragraph/licence
text, with links to the two upstream sources; the app must not imply that RAR creation is
supported. Legal review remains an owner question below.

The package declares Swift tools 5.3 and uses a C++11 target; the wrapper contains no Swift 6
language requirement. It is therefore source-compatible with the project's Xcode 16.4 / Swift
6.0 CI toolchain. The CBR slice's CI acceptance must run an Xcode 16.4 build and a real RAR4 and
RAR5 fixture test, proving that Swift 6.0 resolves and builds the pinned package rather than
relying on the local Xcode 26 toolchain.

The current `.github/workflows/ci.yml` has no package-cache or `SourcePackages` handling (verified
by reading the workflow). The CBR PR must add it: cache a dedicated path such as
`$RUNNER_TEMP/SourcePackages` with `actions/cache`, keyed by the `Package.resolved` hash, Xcode
version, and platform; pass `-clonedSourcePackagesDirPath "$RUNNER_TEMP/SourcePackages"` to every
relevant `xcodebuild`; and let a cache miss resolve the pinned URL/revision. Add
`-skipPackagePluginValidation` only if package resolution actually requires it, not as a blanket
workaround. The normal iPhone 17 Pro destination and parallel testing rule remain in force.

### 3. RAR adapter and safety

`RARArchiveReader` opens a staged file path, lists entries, and extracts a single entry to
memory. It must reject:

- encrypted headers or encrypted file entries, with `LocalImportError.passwordProtectedArchive`
  rendered as **“Password-protected RAR archives aren’t supported.”** The library can accept a
  password, but v1 has no secure password UX or password persistence; do not prompt and do not
  guess.
- multi-volume sets (`.part1.rar`, `.r00`, etc.) unless all volumes are selected together and
  the adapter can prove a complete set. Recommended v1 behavior is a clear unsupported
  multi-volume error, never treating one volume as a complete book.
- path traversal, symbolic-link-like entries, unsupported entry types, corrupt headers, and
  decompressed output beyond the shared limits.

Use the same defaults as ZIP for the first implementation: 512 MiB source archive, 512 MiB
total uncompressed output, 128 MiB per entry, 10,000 entries, and 10,000 maximum compression
ratio. These are safety ceilings, not a promise that every device can import a 512 MiB comic.
Before each extraction, check `FileManager` free space against the remaining output estimate plus
a staging margin; map failure to the existing “Not enough storage available” message.

RAR entries are streamed or extracted one page at a time into staging. Do not call an API that
materializes all pages or the whole archive. The cover is selected after the first decodable
page, or from ComicInfo's `FrontCover` page when present. The existing `LocalItemRecord` gains a
`format` field (`rar`, `zip`, `epub`, `pdf`) with a decoding default for old JSON, so Settings
and errors can identify the imported format without changing Listing identity.

### 4. Fixed-layout EPUB

An EPUB is a ZIP container. Reuse `ZipArchiveReader` for entry listing, path validation, CRC,
size limits, and per-entry reads. Do not add an EPUB or HTML dependency.

1. Require `META-INF/container.xml`, parse its `rootfile full-path`, and locate the OPF.
2. Parse OPF metadata and manifest with `XMLParser`. Resolve relative paths against the OPF
   directory after normalizing without allowing `..` to escape the archive.
3. Require a spine and walk its itemrefs in spine order. For each `idref`, resolve the manifest
   item and accept one of these page shapes:
   - an XHTML item (`application/xhtml+xml`) or SVG item (`image/svg+xml`) whose XML document
     body/root contains exactly one raster image reference: XHTML `body` → `img[src]`, or SVG
     `svg` → `image` with `xlink:href`/`href`; resolve that reference relative to the document and
     require a supported raster manifest entry (`image/jpeg`, `image/png`, `image/webp`,
     `image/gif`, `image/avif`, or `image/heic`);
   - a bare raster manifest item through the OPF fallback chain (`fallback`), when the spine item
     itself is a document item whose fallback eventually names that raster item, or when the
     `idref` directly names a raster item.

   Parse XHTML/SVG with Foundation `XMLParser`, not WebKit or another dependency. The parser
   counts image references and non-whitespace text. A document with zero images, more than one
   image, or text content beyond whitespace is reflowable/unsupported; do not guess from ZIP
   entry order or scrape arbitrary image tags outside the document body. Reject unsupported
   raster media types and broken relative references with a clear import error.
4. Accept a comic EPUB when OPF/package metadata declares `rendition:layout=pre-paginated`, or
   when **every spine item resolves to exactly one raster image page** using the rules above
   (including XHTML/SVG wrappers and fallback-to-image items). The latter is the explicit
   fixed-layout fallback for real manga EPUBs that omit the metadata. A reflowable text EPUB is
   **out of scope** and must fail with **“This EPUB is a reflowable text book; MangaCarta supports
   image-based comic EPUBs.”**
5. Choose title/series/number/volume from OPF metadata, falling back to filename. If a root
   `ComicInfo.xml` exists, merge it using existing ComicInfo precedence and use it for series,
   reading mode, and cover metadata. CBR and EPUB may therefore carry ComicInfo.xml too.
6. Use spine order as page order, one chapter per EPUB. Select the OPF cover image or the first
   decodable spine image. Store the pages in the same `pages/1`, `cover.jpg`, and `item.json`
   shape as ZIP/PDF.

Options considered: (a) render XHTML/CSS with WebKit, rejected because it turns the importer into
a browser and makes text EPUBs a second product; (b) scan all images in ZIP order, rejected
because EPUB spine order is authoritative and would scramble wrapped pages; (c) accept only bare
image manifest items, rejected because valid EPUB 2/3 comic spines normally reference XHTML/SVG
documents; (d) parse each spine document for exactly one raster image and follow OPF fallback
chains, chosen because it handles real fixed-layout manga without a dependency while rejecting
reflowable content. The owner question is now whether to accept the metadata-free fallback when
every spine document resolves to exactly one raster image; the recommended answer is yes.

### 5. Folder watching is foreground reconciliation

The user picks a folder through `UIDocumentPickerViewController` with the public `folder` type.
Apple's [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
documentation says iOS 13+ returns a security-scoped directory URL, recursively covering new
children, and permits saving a bookmark for the next launch. Persist bookmark data (not a raw
path) in a dedicated `LocalFolderBookmarkStore`; use `bookmarkData(options: .withSecurityScope)`
when available, resolve it on launch, call `startAccessingSecurityScopedResource()`, and always
balance it with `stopAccessingSecurityScopedResource()` after reconciliation. A stale bookmark,
revoked permission, provider-offline folder, or failed enumeration becomes a recoverable Settings
error with **Choose folder again**; it never deletes existing imported pages silently.

“Watching” on iOS honestly means **re-scan on launch and each foreground activation**, not a
continuous watcher. There is no supported general-purpose background filesystem event stream for
an arbitrary Files-provider directory granted by the document picker. The app may have a
background refresh task, but iOS does not promise it will run, and the security-scoped access is
user-granted and finite; therefore this feature must not claim instant or background sync. A
foreground scan can be user-triggered with **Scan now**.

Reconciliation is an actor-owned operation:

- enumerate recursively under the granted directory, following no symlinks, and consider only
  `.cbz`, `.zip`, `.cbr`, `.rar`, and `.epub` (case-insensitive); ignore hidden files and the
  app's own staging artifacts;
- compare each relative path plus file size and modification date to a persisted folder-entry
  record; if unchanged, do not re-import;
- for a new or changed archive, import through the same `LocalLibraryStore` path. A changed file
  gets a new SHA-256 identity; the old imported item remains until the removal policy below is
  approved;
- record bookmark id, relative path, byte size, modification date, SHA-256/item id, and last
  successful scan time in `local-folder.json`; never persist an external absolute path as the
  authority;
- process sequentially with cancellation and progress, so one corrupt archive does not prevent
  the rest of the scan. The scan must not run concurrently with an explicit import or another
  scan.

The folder is an import source, not a live reader dependency: pages remain available if the
provider goes offline or the user revokes access. This also means a source archive can be deleted
without immediately breaking a local reader item; removal semantics are explicitly owner-owned
below.

### 6. Document types and UTI behavior

Extend the existing `com.mangacarta.cbz` pattern instead of inventing a per-format private-only
type:

- keep `com.mangacarta.cbz` imported and conforming to `public.zip-archive`;
- declare `com.mangacarta.cbr` imported, conforming to `public.data`, with `cbr` and `rar` tags
  (or use the public `public.archive`/RAR type if the SDK provides it, verified at implementation
  time); declare `com.mangacarta.epub` imported, conforming to `org.idpf.epub-container` when
  available and otherwise `public.zip-archive`;
- list public/common content types (`public.zip-archive`, `com.adobe.pdf`, and the public EPUB
  identifier) in `CFBundleDocumentTypes` as `Alternate`, while MangaCarta-specific comic types
  are `Owner` only where default-open behavior is intentional;
- include the same UTTypes in SwiftUI's importer and open-in routing, with extension checks as a
  defensive fallback because File Provider metadata is not uniform.

The handoff lesson is important: another app claiming the same UTI can win Files' default opener.
UTI ownership is not a correctness mechanism. The app must continue to accept Share/Open-in URLs,
and Settings must provide **Import files** and **Choose watched folder** regardless of which app
Files displays as default. Do not claim ownership of public ZIP/EPUB/RAR types merely to win the
default; it would make MangaCarta look like a general archive utility and could displace the
user's chosen app.

### 7. Covers, grouping, errors, and deletion

ComicInfo parsing, series normalization, and `series-<hash>` identity remain shared across all
formats. CBR/EPUB can include root-level ComicInfo.xml; EPUB also uses OPF metadata. Cover
precedence is explicit: ComicInfo `FrontCover`/OPF cover, then first decodable page in reader
order, then no cover placeholder. A missing or corrupt cover does not reject an otherwise valid
archive.

Existing series grouping by normalized ComicInfo `Series` applies to all imported formats. A
file without Series remains its own Work. A folder scan must use the same hash/deduplication path
as manual import, so discovering an already imported archive does not create a second Listing.

Errors are per archive and retain the view-model convention of strings, including:

- unsupported/corrupt archive, encrypted ZIP, password-protected RAR, incomplete multi-volume
  RAR, no decodable images, malformed/missing EPUB container or OPF, reflowable EPUB, and
  insufficient storage;
- stale/revoked folder permission, provider unavailable, and scan cancelled.

The existing destructive local action remains **Delete from Device**. It removes the copied pages,
record, Library entry, and local Listing via `LocalLibraryDeletion`; reading history remains as
today and re-import can restore it when the identity is the same. Deleting an archive from a
watched external folder must not implicitly delete the copied item until the owner selects a
removal policy. The recommended policy is conservative: mark the folder entry missing and show
“Removed from watched folder” with an explicit **Delete imported copy** action; this protects
against a provider outage or accidental move.

### 8. Accessibility and UI

Use existing Ink & Seal tokens and native controls. The watched-folder Settings row states the
folder name, permission state, last scan time, and number of new/changed/missing archives in
plain text. “Scan now”, “Choose folder”, “Stop watching”, and “Delete imported copy” are native
buttons with at least 44-point targets and VoiceOver labels that include the affected title.

Import and scan banners expose progress as a combined accessibility element with a localized
value (“3 of 8 archives, Berserk volume 2”) and a visible Cancel button. Errors are announced in
the existing error region and remain visible until dismissed or successfully retried. Do not use
format color alone: the row says “RAR”, “EPUB”, or “ZIP” in text. Dynamic Type must wrap long
provider names and paths; no folder access or deletion action may be gesture-only.

## Data and persistence changes

- `LocalItemRecord`: add `format` with a Codable default of `zip` for old records. Keep the hash,
  pages, cover, ComicInfo, and series identity stable.
- New `LocalFolderBookmarkStore` persists one or more bookmark records in a dedicated
  `local-folder.json` (or the project's established Application Support JSON store): bookmark
  data, a display name, enabled flag, last scan date, and relative-path reconciliation records.
  Do not put external URLs in `item.json` or make them required to read imported pages.
- New `LocalFolderScanResult` is transient and reports imported, skipped, changed, missing, and
  failed entries; it is not a second catalog.
- Add the package URL and exact revision to `Package.resolved`; Xcode's package integration will
  add project package references. This is the first dependency, so the PR must document the
  generated project changes and acknowledgement asset.
- No migration is required for existing local items beyond Codable decoding defaults. Folder
  records are new and can be discarded without affecting imported pages.

## Acceptance criteria and tests

Each criterion names the test that proves it. New `MangaCartaTests/` files require
`xcp add-file ... --targets MangaCartaTests`; production files in synchronized `Models/` and
`Services/` do not require project edits. No test may depend on the network or an unseeded
external Files provider.

1. **RAR4 imports** a fixture with ordered image entries, writes one page per file, cover, and
   `item.json`, and returns a Local Listing. `RARArchiveReaderTests.rar4EntriesAndPages` and
   `LocalLibraryStoreTests.importsRAR4`.
2. **RAR5 imports** a fixture with the same guarantees and proves the pinned package handles RAR5.
   `RARArchiveReaderTests.rar5EntriesAndPages`.
3. **RAR safety** rejects encrypted/password archives, incomplete multi-volume archives, traversal,
   corrupt data, oversized entries, and compression bombs with stable user-facing categories.
   `RARArchiveReaderTests.rejectsUnsafeArchives` and `LocalImportErrorTests.rarMessages`.
4. **RAR memory behavior** extracts a large fixture one page at a time without an all-pages
   allocation; the adapter's test double records at most one page buffer in flight.
   `RARArchiveReaderTests.extractsPerEntry`.
5. **Dependency/CI compatibility** builds the app with the exact 0.5.4 revision under Xcode
   16.4/Swift 6.0 and runs the RAR4/RAR5 tests. CI workflow package-cache smoke step.
6. **EPUB spine order and wrappers** imports an XHTML-wrapped fixed-layout manga EPUB whose ZIP
   order differs from spine order, resolves each `img[src]` relative to its XHTML document, and
   stores pages in spine order. `EPUBImportTests.importsXHTMLWrappedPagesInOPFSpineOrder`.
7. **EPUB metadata and cover** uses OPF title/cover, merges root ComicInfo, groups by Series,
   and falls back to the first decodable page when cover metadata is absent.
   `EPUBImportTests.metadataAndCoverPrecedence`.
8. **EPUB scope** accepts XHTML/SVG documents containing exactly one raster image, accepts a bare
   raster item through a valid OPF fallback chain, and rejects documents with text beyond
   whitespace, zero images, multiple images, malformed containers/OPFs, or reflowable text.
   `EPUBImportTests.acceptsXHTMLAndSVGSingleImagePages`,
   `EPUBImportTests.resolvesFallbackToBareImage`, and `EPUBImportTests.rejectsReflowableText`.
9. **Folder permission** stores a picked directory bookmark, resolves it on a later launch,
   balances security-scoped access, and presents a recoverable stale/revoked state.
   `LocalFolderBookmarkStoreTests.roundTripsBookmark` and
   `LocalFolderScanTests.revokedBookmarkIsRecoverable`.
10. **Folder reconciliation** discovers a new archive, skips unchanged files, imports a changed
    fingerprint once, and reports a corrupt file without aborting other entries.
    `LocalFolderScanTests.reconcilesNewChangedAndFailedEntries`.
11. **Foreground semantics** performs scans at launch and foreground activation, exposes Scan now,
    and schedules no filesystem watcher or guaranteed background event listener. Hermetic
    `FolderWatchingUITests.foregroundScanStatus` plus a source inspection test for scheduler wiring.
12. **Removal safety** reports an external archive missing without deleting its copied pages, and
    the explicit delete action routes through `LocalLibraryDeletion`, retaining history.
    `LocalFolderScanTests.missingIsNonDestructive` and `LocalLibraryDeletionTests` extension.
13. **Document types** register `.cbr`, `.rar`, and `.epub` plus public/common UTIs, while retaining
    open-in fallback when another app wins the default. `DocumentTypeTests.infoPlistDeclaresFormats`
    and `LocalImportViewModelTests.routesOpenedFormats`.
14. **Accessibility** exposes format, permission state, scan progress, errors, and destructive
    actions as VoiceOver-readable labels. Hermetic `FolderWatchingUITests.accessibilityLabels`.

## Slices

1. **CBR/RAR reader and package integration.** Add exact `Unrar.swift` 0.5.4, package adapter,
   streaming/per-entry limits, errors, acknowledgements, document types, and RAR unit fixtures.
   This PR must include the Xcode 16.4/Swift 6.0 CI package build.
2. **Fixed-layout EPUB.** Reuse ZIP, implement container/OPF/spine/image extraction, ComicInfo and
   cover precedence, error copy, document type, and EPUB tests. No new dependency.
3. **Folder reconciliation.** Add folder picker/bookmark store, launch/foreground scans, missing
   reporting, conservative deletion UI, accessibility, and hermetic tests. It consumes the
   format adapters from slices 1–2 but can merge independently after those slices.

## Owner decisions (2026-11-10)

The owner accepted every recommended answer below at sign-off.
1. **EPUB fallback:** Approve the recommended rule that an EPUB with no explicit fixed-layout
   metadata is accepted only when every spine item resolves to exactly one supported raster image
   page, whether directly, through XHTML/SVG, or through an OPF fallback chain? Recommended: yes.
2. **Watched-folder removal:** When an archive disappears, should MangaCarta retain the copied
   local item and mark the source missing, or immediately delete the imported copy? Recommended:
   retain it and require an explicit **Delete imported copy** action.
3. **Folder scope:** Should v1 allow one watched folder or multiple independent folder bookmarks?
   Recommended: one, to keep reconciliation and Settings understandable; the persistence shape
   can remain an array for a future migration.
4. **UnRAR legal acknowledgement:** May the app ship the UnRAR decompressor under its
   decompression-only licence, with the full licence text and MIT notice in Settings → About?
   Recommended: yes, subject to the owner's legal review; no compressor functionality will be
   added.
5. **RAR multi-volume:** Should v1 reject all multi-volume RAR sets, or require the user to select
   a complete set in one import? Recommended: reject in v1 with a clear error; add complete-set
   support only as a later slice with dedicated fixtures.
