# Handoff: #303 shipped (#305); per-title reading mode (#290) designed and planned — implement next

Date: 2026-09-30. This is the one live handoff. The prior one
(`2026-09-29-test-litter-fixed.md`) is in `archive/`; every open item in it is carried here.
Recheck GitHub and the working tree before acting.

## Completed this session

- **#305 fixes #303: unit tests no longer leave temporary directories behind.** Merged as `1b649e1`.
  - `MangaCartaTests/TestDirectory.swift` is the one way a test gets a temporary directory (see
    Operating notes). All ~100 call sites in 32 files converted.
  - Serial full unit run on the seeded simulator: **1** directory left (an `imgcache` folder from a
    late asynchronous write; the next run's sweep removes it), down from 117 after the first
    conversion pass and ~14,000 accumulated before. No new top-level `tmp/` entries.
  - Codex Luna did the conversion via Orca and honestly reported `failed` (litter remained). The
    causes, fixed here: fixtures nested a UUID folder and removed only the inner one; Swift Testing
    helpers had no teardown; one `defer` removed a fixture's directory before the fixture used it.
  - 105 pre-fix litter entries from a 15:58 run on 2026-09-29 were deleted from the seeded
    container's `tmp/`, which is back to its 18 known entries plus `MangaCartaTests/`.
- **#290 per-title reading mode — designed, spec approved, plan written.** On this PR's branch:
  - `docs/adr/0026-reading-mode-is-per-work.md` — the decisions (owner-approved in conversation):
    keyed by **Work**; two tiers (the Work's own mode, else a global default); **every change in
    the reader is per title**; the default moves to a Settings "Reader" section and keeps the
    `readingMode` key; ComicInfo `Manga=YesAndRightToLeft` → right to left and `Manga=No` → left to
    right seed a local import's Work at import (only if it has no mode); merges carry the mode to
    the survivor. Source-supplied defaults are explicitly out (a future amendment).
  - `docs/superpowers/specs/2026-09-30-per-title-reading-mode-design.md` — the how. **Owner
    approved it.**
  - `docs/superpowers/plans/2026-09-30-per-title-reading-mode.md` — four TDD tasks with mutation
    checks. Written and self-reviewed; the owner asked to execute it in a fresh session.
  - `docs/glossary.md` gains "Reading mode".

**Working tree:** `main` at `1b649e1` plus this PR. `stash@{0}` is still the Xcode `project.pbxproj`
churn from before #291; it is noise (`git stash drop` is fine, `git stash pop` would conflict).

## Next

1. **Implement #290 from the plan.** Read the ADR, the spec, then the plan. The owner's routing
   preference (memory) is Codex Luna workers via Orca, one task at a time, with Claude reviewing each
   task before the next (the plan's "subagent-driven" option); confirm that with the owner before
   dispatching, since they chose "new session" rather than an execution method. Points to watch:
   - **Reads of `ReadingModeStore` must stay pure** — `ReaderView.body` calls them; the store
     re-keys merged Work ids only on writes (spec §1, plan Review Focus 1).
   - `ComicInfo` needs an explicit init with `manga: String? = nil` last, or existing test call
     sites stop compiling (plan Task 2).
   - The UI test deliberately uses one title, not the spec's two (the fixture hook imports one
     file); title-to-title isolation is pinned by a unit test instead. This is noted in the plan.
   - First Orca `worker-start` doubles as the check that Codex works without the wrapper (see
     Operating notes).
2. **#294's unchecked cases.** Opening in place hands over the reader's original file, not a copy:
   - an iCloud `.cbz` that has not been downloaded yet (may need a coordinated read);
   - a real device, ideally with another comic app that also claims `.cbz` at `Owner`.
3. **The engine change, only after an App Store build with Host API 1.3 ships.** It is made in
   `proxy-link/mangacarta-sources`. Push it through the SSH alias only, and never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`.
   - If it ships too early, current builds see no version intersection and refuse the update.
   - Existing readers will see the update sheet (Amendment 10) the first time they update.
4. **A real report reaching an endpoint.** Only the sheet is covered (#284). Delivery cannot be
   tested locally (`HostURLPolicy` refuses non-public addresses, loopback included). Check it with
   the real engine against MangaDex once item 3 ships.
5. **Bare 429s (optional):** a 429 with no retry header does not pause. Amendment 8 chose that on
   purpose. Revisit only with evidence of a Source that sends bare 429s.

## Other outstanding work

1. **App Store prep** (`docs/app-store/submission-copy.md`):
   - still needs the owner's sample and screenshot art, a sample URL/attachment, and contact
     placeholders; recheck every claim against the build that ships, §5 included;
   - the asset catalog still ships `SourceLogo-mangadex` and `SourceLogo-weebcentral`.
     `SourceLogoView` looks logos up as `SourceLogo-<sourceID>`, so they now match only the legacy
     built-in ids, not installed Sources' qualified ids. Decide whether third-party site logos belong
     in a no-content build before submitting;
   - the copy may now mention ComicInfo metadata, Open in, opening `.cbz` from Files, series
     grouping (#291, #294, #299) and, once shipped, per-title reading mode. That is the owner's call.
2. **Flaky tests:**
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
     suspect the test's own launch timeout.
   - The loopback test now retries and logs. If it recurs, search the CI log for
     `[loopback-flake]` (#289).
3. **Deferred minor:** `SourceRegistry.setInstalledSources` restores a stored chosen Source by
   existence alone. `active` still gates it, so it is contained. (`@Sendable` on
   `AdultContentSetting.current` is **not** redundant: the target is Swift 5 mode without
   `InferSendableFromCaptures`. Keep it.)
4. **`MangaDexSource` / `MangaDexAPI`** still compile for AniList, MAL and the resolver, but nothing
   registers them. Narrowing them is a separate refactor; injecting `UserDefaults` into
   `SourceRegistry` fits the same pass. Good background work for a worker.
5. **Source pins are lost on a Work merge.** `SourcePreferenceStore` keys by raw Work id and never
   follows `WorkStore`'s aliases (noticed 2026-09-30 while designing #290; not filed). The reading-mode
   store's read-resolves / write-rekeys rule would fix it the same way.
6. **Leftover remote branch:** `docs/handoff-2026-09-29` (#288, closed unmerged, superseded). It was
   left in place because it never merged; delete it only if the owner says so.
7. **Human gates:**
   - a VoiceOver device pass (#90);
   - the MAL live-write check (`TEST_RUNNER_MAL_LIVE_WRITE=1`) — the MAL avatar change in #302 can
     be eyeballed in the same signed-in session;
   - the name/trademark check (#150);
   - the app icon brief (`docs/design/app-icon-brief.md`);
   - design nit, owner's call: the reports/age sheet styles Install and Cancel identically.

## Operating notes

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
- **Merging.** The owner asks for merges by PR number (#292–#294, #297–#302 so far). Treat each
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
- **Orca and Codex (changed 2026-09-30):** the owner reports that Orca **1.4.217** runs Codex 0.158
  without the temporary readiness wrapper, so launch workers normally with `--agent codex`. Not
  yet verified by an agent: the first `worker-start` of the next session is the test. If
  `agent_readiness` timeouts return, the owner's wrapper may still be at
  `~/.local/share/orca-codex-compat/codex`; check versions, then fall back to it. Don't delete it
  unasked. Three failures on one Task fail it permanently; stop after two.
- **Orca from outside an Orca terminal:** `orca terminal create --worktree path:<wt> --json` and pass
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
  - The installed app is #305's branch build (`fix/test-temp-dirs`), which is what merged.
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
