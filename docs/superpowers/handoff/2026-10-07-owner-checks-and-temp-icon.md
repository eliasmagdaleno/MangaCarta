# Handoff: owner checks run on the simulator; temporary app icon; notification-permission bug filed

Date: 2026-10-07. This is the one live handoff. The prior one (`2026-10-05-sweep-two-shipped.md`) is
in `archive/`, and every open item in it is carried here. Recheck GitHub and the working tree before
acting.

## State

- **#355 merged** (`c059b8a`): the 2026-10-05 handoff, after the second defect sweep (#342–#348,
  fixed in #349–#354) and MangaDex engine v3.
- **#351's notification tap is verified on the simulator.** A `simctl push` payload carrying a real
  `workId` was tapped once with the app backgrounded (Vagabond) and once on a cold launch (Dorohedoro).
  Both opened the Work's detail page on the Library tab. The technique is in Operating notes.
- **#356 filed:** the app never asks for notification permission.
  `UpdateNotifier.requestAuthorizationIfNeeded()` has no caller in the app, and there is no explainer
  sheet, against ADR-0021's "after the first save" rule. A new user never gets notifications unless
  they switch "Notify about new chapters" off and on. Found while verifying #351.
- **Image-load reports: the client works, but MangaDex's endpoint is down.** MangaDex was updated to
  bundle v3 on the seeded simulator (the disclosure sheet showed), and Dorohedoro ch. 2 was read to
  page 4. All 27 reports were dropped with `HostCapabilityError(code: timeout)`. From the Mac,
  `POST https://api.mangadex.network/report` returns **Cloudflare 522** after about 19.5 s over IPv4
  and IPv6, while `api.mangadex.org/ping` answers 200 in 60 ms. That is MangaDex's origin failing,
  not the app. The reader was unaffected.
- **PR #357 is open: a temporary app icon** (concept A1, a brush "M" with a 漫 seal; light, dark and
  tinted). It also deletes `scripts/make-app-icon.swift` and updates `docs/design/app-icon-brief.md`.
  Auto-merge is **off**; the owner merges. It's built locally on Xcode 26, and CI's Xcode 16.4 hasn't
  been seen on it yet. The dark and tinted icons were confirmed only in the compiled asset catalog
  (`assetutil`), not on a home screen, because the simulator's home-screen icon style is pinned to
  Light.
- **Asking for age again on the MangaDex update is intended,** not a bug: turning "Show adult content"
  off clears `settings.declaredAgeOver18` (`RepositorySettingsViewModel.setAdultSourcesVisible`).

**Working tree:** the main checkout still has the owner's uncommitted `.agents/skills/*` and
`skills-lock.json` edits; leave them. `stash@{0}` is old `project.pbxproj` churn (drop is fine).
Worktrees: `~/orca/workspaces/Manga-Reader/icon-concepts` (Orca, branch `feat/temp-app-icon-a1`, #357)
and this handoff's own.

## Next

1. **#356 is ready for an agent.** It's small: present an explainer on the first save, call the
   existing `requestAuthorizationIfNeeded()`, and work test-first. The acceptance list and a required
   mutation are in the issue.
2. **After #357 merges** (check `state == MERGED` first): delete branch `feat/temp-app-icon-a1` and
   remove the Orca worktree (`orca worktree rm --worktree path:/Users/eliasmagdaleno/orca/workspaces/Manga-Reader/icon-concepts --force --json`).
   It holds untracked concept files (`icon-concepts/`, `icon-concepts/round2/`, `ICON-TASK*.md`) that
   go with it. Ask the owner first if they want the round-2 PNGs kept anywhere. If CI fails on the
   asset catalog's dark or tinted entries (Xcode 16.4), that's the likely cause.
3. Otherwise, as before: ask the owner, or run another defect sweep (method in Operating notes).
   Don't invent refactors.

Known, deliberately unfiled: a Work merged into one that **already** has a MAL id, by a path other
than `MetadataUpgradeQueue`, fires no `workMetadataChanged`, so its deferred MAL progress waits for
the next signal for that Work (#352's PR body). File it only with evidence a real path does this.

## Owner items

1. **#294's device checks.** Opening in place hands over the reader's original file:
   - an iCloud `.cbz` that has not been downloaded yet (Files → long-press → Remove Download, then
     tap): confirm it downloads, imports with title and cover, and stays in iCloud Drive;
   - a real device with another comic app that also claims `.cbz` at `Owner`: report which app a
     tap opens and that Open With lists MangaCarta.
2. **VoiceOver device pass (#90).** `scripts/voiceover-pass.sh` walks the 8 checklist sections and
   writes `docs/accessibility/voiceover-results-<date>.md`. Close #90 when every row has a verdict.
3. **MAL live-write check.** Sign the simulator app into MAL first. Then, in the owner's own
   terminal: `python3 scripts/mal_oauth_token.py`, `export MAL_ACCESS_TOKEN=…`,
   `python3 scripts/mal_live_write.py fire` (it snapshots the Horimiya entry, runs the test, restores).
   Meaningful only if the list is below 124 chapters. Eyeball #302's MAL avatar in the same session.
4. **Merge #357** (temporary icon) when CI is green. The commissioned icon is still the real
   replacement: `docs/design/app-icon-brief.md` is ready to send, and its status line now names the
   temporary icon.
5. **A real image-load report reaching MangaDex**: blocked on MangaDex. Recheck the endpoint with
   `curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" --data '{}' https://api.mangadex.network/report`.
   While it returns 522 there's nothing to test. Once it doesn't, read a chapter on the seeded
   simulator (already on v3) and confirm no `Image-load report dropped` lines appear in
   `log stream --level debug --predicate 'process == "MangaCarta" AND category == "ImageLoadReporter"'`.
   Success is silent, so also check that the endpoint answers a POST with 2xx.
6. **App Store prep** (`docs/app-store/submission-copy.md`): not until the owner says so.
   - the owner's sample and screenshot art, a sample URL or attachment, and contact placeholders;
     recheck every claim against the build that ships, §5 included;
   - accept or drop the three candidate bullets #325 lists (per-title direction, ComicInfo +
     series, Open in);
   - decide whether third-party site logos belong in a no-content build (`SourceLogo-mangadex` and
     `SourceLogo-weebcentral` match only legacy ids, not installed Sources' qualified ids).
7. **Bare 429s (optional):** a 429 with no retry header does not pause (Amendment 8, on purpose).
   Revisit only with evidence of a Source that sends bare 429s.

## Seeded simulator: changed 2026-10-07

- Backup before today's changes: `~/Manga-Reader-sim-backup-2026-10-07-pre-notif` (Application
  Support + Preferences).
- **The installed build is #357's branch** (`feat/temp-app-icon-a1`, built from `c059b8a` plus the
  icon).
- Notification permission is **granted**. `settings.declaredAgeOver18` is **true** (confirmed on the
  v3 update). `settings.showAdultSources` is still false.
- The MangaDex Source is on **bundle v3** (declares image-load reports). WeebCentral is unchanged.
- History gained Dorohedoro ch. 2, read to page 4 of 26.
- Appearance was switched dark and back to light. The home-screen icon style is pinned to Light.

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
- **Merging.** The owner asks for merges by PR number (#292–#294, #297–#302, #309, #311, #341, #349–#355 so far). Treat each
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

- **"No Work → unchanged" needs a same-Listing test.** #332's first version put the opened
  `manga.id` into the listing set even with no Work, which quietly turned on ordinal matching
  *within* one Listing (two groups' chapter 7 shared a resume marker; unread on one cleared the
  other). A cross-Listing no-Work test can't see that. `testWithoutWorkSameListingOrdinalDoesNotMatch`
  now guards it.
- **Two PRs squash-merged back to back never ran CI together.** #336 and #337 both edited
  `HistoryStore` and merged within a minute. Run the full unit suite on the resulting `main` (done
  here, green) before building on it.
- **A worker's unit-test run can kill your UI run.** Two `RepositorySettingsUITests` failures on
  #329's branch happened while the #330 worker was testing on the same simulator; alone the suite
  passed 5/5. Run the hermetic UI suites only when no worker is mid-test.
- **A worker's "mutation run hung" is not a result.** #332's worker applied its third mutation but
  the run hung on launch; it said so honestly. Re-run that mutation yourself before opening the PR.
- **Small fixes don't need a worker.** #331 was ~15 lines over an existing lookup; writing the spec
  would have cost more than the change. Dispatch when there is real implementation to delegate.

- **Sweep method that worked (2026-10-04, 2026-10-05).** Two read-only workers on different
  providers, split by area (Sources+reader / Library+history+tracking+launch); spec forbids edits
  and requires file:line plus a user repro per finding; workers write reports to the ignored
  `.worktrees/`; the coordinator verifies each against `main` before filing. 7 of 7 held up.
- **Workers' tests miss the case the fix is for, and their own mutations don't show it.** Twice
  today (#347, #348) the worker's mutation was real but a *different* mutation of the same fix
  survived — the tests parked the stale load on the wrong await, or used different manga ids. Run
  a mutation of your own on the line the issue is about, not the one the worker picked.
- **Parallel workers starve each other's mutation runs.** Three workers on one simulator: two
  reported `failed` only because their mutation/full-suite runs couldn't launch. The specs now
  say to retry launch failures 5× at 60s. Plan to run the mutation and full suite yourself.
- **`Timed out waiting for AX loaded notification`** fails a UI run before any test executes.
  `xcrun simctl shutdown` + `boot` the seeded simulator and rerun; it passed 20/20 after.
- **Swift Testing suites are selected by struct name**, not file name
  (`-only-testing:MangaCartaTests/MALAccountStoreLifecycleTests`). A wrong selector runs 0 tests
  and reports success — check the count before trusting a "mutation survived".
- **`LegacySourceID.unattributed` is `"mangadex"`.** A Library item or Manga with no `sourceId`
  keys as legacy MangaDex, not as local — don't fall back to it for local items.
- **zsh arrays are 1-indexed.** A `T=("" …)` / `${T[$i]}` loop written for bash shifted every
  issue title by one; feed titles through `while read` instead.
- **Stale PR CI after a sibling merges.** When two PRs touch one file and one merges, run
  `gh pr update-branch <n>` on the other so CI runs on the combined code (done for #353).

- **Tapping a real notification on the simulator (2026-10-07).** Write an `.apns` file with
  `"Simulator Target Bundle": "Elias-Magdaleno.Manga-Reader"`, an `aps.alert`, and a top-level
  `"workId": "<a WorkID UUID from works.json>"` (`UpdateNotifier.workIdUserInfoKey`). Send it with
  `xcrun simctl push <udid> Elias-Magdaleno.Manga-Reader <file>`. It reaches the same
  `UpdateNotificationDelegate.didReceive` a local notification does. The app must have permission
  first (see #356). For a cold-launch tap, `simctl terminate` before pushing.
- **Drive the simulator with the iOS Simulator control tool, and name the device on every call.**
  After a desktop-app restart it silently defaulted to the also-booted "iPhone 16 Pro (CI repro)",
  and a tap landed there. Separately, clicking around Device Hub with computer-use brought up
  "Remove iPhone 16 Pro (CI repro)?", which Escape didn't dismiss. Avoid Device Hub clicks for
  simulator work.
- **Watching an app's network calls on the simulator:** `xcrun simctl spawn <udid> log stream --level
  debug --predicate 'process == "MangaCarta" AND (...)'`. The
  `com.apple.networkextension` `ne_tracker_check_is_hostname_blocked` lines name every host the app
  resolves, which shows a request was attempted. `lsof` on the app's pid showed no TCP sockets, so
  don't rely on it. macOS has no `timeout`; background the stream and `kill` it.
- **`ImageLoadReporter` logs only failures, and only in DEBUG** (`Image-load report dropped: …`).
  A silent log isn't proof of delivery; probe the endpoint directly as well.
- **Codex can generate images** (`codex features list` shows `image_generation stable true`, CLI
  0.160.1). Driven through Orca like any worker, it made both icon rounds. What worked: generate
  only the light variant, derive dark and tinted from its pixels (so the composition can't drift),
  and have it check any kanji. Verify `sips -g hasAlpha` and the sizes yourself.
- **A long chain of mutating commands in one Bash call can be refused** by the auto-mode classifier
  ("Irreversible Local Destruction") when it overwrites a tracked file and `git rm`s another.
  Splitting it into single, reversible steps went through, and the `git rm` ran once the owner
  approved it.
