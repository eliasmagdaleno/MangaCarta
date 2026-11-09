# Vector PDF reader path

**Date:** 2026-11-09  
**Status:** Proposed design  
**Slug:** `vector-pdf-reader`  
**Build baseline:** current branch at design time; no code or tests changed for this spec

## Goal

Keep an imported PDF as a PDF and render its pages on demand so text and line art stay sharp at
the reader's full 4× zoom range, while making import proportional to the source file rather than
to the number and dimensions of rasterized pages. A PDF remains one ordinary `local` Listing and
one chapter, and it continues through the existing reader's progress, read-state, chapter
navigation, R→L ordering, accessibility, and Files open-in-place flows.

The implementation should add one page-rendering seam, not a second reader. Image-backed chapters
continue to use the existing asynchronous image path; PDF-backed chapters supply a vector page
reference to the same `ReaderView` and `ReaderViewModel` pipeline.

## Non-goals

- Editing, annotating, reflowing, searching, selecting, copying, or printing PDF content.
- Changing the local Source identity, Work/Listing model, chapter grouping, or reading-mode rules.
- A PDF document browser, multi-document tab UI, or a new PDF-specific reader screen.
- Keeping an import-time raster copy “just in case” for new PDFs.
- Converting already-imported raster pages when the original PDF is unavailable.
- Password entry, password removal, or support for encrypted PDFs in v1.
- A custom continuous PDF canvas that bypasses the existing webtoon layout.

## Current code this builds on

The following facts were checked against the files named here, not inferred from older design
documents.

### Import and persistence

- `LocalLibraryStore.importArchive` copies the security-scoped/open-in-place input into a staging
  directory, hashes it, assigns the first 32 hex characters of the SHA-256 as `itemId`, and
  detects duplicates before format handling (`MangaCarta/Services/LocalLibraryStore.swift:77-107`).
- PDF detection is by `%PDF-` bytes or a `.pdf` extension (`LocalLibraryStore.swift:100-103`).
- `importPDF` currently creates `pages/1`, invokes `PDFPageRasterizer`, writes a cover from the
  first JPEG, stores one `LocalChapter` whose `pageFiles` are JPEG names, deletes the staged
  archive, and moves the item directory into place (`LocalLibraryStore.swift:183-215`).
- `PDFPageRasterizer` opens a `PDFDocument`, rejects locked/zero-page documents, and calls
  `PDFPage.thumbnail(of:for:)` for every page with a 2,600-point long edge before writing
  `0001.jpg`, etc. (`MangaCarta/Models/PDFPageRasterizer.swift:11-49`).
- `LocalItemRecord` persists item identity, source filename, hash, byte size, chapters, and
  ComicInfo; `LocalChapter` currently persists only number, title, page count, and image filenames
  (`MangaCarta/Models/LocalItemRecord.swift:4-25`).
- `LocalLibraryStore.pageURLs` reconstructs file URLs from `pageFiles` (`LocalLibraryStore.swift:286-290`),
  and `LocalSource.pageURLs` parses the `itemId/chapter` chapter id and delegates to that method
  (`MangaCarta/Models/LocalSource.swift:55-68`).
- `LocalLibraryStore` already computes item size by walking the item directory and removes the
  whole item directory on delete (`LocalLibraryStore.swift:297-318`), so retaining a PDF requires
  no new cleanup subsystem.

The accepted local-import design explicitly chose rasterization as v1 and says the original
archive is deleted after unpacking (`docs/superpowers/specs/2026-09-22-local-import-design.md:141-146`,
`:330-336`). This spec supersedes only that PDF implementation choice; it does not reopen the
accepted `LocalSource` decision recorded in ADR-0025.

### Reader and page pipeline

- `MangaSource.pageURLs` is the bridge-friendly page seam and returns `[URL]`
  (`MangaCarta/Models/MangaSource.swift:59`). `ReaderViewModel.fetchPages` calls it, rejects an
  empty result, publishes `[URL]`, and prefetches those URLs after a successful load
  (`MangaCarta/Models/ReaderViewModel.swift:41-45`, `:163-170`, `:187-193`).
- `ReaderView` uses the same published pages for both modes: a `TabView` creates one
  `ZoomablePage` per URL in paged mode (`MangaCarta/Views/ReaderView.swift:472-503`), and a
  `LazyVStack` creates one `WebtoonPage` per URL in vertical mode (`ReaderView.swift:530-565`).
- Right-to-left mode reverses `pageOrder`; it does not mirror a view
  (`ReaderView.swift:522-528`; the no-mirror constraint is also explicit in
  `MangaCarta/Views/Components/ZoomableContainer.swift:27-29`).
- `ZoomableContainer` is a `UIScrollView`-backed `UIViewRepresentable`, with 1× minimum, 4×
  maximum, native pinch/pan, and double-tap zoom (`ZoomableContainer.swift:35-44`, `:58-71`).
  It hosts SwiftUI content and resets inactive pages to 1× (`ZoomableContainer.swift:78-99`).
- `ZoomablePage` currently wraps `CachedAsyncImage` and labels the page as “Page n of total”;
  `WebtoonPage` does the same without the zoom container (`MangaCarta/Views/ReaderView.swift:717-763`,
  `:766-794`). The page indicator keeps the accessibility identifier
  `readerPageIndicator` (`ReaderView.swift:675-690`).
- `LocalImportViewModel.importOpenedURL` sends file URLs through the same importer used by the
  Files picker (`MangaCarta/Models/LocalImportViewModel.swift:128-132`). The app enables
  `LSSupportsOpeningDocumentsInPlace` and claims PDF at Alternate rank
  (`MangaCarta/Info.plist:22-29`). The importer coordinates reads and only deletes a handed-over
  file when it is inside the app container (`LocalImportViewModel.swift:116-139`).

## Design

### 1. Keep the PDF as one imported document

For a new PDF, the item directory becomes:

```text
<itemId>/
  document.pdf
  cover.jpg
  item.json
```

`document.pdf` is the coordinated copy made during import. No page JPEGs are generated. The
record keeps the exact source byte size and hash already used for duplicate detection; Settings'
existing item-size walk therefore reports the PDF plus its small cover and metadata. The source
file outside the container is never deleted, including a Files “Open in place” original.

The cover remains a small raster thumbnail. It is library chrome, not reader content, and keeping
one predictable JPEG avoids opening a PDF just to draw a Library card. Generate it from page one
at a bounded 512-pixel maximum edge using the existing cover-writing policy; this is the only
import-time rendering.

### 2. Page abstraction: one reader, two renderers

Introduce a Codable/value page reference owned by the host, for example:

```swift
enum ReaderPage: Equatable, Sendable {
    case image(URL)
    case pdf(documentURL: URL, pageIndex: Int)
}
```

The exact declaration may use a URL string or a small `Codable` payload if Swift's synthesized
conformance requires it; the important contract is that it carries no `PDFPage` object across an
actor or persistence boundary. It is a reader-session value, not a new Source identity.

Add a narrow optional capability rather than changing the bridge-friendly `MangaSource` contract:

```swift
protocol VectorPageProviding {
    func pageReferences(chapterId: String) async throws -> [ReaderPage]
}
```

`LocalSource` conforms. `ReaderViewModel.fetchPages` asks a `VectorPageProviding` source for
references and otherwise adapts the existing `pageURLs` result to `.image`; its published
`pages`, landing calculations, chapter advance, and progress use the reference array's count just
as today. This one capability check is the only source-specific seam. Remote and archive sources
remain unchanged, and extensions do not need to understand PDFKit.

`ReaderView` switches only at the leaf:

- `.image(url)` uses the existing `CachedAsyncImage`, retry control, image-load reporting, and
  prefetch path.
- `.pdf(documentURL, pageIndex)` uses `PDFPageCanvas` inside the existing `ZoomableContainer`
  for paged mode, or the same canvas without the zoom container in webtoon mode.

The two leaf views share the current page label, retry/error treatment, tap-to-toggle chrome, and
page index. The page order remains an array reversal for R→L, never a transform. PDF pages do not
enter `ImageCache` and do not produce image-load reports; those reports belong to network image
URLs and covers, not a local document.

### 3. Rendering choice

Three plausible approaches were considered:

1. **`PDFView` per page.** It gives PDFKit rendering and built-in zoom, but nests a second scroll
   and gesture system inside the reader's `UIScrollView`, duplicates the pager's zoom ownership,
   and makes webtoon sizing/gesture behavior harder to control.
2. **Draw a PDF page into a bitmap at the current zoom scale.** It keeps the view simple, but
   reallocates large images during pinch and can visibly blur or stutter while the scale changes.
3. **A `CATiledLayer`-backed page canvas (selected).** A small `UIView` owns one `PDFDocument` and
   page index, and its tiled layer calls `PDFPage.draw(with:to:)` for the tile bounds. The outer
   `ZoomableContainer` remains the sole zoom/pan owner. Tiles are rendered at the display scale,
   invalidated by the normal layer lifecycle, and discarded by Core Animation under memory
   pressure.

The selected approach preserves the reader's tested interaction contract and makes zoom sharp
without a full-page bitmap. `PDFPageCanvas` must account for PDF crop-box bounds and rotation when
choosing its aspect-fit frame, and must draw in the page's coordinate system with the required
Y-axis transform. It should expose a small injectable `PDFPageRendering` seam for unit tests;
tests must not inspect tile pixels as their primary correctness signal.

### 4. PDF document lifetime and memory

`LocalSource.pageReferences` returns URLs and indexes only. A `PDFDocumentSession` owned by the
reader presentation (or an injected actor-backed cache) opens the document once per chapter,
validates its page count, and hands page access to the UIKit canvas. Do not create one
`PDFDocument` per visible tile or retain all rendered pages.

The session keeps at most the current document plus the adjacent chapter's document while a
chapter transition is in flight. Within a chapter, the view may have the current page and the
pager's neighboring pages alive, but it must not pre-render every page. `CATiledLayer` owns tile
eviction; a canvas invalidates its layer and releases its document/page reference on
`dismantleUIView` or chapter change. If the document cannot be opened after import, the reader
uses the existing permanent page-load failure UI and never falls back to silently rasterizing.

Import must remain fast and small: copy/hash the PDF, read page count and page-one cover, write
`item.json`, then commit the staging directory. Page-count inspection is bounded by the PDF's
cross-reference work, not page pixel dimensions. Progress reports two deterministic milestones
for a PDF (`opening/counting` and `cover/committing`) rather than pretending each page was
rasterized.

### 5. Paged and webtoon behavior

Paged mode is unchanged structurally: a `ReaderPage` occupies one `TabView` page and the outer
`ZoomableContainer` supplies pinch, pan, double-tap, and 1× reset when it is no longer selected.
Page turns should show the existing page view immediately; the next PDF page's first tile is
allowed to render asynchronously, with the existing screentone/retry state while the canvas is
not ready. A document open and page lookup are performed once per chapter, not once per swipe.

Webtoon mode keeps one PDF page per existing `LazyVStack` row. The canvas reports its intrinsic
aspect ratio so the row's height is the page's fitted height; it does not make a single enormous
PDF document view. This preserves the existing frame measurement, restore, throttled progress,
and end-of-chapter behavior. Webtoon mode does not add pinch zoom in v1; it remains the current
continuous fitted-page experience.

### 6. Import migration and cleanup

Already-imported rasterized PDFs are left alone. Their `LocalChapter.pageFiles` continue to yield
`.image` references, so they remain readable and are not rewritten, re-hashed, or unexpectedly
expanded. There is no reliable original PDF to recover because the accepted v1 importer deleted it.

Re-importing the same original PDF is currently a duplicate by SHA-256 and would not create a
vector copy. Therefore the migration policy is: **old items stay raster; a user who wants vector
rendering must first delete the old item and import the original PDF again.** The UI should make
the consequence explicit in the duplicate message or a one-time migration note, and the owner
must approve whether delete-and-reimport is acceptable (see open questions).

New PDF deletion removes `document.pdf`, `cover.jpg`, and `item.json` with the same existing
item-directory deletion. No orphaned raster pages exist for a vector import. Failed imports remove
the staging directory as today; a destination collision still reports duplicate and removes the
staging copy.

### 7. Password-protected PDFs and malformed documents

V1 behavior remains the current behavior: if `PDFDocument` is locked, import fails with
`LocalImportError.passwordProtectedPDF` and the existing user-facing “This PDF is
password-protected” message. No password prompt is added. A malformed, zero-page, or page-count-
unreadable PDF fails with `unreadablePDF`, leaving no item directory. A PDF that imports
successfully but later cannot be reopened is a permanent reader error with Retry omitted, matching
the existing reader failure classification rather than silently producing blank pages.

## Data and persistence changes

1. Add a version-tolerant PDF storage discriminator to `LocalItemRecord`/`LocalChapter`, such as
   `pageStorage: .images(files)` or `.pdf(documentFilename:)`. Missing keys decode as the current
   image form, so every existing `item.json` remains readable. Keep `pageCount` in both forms.
2. For new PDFs, write `document.pdf` into the item directory and persist the document filename;
   do not persist absolute PDF URLs. `LocalLibraryPaths.relocated` continues to repair URLs derived
   from the current root, while `LocalSource` derives the document path from the current store
   root at read time.
3. Add `LocalLibraryStore.pageReferences(itemId:chapter:)` and a `LocalSource` implementation of
   `VectorPageProviding`. Retain `pageURLs` for archive pages and legacy raster PDFs.
4. Refactor `ReaderViewModel`'s `[URL]` page state and prefetch closure to a page-reference state
   without changing persisted `ReadingEntry.page` or `pageCount`. Existing history is indexed by
   page ordinal, which remains stable because the PDF page count is recorded at import.
5. Keep `LocalLibraryStore.itemSize` and `delete` as the disk accounting and cleanup authority;
   no second PDF cache or database is introduced.

## Error and edge cases

- A rotated or non-letter page uses PDF crop-box bounds plus page rotation to determine its fitted
  canvas size; the index and page count stay unchanged.
- A PDF with a valid document but a missing page at a recorded index fails that page/chapter load;
  it is not silently skipped, because skipping would corrupt progress ordinals.
- A document opened in place from iCloud is coordinated/copied at import as today. Reading later
  uses the app-container copy and does not require an active security-scoped bookmark or network.
- Duplicate detection remains byte-hash based. The same bytes are not imported twice, regardless
  of whether the first item is raster legacy data or a vector item; a future “upgrade” action is
  an owner decision, not an implicit import side effect.
- Low-memory pressure may evict tiles and cause them to redraw; it must not evict the committed
  PDF file. The implementation must avoid `Data(contentsOf:)` for whole-page raster buffers.
- Source failures and empty page references continue through `ReaderViewModel`'s existing
  load-then-commit and permanent/transient presentation rules.
- R→L uses the existing reversed page-reference order. No PDF canvas or document transform may
  mirror content or reverse the page's writing direction.

## Accessibility

- Every PDF page has the same accessibility element shape and label as an image page:
  `ReaderAccessibility.pageLabel(index:pageCount:)`, announced as “Page n of total”. The page
  index is the logical reader index after the R→L page-order reversal, not a PDF object number.
- Keep the `readerPageIndicator` accessibility identifier unchanged and keep its spoken label
  generated by `ReaderAccessibility.pageIndicatorLabel` (`ReaderView.swift:675-690`).
- The vector canvas is decorative content inside the already-labelled page element; it must not
  expose PDFKit's internal controls, links, annotations, or a second VoiceOver focus target.
- VoiceOver focus and page announcements must work while a tile is still rendering; the page
  element exists before the first tile completes. Retry remains a labelled button when rendering
  fails.
- Reduce motion/transparency behavior remains owned by `ReaderView`; the PDF renderer introduces
  no new brand colors, controls, or animation.

## Files open-in-place

No document-type or Launch Services change is required. PDF remains an Alternate document type and
`LSSupportsOpeningDocumentsInPlace` stays true (`MangaCarta/Info.plist:22-29`). Files opening in
place still delivers the original URL to `LocalImportViewModel`, whose coordinated read creates the
app-owned `document.pdf`; outside files are never deleted. Share-to-app continues to deliver a
copy, which is also copied into Application Support and cleaned from the app container after
processing. A user may remove or rename the original after import without breaking the reader.

## Testing and acceptance criteria

Each criterion names its primary test. These tests are design requirements; do not run them while
drafting this spec.

1. **Import stores one PDF and no page raster set.** A small three-page fixture imports with one
   `document.pdf`, one cover, and `item.json`; `pages/` is absent and the record has page count 3.
   **Test:** `PDFVectorImportTests` in `MangaCartaTests/`.
2. **Page count and page references are stable.** The fixture yields ordered indices 0, 1, 2,
   correct chapter count, current-root document URLs, and a missing/zero-page PDF is rejected.
   **Test:** `PDFVectorImportTests`.
3. **Password behavior remains v1.** A locked fixture throws `passwordProtectedPDF`, leaves no
   destination directory, and preserves the existing user-facing message.
   **Test:** `PDFVectorImportTests`.
4. **Legacy records remain image-backed.** A pre-vector `item.json` with JPEG `pageFiles` returns
   `.image` references and is not migrated or rewritten.
   **Test:** `PDFVectorImportTests`.
5. **Reader seam has one path.** An injected source returning image URLs and an injected local
   vector provider both produce the same page count, landing, chapter advance, and progress
   ordinals; only the leaf renderer differs. **Test:** `ReaderPagePipelineTests` in
   `MangaCartaTests/`.
6. **Paged vector zoom is sharp and bounded.** A hermetic UI fixture imports a PDF, opens its first
   chapter, verifies `readerPageIndicator`, performs a pinch/double-tap zoom, and verifies the
   page remains addressable and the next page can still be turned. **Test:**
   `LocalPDFReaderUITests` in `MangaCartaUITests/`.
7. **Webtoon uses existing rows.** The same fixture can switch to webtoon mode, exposes one
   VoiceOver page element per PDF page with “Page n of total”, restores a saved ordinal, and
   reaches the existing end marker. **Test:** `LocalPDFReaderUITests`.
8. **R→L is page reversal only.** The UI fixture verifies page 3 is the first logical page in
   right-to-left mode and that zoom/pan coordinates are not mirrored. **Test:**
   `LocalPDFReaderUITests`.
9. **Cleanup and open-in behavior are safe.** Deleting a vector local item removes its document
   and metadata; an open-in-place URL outside the app container remains on disk after import.
   **Test:** `PDFVectorImportTests` plus the existing open-in importer test seam.
10. **Accessibility identifiers do not regress.** The page indicator remains identified as
    `readerPageIndicator`, and page elements use the existing `ReaderAccessibility` label helper.
    **Test:** `LocalPDFReaderUITests`.

New Swift files under `MangaCartaTests/` and `MangaCartaUITests/` are not synchronized groups and
must be added with `xcp add-file` for their respective targets. A new renderer under
`MangaCarta/Views/Components/` is inside the synchronized Components group and needs no
`project.pbxproj` edit. No build or test run is part of this design task.

## Implementation slices

1. **Storage and import:** add the version-tolerant PDF storage record, keep the copied PDF, count
   pages, generate the cover, and preserve staging/cancellation/error behavior.
2. **Source/page seam:** add `ReaderPage`, `VectorPageProviding`, and LocalSource references;
   prove legacy image records and new vector records through unit tests.
3. **Paged renderer:** add the `CATiledLayer` canvas inside `ZoomableContainer`, refactor the
   reader leaf to accept `ReaderPage`, and add vector page lifecycle/memory tests.
4. **Webtoon and accessibility:** render the same canvas in existing rows, preserve frame
   measurement/progress, and add the hermetic PDF zoom/accessibility UI test.
5. **Cleanup and manual verification:** verify Files open-in-place and Share paths, duplicate and
   delete behavior, low-memory redraw, rotated pages, and R→L on an iPhone 17 Pro simulator.

## Open questions for the owner

1. **Recommended: approve delete-and-reimport for legacy raster PDFs.** Old imports do not retain
   the source PDF, and silently replacing their page files would change stored page URLs and disk
   state. Should the product explicitly tell a user to delete the old item and re-import the
   original PDF when they want vector rendering?
2. **Recommended: keep password-protected PDFs rejected in v1.** This preserves the shipped error
   path and avoids storing credentials or adding a password UI. Should v1 continue to reject all
   locked PDFs even when a user could supply a password?
3. **Recommended: use the selected CATiledLayer canvas and retain the existing 4× zoom maximum.**
   This keeps one zoom owner and avoids a nested PDFView gesture system. Should the owner accept
   the current 4× maximum for PDFs rather than introducing a PDF-specific zoom limit?
4. **Recommended: retain the PDF as the only page source and a raster cover only.** This gives the
   smallest import and avoids a hidden second copy, at the cost of first-tile rendering on the
   first open. Should new PDFs ever keep an optional low-resolution page cache for offline/low-
   memory fallback, or is vector-only reader content the intended invariant?
5. **Recommended: no PDF text/search/accessibility extraction in this PR.** VoiceOver should
   announce the stable page element (“Page n of total”), while PDF text remains visual content.
   Should text selection/search be a separate product feature rather than part of vector rendering?
