# Handoff: SourceRegistry defaults injected (#317), AppComposition.init split (#318); agent-side follow-ups open as #323–#326

Date: 2026-10-01. This is the one live handoff. The prior one
(`2026-09-30-extension-failure-classification.md`) is in `archive/`; every open item in it is
carried here. Recheck GitHub and the working tree before acting.

## Completed this session

- **#315 / #316 — the reader stops offering Retry for failures retrying cannot fix** (merged as
  `666b886`). ADR-0012 Amendment 1 and Host API design Amendment 7 hold the rule; `http` is
  classified by `details.status`. Detail is in the archived handoff and the ADR.
- **MangaDex engine bundle version 2 is published** (`proxy-link/mangacarta-sources` `15a3823`). It
  sends `details.status` on `http` failures. The Pages index was confirmed serving the new hash.
- **#317 / #321 — `SourceRegistry` takes injected `UserDefaults`** (merged as `9161d37`).
  `init(sources:defaults:showAdultContent:)` uses it for both the read and the `didSet` write;
  production keeps `.standard`. Every test-built registry now has an isolated `TestDefaults` suite
  (14 files, checked across multi-line calls), so unit tests no longer read or overwrite the seeded
  simulator's `source.activeID`. Test: `activeChoicePersistsThroughTheInjectedSuite`; mutations of
  the read and the write each fail it.
- **#318 / #320 — `AppComposition.init` is under `function_body_length`** (merged as `87e3908`).
  `runIdentityMigrations(directory:defaults:)` and `makeMAL(...) -> MALGraph` were extracted; the
  MAL stack moved without changes. The side-effect order was compared before and after: identical.
- `CLAUDE.md`'s two overlong "Current state" lines were wrapped (#319).

**Later the same day (owner: "do everything besides the checks I need to do"):**

- **#323 (open)** — `setInstalledSources` restores a stored browse choice only while it is
  browsable now (`isBrowsableNow`, the rule `init` and `active` use). Closes the old "deferred
  minor". Test `testInstalledSourcesRestoreOnlyABrowsableStoredChoice`; each branch mutated fails it.
- **#324 (open)** — the install/age sheet's Install / Update / "I am 18 or over" take a vermilion
  fill (`SealFillButtonStyle`); Cancel is secondary ink. Owner's call — reject freely.
- **#325 (open)** — `submission-copy.md` rechecked against `main`: zoom is paged-only (bullet
  corrected), the garbled adult paragraph in the review notes rewritten, §5's stale "manifest
  declares only MAL" / "wiring unshipped" fixed. Three shipped-but-unclaimed features listed for
  the owner to accept or drop.
- **#326 (open)** — `AccessibilityAuditUITests` runs Xcode's accessibility audit on Home, Library,
  detail, reader and Settings (hermetic, local import) and is **added to CI's UI job**. Its 17
  findings → 0: empty-state buttons and the Manage Collections / Local library rows were only
  tappable on their text (a real tap bug), a decorative symbol read as "books.vertical", Library
  chip counts were ~3:1 contrast, the detail cover was an unlabeled image. `.contrast` and
  `.textClipped` are excluded as false positives (documented in the test). First run on CI's iOS
  26.2 happens on that PR.
- Remote branch `docs/handoff-2026-09-29` deleted (owner ran it; the auto-mode classifier blocked
  the agent).

**Working tree:** `main` at `9161d37`. Worktrees for #323–#326 live at `/tmp/mc-registry`,
`/tmp/mc-sheet`, `/tmp/mc-copy`, `/tmp/mc-a11y` (plain git worktrees); remove each and its branch
once its PR is MERGED. `stash@{0}` is still the Xcode
`project.pbxproj` churn from before #291; it is noise (`git stash drop` is fine, `git stash pop`
would conflict).

## Next

**Owner merges #322–#326** (each by number). After each merge, the agent removes that PR's
worktree and branch, gated on `state == MERGED`. If #326's CI fails on iOS 26.2, read the attached
`a11y-<screen>` screenshot before changing anything.

Beyond that, **no agent work is queued.** No open issue is `ready-for-agent`; the only open issue
is #90 (owner). An agent with nothing assigned should ask the owner, or look for real defects and file
them as issues after verifying each against `main`. Don't invent refactors.

## Owner items

1. **#294's device checks (owner).** Opening in place hands over the reader's original file:
   - an iCloud `.cbz` that has not been downloaded yet — now coordinated (#309); confirm on a
     signed-in device that it downloads and imports;
   - a real device with another comic app that also claims `.cbz` at `Owner`.
2. **The engine change, only after an App Store build with Host API 1.3 ships.** It is made in
   `proxy-link/mangacarta-sources`. Push it through the SSH alias only, and never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`, and bump the bundle `version` to 3 (2 shipped for #315).
   - Update the test fixture copy and its `index.json` hash in the same change
     (`testIndexPinsThisEngine`).
   - If it ships too early, current builds see no version intersection and refuse the update.
   - Existing readers will see the update sheet (Amendment 10) the first time they update.
3. **A real report reaching an endpoint.** Only the sheet is covered (#284). Delivery cannot be
   tested locally (`HostURLPolicy` refuses non-public addresses, loopback included). Check it with
   the real engine against MangaDex once item 2 ships.
4. **Bare 429s (optional):** a 429 with no retry header does not pause. Amendment 8 chose that on
   purpose. Revisit only with evidence of a Source that sends bare 429s.

## Other outstanding work

1. **App Store prep** (`docs/app-store/submission-copy.md`):
   - still needs the owner's sample and screenshot art, a sample URL/attachment, and contact
     placeholders; recheck every claim against the build that ships, §5 included;
   - the asset catalog still ships `SourceLogo-mangadex` and `SourceLogo-weebcentral`.
     `SourceLogoView` looks logos up as `SourceLogo-<sourceID>`, so they now match only the legacy
     built-in ids, not installed Sources' qualified ids. Decide whether third-party site logos belong
     in a no-content build before submitting;
   - whether to add the three candidate bullets #325 lists (per-title direction, ComicInfo +
     series, Open in). That is the owner's call.
2. **Flaky tests:**
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
     suspect the test's own launch timeout.
   - The loopback test now retries and logs. If it recurs, search the CI log for
     `[loopback-flake]` (#289).
3. **`@Sendable` on `AdultContentSetting.current` is not redundant:** the target is Swift 5 mode
   without `InferSendableFromCaptures`. Keep it.
4. **Human gates:**
   - a VoiceOver device pass (#90) — #326's audit clears the mechanical findings first; traversal
     order, announcements and focus restoration are still the person's;
   - the MAL live-write check. **No agent holds a MAL token** — `scripts/mal_oauth_token.py` prints
     one and never saves it, and the harness can't read the simulator keychain. The owner runs, in
     their own terminal: `python3 scripts/mal_oauth_token.py`, `export MAL_ACCESS_TOKEN=…`,
     `scripts/mal_live_write.py fire`. The MAL avatar change in #302 can be eyeballed in the same
     signed-in session;
   - the app icon brief (`docs/design/app-icon-brief.md`).

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
  run the CI-gated hermetic suites yourself (4, or 5 once #326 merges), one branch at a time:
  `-only-testing:MangaCartaUITests/UpdatesUITests -only-testing:MangaCartaUITests/SourcePreferenceUITests -only-testing:MangaCartaUITests/RepositorySettingsUITests -only-testing:MangaCartaUITests/LocalImportUITests`.
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
