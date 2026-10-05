# Handoff: #328 fix awaiting merge; read state goes Work-wide (ADR-0027)

Date: 2026-10-04 (late). This is the one live handoff. The prior one
(`2026-10-04-agent-queue-empty-owner-gates.md`) is in `archive/`; every open item in it is carried
here. Recheck GitHub and the working tree before acting.

## State

`main` is at `6eceebd`. Since the previous handoff:

- **#327** merged — the previous handoff.
- **Defect sweep** filed five verified bugs: #328, #329, #330, and the follow-ups #331, #332 (all
  labelled `bug`, none `ready-for-agent` yet — the owner chooses dispatch).
- **#333** merged — **ADR-0027: read state is per Work, matched by `ChapterOrdinal`.** Owner
  decision. Storage stays Listing-keyed; the Work-wide answer is derived from `work.listings`;
  unparseable chapter numbers match by id only; marking unread clears the ordinal on every Listing;
  no Work → unchanged. Glossary gained a **Read** entry.
- **#334 open, all four CI checks green, awaiting the owner's merge** — fixes #328: the detail page's
  readers now open on the *active* Listing (`MangaDetailViewModel.readerManga`, `Manga.relisted(as:)`),
  history names the Listing the chapter came from, and Continue uses
  `HistoryStore.latestEntry(forMangaIds:)` over the Work's Listings. Built by a Luna worker (Orca run
  `run_cfa81edc5d6f`, released); reviewed, mutation re-run, lint clean, 5 hermetic UI suites 20/20.

**Working tree / cleanup owed:** after #334 is `MERGED` (check the state first), remove worktree
`/private/tmp/mc-328` and delete branch `fix/328-reader-follows-listing` locally and on origin.
The main checkout has uncommitted `.agents/skills/*` and `skills-lock.json` edits that predate this
session and are the owner's — leave them. `stash@{0}` is old `project.pbxproj` churn (drop is fine).

## Next

Agent-dispatchable once the owner says go; suggested order:

1. **Merge #334** (owner), then clean up as above.
2. **#332 — chapter rows read state Work-wide.** Spec = ADR-0027 + the decision comment on #332.
   Build **one shared Work-wide read lookup** (chapter id read, or ordinal read on any Listing of the
   Work) that chapter rows, the resume marker, #331 and `LibraryUpdatesPresentation:66` all use —
   move that existing union behind it, don't copy it. Every mark/unmark call site passes the active
   Listing's `Manga` (`vm.readerManga` after #334); `markUnread` clears the ordinal across Listings.
   Update `CLAUDE.md`'s read-state paragraph in the same PR.
3. **#331 — Library badge Work-wide**, on #332's lookup. Small.
4. **#329 — clearing History un-reads finished chapters** (convert complete entries to `ReadMark`s
   on `clear`/`delete`/cap trim). Independent of 2–3; only touches `HistoryStore`/`HistoryView`, so it
   can run on a second worker in parallel with #332 — but **#332 and #329 both edit `HistoryStore`**;
   expect a small rebase.
5. **#330 — automatic refresh never updates Library badges** (apply `latestChapterNumbers` at the
   end of every `run`, or per Work in `step`). Independent.

Each issue carries Symptom / Cause / Fix / Acceptance with mutation checks; turn that into the
worker spec the way #328's was (named test per acceptance item, "report succeeded ONLY if…").

## Owner items

1. **#294's device checks.** Opening in place hands over the reader's original file:
   - an iCloud `.cbz` that has not been downloaded yet — coordinated since #309; confirm on a
     signed-in device that it downloads and imports;
   - a real device with another comic app that also claims `.cbz` at `Owner`.
2. **VoiceOver device pass (#90).** #326 cleared the mechanical findings; traversal order,
   announcements and focus restoration (after sheets and after closing the reader) need a person.
3. **MAL live-write check.** No agent holds a MAL token: `scripts/mal_oauth_token.py` prints one and
   never saves it, and the harness cannot read the simulator keychain. In the owner's own terminal:
   `python3 scripts/mal_oauth_token.py`, `export MAL_ACCESS_TOKEN=…`, then
   `scripts/mal_live_write.py fire` (it snapshots the Horimiya entry, runs the test, restores).
   The MAL avatar change in #302 can be eyeballed in the same signed-in session.
4. **App icon** — `docs/design/app-icon-brief.md`.
5. **App Store prep** (`docs/app-store/submission-copy.md`):
   - owner's sample and screenshot art, a sample URL/attachment, and contact placeholders; recheck
     every claim against the build that ships, §5 included;
   - accept or drop the three candidate bullets #325 lists (per-title direction, ComicInfo +
     series, Open in);
   - decide whether third-party site logos belong in a no-content build. The asset catalog still
     ships `SourceLogo-mangadex` and `SourceLogo-weebcentral`; `SourceLogoView` looks logos up as
     `SourceLogo-<sourceID>`, so they now match only the legacy built-in ids, not installed
     Sources' qualified ids.
6. **The engine change, only after an App Store build with Host API 1.3 ships.** Made in
   `proxy-link/mangacarta-sources`; push through the SSH alias only, and never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`, and bump the bundle `version` to 3 (2 shipped for #315).
   - Update the test fixture copy and its `index.json` hash in the same change
     (`testIndexPinsThisEngine`).
   - If it ships too early, current builds see no version intersection and refuse the update.
   - Existing readers will see the update sheet (Amendment 10) the first time they update.
7. **A real report reaching an endpoint.** Only the sheet is covered (#284). Delivery cannot be
   tested locally (`HostURLPolicy` refuses non-public addresses, loopback included). Check it with
   the real engine against MangaDex once item 6 ships.
8. **Bare 429s (optional):** a 429 with no retry header does not pause. Amendment 8 chose that on
   purpose. Revisit only with evidence of a Source that sends bare 429s.

## Watch list

- `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
  suspect the test's own launch timeout.
- The loopback test retries and logs. If it recurs, search the CI log for `[loopback-flake]` (#289).
- `@Sendable` on `AdultContentSetting.current` is **not** redundant: the target is Swift 5 mode
  without `InferSendableFromCaptures`. Keep it.

## Operating notes

- **Plans written here can be wrong about the code; the worker is the first to find out.** #290's
  plan was self-reviewed and still missed three things (above). What worked: a spec per task that
  said "report succeeded ONLY if every acceptance item holds", and ruling promptly when the worker
  escalated. Grep a plan's claims ("only call site", "the helper") before dispatching.
- **A Codex worker can ask the same question twice** — once as an `escalation`, then again as a
  blocking `question` before it has read the reply. Answer the `question` with `orchestration reply
  --id <msg>`; that unblocks it. Nudge an idle worker with `orca terminal send … --enter`.
- **Reusing one worker terminal across tasks works:** `worker-start --spec … --terminal <worker>
  --from <coordinator>`. A receipt of `outcome_unknown` / `turn_start_unobserved` still delivered the
  task here — read the terminal (`orca terminal read`) before retrying anything.
- **Close a menu in a UI test by tapping one of its entries, never the button behind it.** On CI's
  iOS 26.2 the menu's own button is unreachable while its menu is open (`kAXErrorCannotComplete`
  on scroll-to-visible); on 26.5 it happens to work. That, not reopening the reader, is what failed
  #307's CI — see "Completed" below.
- **SwiftLint on changed files, in zsh:** `git diff --name-only main...HEAD | grep '\.swift$' |
  xargs swiftlint lint`. `swiftlint lint $F` does not word-split in zsh, so it lints the whole repo
  and the existing warnings look like yours.
- **Testing that a read is coordinated:** register an `NSFilePresenter` on the file and implement
  `relinquishPresentedItem(toReader:)`; only coordinated reads call it (#309's test). Its
  `@Sendable` signature is newer-SDK, but a mismatch only warns and still matches, so it holds on
  CI's Xcode 16.4.
- **Check a mutation actually landed** (`git diff` after the edit) before trusting its result. A
  `sed` against a line that had since been reformatted matched nothing, and the "mutation" run
  passed — which reads exactly like a test that can't detect the mutation.
- **Never background a `check --wait` with `&` inside a tool call.** It survives as an orphan waiter,
  and the next `check --wait` fails with `waiter_exists`. Use the harness's background mode.

- **a parallel test run leaves nothing in the seeded container.** It executes on
  cloned simulators whose containers are discarded. A parallel full run showed 0 leftover plists
  where the serial run of the same code showed 66. Keep parallel on for pass/fail, but pass
  `-parallel-testing-enabled NO` for any check that inspects the seeded container afterwards.
- **`xcp add-file` fails on `/private/tmp/...` paths** ("Group not found in the
  project"). Use the `/tmp/...` spelling of the same worktree path; it then writes a clean
  4-line change.
- **Luna's `failed` can be the honest answer.** On #296 it reported `failed` because its
  own no-leftovers check did not hold, and that was correct: it had found the cfprefsd write-back.
  Read the summary before discarding a `failed`.
- **undoing a mutation with `git checkout -- <file>` reverts to the last commit,** not to
  your uncommitted edit, and silently throws that edit away. It happened here. Commit before a
  mutation, or undo it with the inverse `sed`.
- **Luna's "succeeded" is not evidence.** On slice 6 the first pass reported `succeeded` while its own
  summary said most acceptance tests were missing. What worked: a spec that mapped every acceptance
  item to a named test, named the mutations to run, and said "report succeeded ONLY if every item
  above is done". Keep reading each test against its acceptance item.
- **A branch's unit tests run its launch migrations on the seeded fixture.** Unit tests are hosted in
  the app, so `xcodebuild test` installs and launches that branch's build on `ADDAB2F8-…`. A migration
  under test is not reversible by switching back to `main`; back up the container first.
- **Reading a `check --wait` result.** The consumed output is pretty-printed JSON across many lines
  after the dropped `_keepalive` lines, so parse from the first `{`, not the last line. A
  `worker_done`'s task, dispatch and outcome live in the message's `payload` string.
- **Swift Testing and actors.** `#expect(... store.root ...)` on an actor's `let` fails to compile
  inside the macro expansion. Hold the value in a local before the `#expect`.
- **Merging.** The owner asks for merges by PR number (#292–#294, #297–#302, #309, #311 so far). Treat each
  request as covering the PRs it names, not as a standing permission. Use
  `gh pr merge <n> --squash` once all four checks pass, or `--squash --auto` to wait for CI; gate
  branch cleanup on `state == MERGED`.
- **How Files decides who opens a document (iOS 26.5).** "Open With" lists only apps with
  `LSSupportsOpeningDocumentsInPlace = true`, and a tap opens the app only at `Owner` rank. Launch
  Services lists every claimant regardless. Spec decision 14 has the full table.
- **A probe app for Launch Services questions.** A 60-line UIKit app built with
  `xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator`, a hand-written
  `Info.plist`, `codesign -s -`, then `simctl install` and `simctl launch --console-pty`. Vary one
  Info.plist key per install and check Files by hand. Not in the repo.
- **A probe test for runtime questions.** Append a temporary `@Test` to a Swift Testing file that
  already imports `Testing` (e.g. `AdultContentFilterTests.swift`; add `import Foundation`), run it
  alone with `-only-testing:'MangaCartaTests/<name>()'`, and `print("PROBE …")`. Both of today's
  root causes were found this way in minutes. `MangaCartaTests.swift` cannot take one: adding
  `import Testing` there makes `Tag` ambiguous.
- **Putting files into the simulator's Files app.** Copy them into the
  `group.com.apple.FileProvider.LocalStorage` app group's `File Provider Storage` directory; they
  appear under On My iPhone. Tapping a `.cbz` there opens MangaCarta and imports it.
- **Device Hub click hazard.** Dismissing a Files context menu by clicking where a menu item sits
  runs that item. Dismiss by clicking well outside the menu.
- **Orca and Codex:** verified 2026-09-30 — Orca **1.4.217** runs Codex without the temporary
  readiness wrapper; launch with `--agent codex --model gpt-5.6-luna --effort medium`. If
  `agent_readiness` timeouts return, the owner's wrapper may still be at
  `~/.local/share/orca-codex-compat/codex`; check versions, then fall back to it. Don't delete it
  unasked. Three failures on one Task fail it permanently; stop after two.
- **Orca from outside an Orca terminal:** `orca terminal create --worktree path:<wt> --json` (the
  selector needs the `/private/tmp/...` spelling; `/tmp/...` gives `selector_not_found`) and pass
  that handle as `--from` to `run-create` / `worker-start`; `--worktree path:<wt>` works for an
  existing non-Orca worktree. A consuming `check` takes `--terminal <handle>`. `worker-release` takes
  neither. Never pipe `check --wait` into `head`. Close the coordinator terminal when done
  (`orca terminal close --terminal <handle>`).
- **Messages do not wake an idle Codex worker.** Prompt it with
  `orca terminal send --terminal <handle> --text "<instruction>" --enter --wait-submit 20 --json`.
- **Worker claims need checking.** Review the diff against the acceptance list, run
  `swiftlint lint` yourself on the changed files (a bare `swiftlint lint` with an empty file list
  lints the whole repo, whose existing warnings look like yours), and re-run a mutation of your own.
- **A merge-when-green script must fail closed.** Require exactly the expected number of `pass`
  lines (4 today) and treat a `gh` error as "do not merge".
- **Boot the seeded simulator before testing.** A cold boot by `xcodebuild` can fail with
  `Busy ("Application failed preflight checks")`.
  `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 && xcrun simctl bootstatus <udid>`.
- **A test that awaits a condition needs a deadline.** A wait with no deadline hung a whole run once.
- **Swift Testing and `-test-iterations`.** It *does* repeat Swift Testing tests. To reproduce a
  scheduling flake, force the bad order instead.
- **URLSession retries a lost connection on its own** (three attempts before -1005).
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, iOS 26.5:
  MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`). Read `settings.showAdultSources`
  before relying on it. **Changed 2026-09-29/30:**
  - `Library/Preferences` went from 16,778 files (66 MB) to 9: the app's own plist (byte-identical
    before and after) plus the app-created `*-ui-test*` suites. Backup of the folder:
    `~/Manga-Reader-sim-backup-2026-09-29-pre-296-prefs`.
  - `tmp/` went from 47,743 entries (3.7 GB) to 17: the Files inbox, fixed-name UI-test folders,
    WebKit folders, `deflated.cbz`. Not backed up (download scratch and test fixtures only).
  - Library still holds the three local test series ("Trilogy Check", "Open In Check",
    "In Place Check"); Files still holds the test `.cbz`/`.zip`/`.pdf` files.
  - `tmp/` holds 18 known entries plus `MangaCartaTests/` (the #303 sweep's folder) after the
    2026-09-30 cleanup.
  - The installed build is unverified: #305's branch build as of the last serial run, but #307's
    tests ran in parallel (clones), so check before relying on which build is installed.
  - Older backups: `~/Manga-Reader-sim-backup-2026-09-29-pre-openin/` and
    `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`.
- **The app's data container moves on every reinstall, and every test run reinstalls.** Look it up
  with `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` right before use
  while booted, then edit plists with PlistBuddy while shut down. Never use
  `simctl spawn … defaults write`. Read the app's settings from
  `Library/Preferences/Elias-Magdaleno.Manga-Reader.plist` only.
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above, and keep parallel testing
  on for pass/fail runs.
- **Keep build products out of the repo.** `build/` is not ignored; use a `-derivedDataPath` under
  session scratch.
- **`/private/tmp` can be wiped between sessions**, so push work before ending one.
- **The simulator GUI is Device Hub.** Live UI tests run by name on clones; see the header of
  `MangaCartaUITests.swift`.
- **Temporary directories in tests (#303):** use `makeTestDirectory("<prefix>")` in XCTest, or
  `TestDirectory("<prefix>")` + `defer { dir.remove() }` in Swift Testing. A fixture class holds its
  `TestDirectory` and removes it in `deinit`. A Swift Testing suite that needs several directories
  per test is a `final class` with one root per test, removed in `deinit` (Swift Testing makes a
  fresh instance per test). Everything lives under `tmp/MangaCartaTests/`, swept after ten minutes.
- **A computed property can't be read in a class `init`** before every stored property is set. Take
  a local (`let directory = testDirectory.url`) at the top of the `init` instead.
- **Grep the whole call path before telling the owner something doesn't exist.** On 2026-09-30 a
  grep limited to `Local*` files missed that local import mints its Work through
  `LibraryStore.toggle`; the claim went to the owner and had to be corrected.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.

- **Publishing an engine has a short window where installs fail.** `raw.githubusercontent.com` serves
  the new `engine.js` at once, while GitHub Pages serves the old `index.json` (old hash) for a few
  minutes. An install in that window fails the hash check. Confirm the Pages index carries the new
  hash before calling a publish done.
- **Engine-supplied numbers never go straight into `Int(_:)`.** It traps on huge, infinite or NaN
  doubles. Range-check first (#316).

- **Parallel workers must not run UI suites at the same time.** Two workers sharing the seeded
  simulator both got signal-killed hermetic UI runs on 2026-10-01 (#317's worker reported `failed`
  for it). Run alone, the same suites passed 19/19. Have parallel workers run unit tests only, then
  run the 5 CI-gated hermetic suites yourself, one branch at a time:
  `-only-testing:MangaCartaUITests/UpdatesUITests -only-testing:MangaCartaUITests/SourcePreferenceUITests -only-testing:MangaCartaUITests/RepositorySettingsUITests -only-testing:MangaCartaUITests/LocalImportUITests -only-testing:MangaCartaUITests/AccessibilityAuditUITests`.
- **`Secrets.xcconfig` is not in a fresh worktree.** It is gitignored (it holds `MAL_CLIENT_ID`, read into `MALClientID`) and is
  the target's base configuration. #318's worker copied it in from the main checkout to build;
  builds in the #315 worktree passed without it. If a worktree build complains about it, copy it in
  and never commit it.
- **Check a worker's stated exceptions, not just its diff.** #317's worker left one test on the
  standard domain "deliberately"; that test already held an isolated suite, and the exception was
  wrong.
- **A single-test `xcodebuild` run can hang after the result prints** (seen with a Swift Testing
  `-only-testing:'Suite/test()'` selector). Read the output file; if the verdict is there, kill the
  process instead of waiting.

- **Reading an accessibility audit.** `performAccessibilityAudit`'s issue handler gets the element;
  print `elementType.rawValue` (9 button, 43 image, 48 static text), label and identifier, and return
  `true` to collect rather than fail. Judge every finding against a screenshot: here contrast fired
  on text under the tab bar's blur, and text-clipped on labels that render whole.
- **A `.plain` button's hit region is its label.** A frame, padding or fill applied to the `Button`
  itself is drawn but not tappable; put them inside the label and end with `.contentShape(...)`
  *after* the padding (#326).
- **Viewing a UI test's screenshots:** run with `-resultBundlePath <scratch>/x.xcresult`, then
  `xcrun xcresulttool export attachments --path <it> --output-path <dir>`; `manifest.json` maps
  attachment names to files.

- **Orca can update and restart itself mid-run** (1.4.218 → 1.4.220 on 2026-10-04). A pending
  `check --wait` then returns `runtime_unavailable` / `outcome_unknown`, and the worker shows
  `unverifiable` / `restored_unconfirmed`. The worker survived. Prove it with
  `lsof -a -p <codex pid> -d cwd` pointing at the worktree. **`--retry-request <id>` only replays the
  cancelled result** (`connectionLost: true`, no messages); start a fresh `check --wait` instead.
- **`LocalImportUITests` ran ~27 min for one test locally** during #334's hermetic run (passed; CI
  took the normal ~12 min for the whole job). Likely simulator state, not code. If it recurs, look at
  the seeded simulator before the test.
- **The UI-test two-listing fixture can't catch wrong-Source reads**: both fixture sources return `[]`
  from `pageURLs` for any chapter id. Test Listing routing at the view-model seam
  (`MangaDetailRetargetTests`), not through UI tests.
