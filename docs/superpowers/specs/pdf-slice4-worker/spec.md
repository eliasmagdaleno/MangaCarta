# Task: MangaCarta vector PDF slice 4 — webtoon rows, the flip, the duplicate message, hermetic UI tests

Repository: MangaCarta (SwiftUI iOS app, no dependencies). Read `CLAUDE.md` first; its build rules apply.
Design: `docs/superpowers/specs/2026-11-09-vector-pdf-reader-design.md`, especially §5, "Testing and
acceptance criteria", and Amendments 1–3. **Amendment 4 is in this spec's folder:**
`docs/superpowers/specs/pdf-slice4-worker/amendment-4.md` (the worker's own copy was in session scratch).
It is the plan of record for this slice; where it and older text differ, Amendment 4 wins.

## Work in pieces — do ONLY the piece the coordinator names in each turn

The coordinator reviews between pieces. Do not start the next piece until told. Each piece ends with a
`worker_done` whose summary lists commits, test commands run with their results (both framework counts by name
when the full suite ran), and anything not done.

- **Piece A** (this first turn):
  1. Append Amendment 4 verbatim to the end of the design doc and commit it alone:
     `docs(pdf): Amendment 4 — slice 4 rechecked against main`.
  2. Amendment 4 items 1–3: the shared strip modifier (frame reporter + anchor grid) used by both `WebtoonPage`
     and a new `WebtoonPDFPage`; the webtoon call site in `ReaderView.verticalReader` uses `WebtoonPDFPage` for
     `.pdf` pages with the reader's existing `pdfSession`; `PDFPageCanvasView.isUserInteractionEnabled = false`;
     contents cleared on leaving a window and redrawn on return.
  3. Unit tests in `MangaCartaTests/PDFPageCanvasTests.swift` (Swift Testing): `testCanvasDoesNotTakeTouches`,
     `testLeavingTheWindowReleasesTilesAndReturningRedraws` (put the view in a `UIWindow`, remove it, assert
     `layer.contents == nil`, re-add, assert a redraw was requested; use a recording renderer or a
     `setNeedsDisplay` spy as you see fit, but the test must go red if `didMoveToWindow` is removed).
- **Piece B:** Amendment 4 items 4 and 5 (the flip, deletion of the raster path, the duplicate message), with
  tests named below.
- **Piece C:** Amendment 4 item 7: `MangaCartaUITests/LocalPDFReaderUITests.swift` and the CI list entry.
- **Piece D:** the mutations below, then the full verification.

## Acceptance → test (every one must exist and pass)

| Item | Test |
|---|---|
| Canvas takes no touches (A4 item 2) | `PDFPageCanvasTests.testCanvasDoesNotTakeTouches` |
| Tiles released off-window (A4 item 3) | `PDFPageCanvasTests.testLeavingTheWindowReleasesTilesAndReturningRedraws` |
| Production imports vector (A4 item 4) | `PDFVectorImportTests.productionStoreImportsPDFsAsVector` (replaces `rasterModeIsStillTheDefault`; builds `LocalLibraryStore(root:)` with no mode argument and asserts the chapter is `.pdf` and `document.pdf` exists) |
| Legacy raster duplicate message (A4 item 5) | `LocalImportViewModel`-level test `legacyRasterPDFDuplicateExplainsReimport`: hand-write a legacy record (`sourceFilename` `x.pdf`, `.images` chapter) at the item directory the fixture bytes hash to, import the same bytes, assert the exact new message |
| Other duplicates unchanged (A4 item 5) | `archiveDuplicateKeepsTheExistingMessage` (an `.images` record with a `.cbz` name → "Already in your library") and `vectorPDFDuplicateKeepsTheExistingMessage` |
| Criterion 6 — paged zoom | `LocalPDFReaderUITests.testPagedZoomKeepsThePageAndTurns` |
| Criterion 7 — webtoon | `LocalPDFReaderUITests.testWebtoonRowsLabelRestoreAndEnd`: one "Page n of total" element per page; the first page element's height ÷ width matches the fixture page's aspect within 3% (so a fixed-height row fails); tapping a page toggles the chrome; scroll to page 3, close, reopen → the indicator reads page 3; scroll to the end → the end mark exists |
| Criterion 8 — R→L | `LocalPDFReaderUITests.testRightToLeftOpensOnPageOneAndAdvancesBySwipingRight` |
| Criterion 10 | the indicator is found by `readerPageIndicator` in every test above |

## Mutations (Piece D) — each must turn the named test red; revert each and `git status` after every one

- M1 `WebtoonPDFPage` reports `isDecoded: false` → the webtoon restore test.
- M2 drop the shared modifier from `WebtoonPDFPage` → the webtoon restore test.
- M3 `isUserInteractionEnabled = true` → `testCanvasDoesNotTakeTouches` and the webtoon chrome-tap check.
- M4 remove the `didMoveToWindow` override → `testLeavingTheWindowReleasesTilesAndReturningRedraws`.
- M5 `WebtoonPDFPage` uses a fixed `.frame(height: 460)` instead of the aspect ratio → the webtoon aspect check.
- M6 `isLegacyRasterPDF` always `false` → `legacyRasterPDFDuplicateExplainsReimport`.
- M7 `isLegacyRasterPDF` ignores the extension → `archiveDuplicateKeepsTheExistingMessage`.
- M8 the vector import path bypassed (raster-shaped record with no `document.pdf`) → `productionStoreImportsPDFsAsVector`.
- M9 the R→L page reversal removed from `ReaderView`'s pager order → the R→L UI test.
Run each mutation's test by name and paste the red line. A run that executes 0 tests, or dies at launch, is not
a result: rerun it.

## Constraints

- **Simulator: ONLY `06CB4285-0173-4CDB-B844-A539740A7028` ("PDF2 iPhone 17 Pro", iOS 26.5).** Every
  `xcodebuild` uses `-destination 'platform=iOS Simulator,id=06CB4285-0173-4CDB-B844-A539740A7028'` and a
  `-derivedDataPath` under `/private/tmp/pdf-slice4-dd`. Never use any other simulator id or a name-based
  destination; another session is using the others. Boot it first if needed.
- CI builds with Xcode 16.4 / Swift 6.0: no isolated conformances, `nonisolated(nonsending)`, `@concurrent`,
  `Task.immediate`, or `weak let`.
- `MangaCartaTests/` and `MangaCartaUITests/` are not synchronized groups. Add and remove test files with `xcp`
  using the `/tmp/...` spelling of the worktree path; check `git diff --stat` on `project.pbxproj` before
  committing and keep only your change.
- `Secrets.xcconfig` is gitignored; if the build needs it, copy it from `/Users/eliasmagdaleno/Manga-Reader/` and
  never commit it. For UI runs, replace `MAL_CLIENT_ID`'s value with `ci-placeholder` (back the real file up
  first) and restore the file byte-identically afterwards; confirm with `cmp`.
- Build before every commit. SwiftLint must report 0 violations on changed files
  (`git diff --name-only main...HEAD | grep '\.swift$' | xargs swiftlint lint`), with **no `swiftlint:disable`
  anywhere in the diff.** One statement per line in tests; no `guard … else { return }` in a test (use
  `try #require`).
- Use `PDFFixtureWriter` (in `PDFVectorImportTests.swift`) for every PDF fixture written to disk.
- Do not touch analytics files or `ci.yml`'s structure beyond adding one hermetic-list line. Do not push, open a
  PR, or merge. Do not change behaviour Amendment 4 does not ask for; if something looks wrong, `ask` first.
- Commit messages: Conventional Commits, ending with `Co-Authored-By: Codex <noreply@openai.com>`.

## Final verification (end of Piece D)

Full unit suite (report the XCTest count and the Swift Testing count separately), the 11 CI-gated hermetic UI
suites (the 10 on `ci.yml`'s list plus `LocalPDFReaderUITests`) with `ci-placeholder`, SwiftLint, the mutation
table with red lines, `Secrets.xcconfig` restored (`cmp`), a clean `git status`. **Report `succeeded` only if
every acceptance row and every mutation holds;** otherwise report `failed` and say exactly what is missing.
