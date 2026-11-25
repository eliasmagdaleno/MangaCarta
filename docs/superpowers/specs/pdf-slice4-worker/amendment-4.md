
## Amendment 4 (2026-11-19): slice 4 rechecked against `main` at `b2c3b01`

Slice 3 (#415) draws `.pdf` pages in paged mode through `PDFPageCanvas` (`Views/Components/PDFPageCanvas.swift`),
sized by `PDFPageGeometry.displayedSize` and opened by the reader's `PDFDocumentSession`. The webtoon call site
(`ReaderView.verticalReader`) still shows `UndrawnPDFPage` at a fixed 460 pt. Imports still default to `.raster`
(`LocalLibraryStore(root:pdfImport:)`). Rechecked against `main`, eight things are settled for slice 4:

1. **A webtoon PDF row is a strip like an image row.** `WebtoonPage` gives each image row a frame reporter
   (`StripFramesKey`, with `isDecoded`) and an anchor grid (`stripAnchorSlots` `StripAnchor` ids); progress
   capture, restore and the end-of-chapter trigger all read them (ADR-0014). The undrawn PDF row has neither, so
   a PDF chapter could not save or restore a webtoon position. Slice 4 moves the reporter and grid into one shared
   modifier that both `WebtoonPage` and a new `WebtoonPDFPage` use. `WebtoonPDFPage` asks the reader's
   `PDFDocumentSession` for the page, draws `PDFPageCanvas` at `.aspectRatio(displayedSize, contentMode: .fit)`
   and full width, and reports `isDecoded: true`, because its height is final as soon as the page opens: no tile
   needs to finish first. A page that cannot be opened shows `UndrawnPDFPage` at 460 pt with `isDecoded: false`,
   as a failed image row does. Its accessibility element and label match `WebtoonPage`'s. No pinch zoom in
   webtoon (design §5).
2. **The canvas must not take touches.** Webtoon's chrome toggle is a SwiftUI tap gesture on the `LazyVStack`.
   A `UIView` with user interaction on would receive the touch and hide it from that gesture. Paged mode does not
   need the canvas to take touches either: its zoom, double-tap and chrome tap are gesture recognizers on
   `ZoomableContainer`'s scroll view, which still get touches that land on a non-interactive subview. So
   `PDFPageCanvasView.isUserInteractionEnabled = false`.
3. **Off-screen rows give back their tiles.** `LazyVStack` keeps rows it has built, so a long PDF read top to
   bottom would otherwise hold every page's tile cache. The canvas clears its layer contents when it leaves a
   window (`didMoveToWindow` with `window == nil`) and redraws when it returns. The low-memory device check stays
   in slice 5.
4. **The flip, and the raster path goes.** Production imports PDFs as `.vector`. `PDFImportMode`, its `pdfImport:`
   parameter, `PDFPageRasterizer.swift` and `PDFRasterizationError` are deleted, and `importPDF` keeps only the
   vector path and its error mapping. `MangaCartaTests/PDFImportTests.swift` asserted the raster output; each of
   its four cases now has a vector counterpart in `PDFVectorImportTests` (three pages, rotated cover, corrupt and
   zero-page, locked), so the file is removed with `xcp delete-file`. `rasterModeIsStillTheDefault` becomes
   `productionStoreImportsPDFsAsVector`, through `LocalLibraryStore(root:)` with no mode argument, the same
   construction `MangaCartaApp` uses.
5. **The duplicate message for a legacy raster PDF (owner decision 1).** Duplicates are found by byte hash
   before the importer knows the format, and `LocalImportViewModel` shows "<file>: Already in your library" for
   every `.duplicate`. A new `LocalLibraryStore.isLegacyRasterPDF(itemId:)` is true when the stored record's
   `sourceFilename` has a `pdf` extension (case-insensitive) and every chapter is `.images`. For such an item
   the message is "<file>: Already in your library as an older import. Delete it and import again for sharp
   pages." Every other duplicate keeps the existing message. A raster PDF that was imported under a non-`.pdf`
   name keeps the existing message; there is no reliable way to tell it from an archive.
6. **The UI fixture route needs no change.** `importUITestFixtureIfRequested` writes the fixture as
   `<name>.cbz` whatever it holds, but the importer recognizes a PDF by its `%PDF-` bytes
   (`LocalLibraryStore.importArchive`), so a PDF fixture imports as a vector PDF through the same path the Files
   picker uses. The item's title is the name without its extension either way. Its stored `sourceFilename`
   ends `.cbz`, which nothing shows and which item 5 never sees for a vector item.
7. **`LocalPDFReaderUITests`, hermetic, on CI's list.** It launches with `-uitest-local-import` and
   `-uitest-import-fixture`, with a PDF fixture the test builds in code (`UIGraphicsPDFRenderer`, several pages,
   each visibly numbered). It covers criteria 6 (paged: page indicator, a double-tap or pinch zoom, the page
   still labelled, the next page reachable), 7 (webtoon through `readerModeMenu`: one "Page n of total" element
   per page, a saved position restored after closing and reopening, the end mark reached), 8 (right-to-left:
   opens on page 1 and reaches page 2 by an R→L swipe; no mirror transform exists anywhere in the PDF path) and 10
   (`readerPageIndicator` unchanged). The suite goes on `.github/workflows/ci.yml`'s hermetic list, with the line
   continuation every other line has.
8. **What a user sees once this ships:** a newly imported PDF is stored as the PDF itself and reads sharp at
   every zoom in paged mode and at full width in webtoon. PDFs imported before stay readable as they are.
   Importing one of those again explains how to get sharp pages.

Slice 4's acceptance: criteria 6, 7, 8 and 10, the flip (item 4) and the duplicate message (item 5). Slice 5 (the
manual device checks) follows the merge.
