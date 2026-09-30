# Handoff: test litter fixed (#296 via #301), AsyncImage temp-file leak fixed (#302); #294 checks next

Date: 2026-09-29 (evening). This is the one live handoff. The prior one
(`2026-09-29-series-grouping-shipped.md`) is in `archive/`; every open item in it is carried
here. Recheck GitHub and the working tree before acting.

## Completed this session

- **#300**, the previous handoff, merged after reverting 167 lines of unrelated `project.pbxproj`
  churn that Xcode had written into its branch.
- **#301 fixes #296: unit tests no longer pile up `UserDefaults` plists.** Merged as `56b6587`.
  - `MangaCartaTests/TestDefaults.swift` is the one way a test makes a suite: `makeTestDefaults("x")`
    in XCTest (removal is a teardown block), `TestDefaults("x")` + `defer { suite.remove() }` in
    Swift Testing. 22 files / ~87 sites converted (Codex Luna via Orca, reviewed and finished here).
  - **The issue's proposed fix was insufficient**, measured on the simulator:
    `removePersistentDomain` leaves the plist on disk; deleting the file alone leaves values in
    cfprefsd's cache; doing both still loses a race, because once the plist has reached disk
    cfprefsd can write an emptied copy back *after* the delete. So `remove()` is best effort, and
    the guarantee is a sweep: suites are named `MangaCartaTests.<prefix>.<UUID>`, and the first
    `TestDefaults` a process creates deletes any older than ten minutes. The ten minutes protects
    a second run sharing the simulator. The doc comment in `TestDefaults.swift` has the numbers.
  - `scripts/seed-simulator.sh` now clears `MangaCartaTests.*.plist` instead of the old `seed-*` names.
- **#302: SwiftUI `AsyncImage` leaked one `CFNetworkDownload_*.tmp` per image load.** Merged as `05c0869`.
  - Probe: 10 loads left 10 files, finished or cancelled; `URLSession` data tasks,
    `URLSessionDataFetcher` and `ImageCache` left none. 33,657 files / 3.7 GB had piled up in the
    seeded simulator, nearly all 512-pixel covers from before #237 moved covers to `CachedAsyncImage`.
  - The last user, the MAL avatar in `MALAccountSettingsView`, now uses `CachedAsyncImage`.
    **Not checked on screen** — the avatar needs a signed-in MAL account.
  - A SwiftLint custom rule, `no_swiftui_async_image`, makes `AsyncImage(` an error outside
    `CachedAsyncImage.swift` (verified against `main`'s old avatar code).
- **Filed #303:** unit tests also leave ~14,000 temporary directories (~45 MB) in `tmp/`. Counts
  per prefix and the fix direction (a `TestDefaults`-style helper plus sweep) are in the issue.
- **Seeded simulator cleaned** (see Operating notes for what is left and where the backup is).

**Working tree:** `main` at `05c0869` plus this handoff; no other worktrees or open PRs besides
this one. `stash@{0}` is still the Xcode `project.pbxproj` churn from before #291. It is noise:
`git stash drop` is fine, and `git stash pop` would conflict.

## Next

1. **#294's unchecked cases.** Opening in place hands over the reader's original file, not a copy:
   - an iCloud `.cbz` that has not been downloaded yet (may need a coordinated read);
   - a real device, ideally with another comic app that also claims `.cbz` at `Owner`.
2. **#303: test temporary directories.** Same shape as #296; small (~45 MB). Measure serially (see
   Operating notes). The seeded simulator's `tmp/` was emptied on 2026-09-29, so a count starts from zero.
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

1. **Per-title reading direction (#290).** Needs a design: keyed by Work or Listing, where it is
   set, and how it takes precedence over the global setting. ComicInfo `Manga=YesAndRightToLeft` is
   the natural initial value for local imports once it exists.
2. **App Store prep** (`docs/app-store/submission-copy.md`):
   - still needs the owner's sample and screenshot art, a sample URL/attachment, and contact
     placeholders; recheck every claim against the build that ships, §5 included;
   - the asset catalog still ships `SourceLogo-mangadex` and `SourceLogo-weebcentral`.
     `SourceLogoView` looks logos up as `SourceLogo-<sourceID>`, so they now match only the legacy
     built-in ids, not installed Sources' qualified ids. Decide whether third-party site logos belong
     in a no-content build before submitting;
   - the copy may now mention ComicInfo metadata, Open in, opening `.cbz` from Files, and series
     grouping (#291, #294, #299). That is the owner's call.
3. **Flaky tests:**
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
     suspect the test's own launch timeout.
   - The loopback test now retries and logs. If it recurs, search the CI log for
     `[loopback-flake]` (#289).
4. **Deferred minor:** `SourceRegistry.setInstalledSources` restores a stored chosen Source by
   existence alone. `active` still gates it, so it is contained. (`@Sendable` on
   `AdultContentSetting.current` is **not** redundant: the target is Swift 5 mode without
   `InferSendableFromCaptures`. Keep it.)
5. **`MangaDexSource` / `MangaDexAPI`** still compile for AniList, MAL and the resolver, but nothing
   registers them. Narrowing them is a separate refactor; injecting `UserDefaults` into
   `SourceRegistry` fits the same pass.
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

- **New today — a parallel test run leaves nothing in the seeded container.** It executes on
  cloned simulators whose containers are discarded. A parallel full run showed 0 leftover plists
  where the serial run of the same code showed 66. Keep parallel on for pass/fail, but pass
  `-parallel-testing-enabled NO` for any check that inspects the seeded container afterwards.
- **New today — `xcp add-file` fails on `/private/tmp/...` paths** ("Group not found in the
  project"). Use the `/tmp/...` spelling of the same worktree path; it then writes a clean
  4-line change.
- **New today — Luna's `failed` can be the honest answer.** On #296 it reported `failed` because its
  own no-leftovers check did not hold, and that was correct: it had found the cfprefsd write-back.
  Read the summary before discarding a `failed`.
- **New today — undoing a mutation with `git checkout -- <file>` reverts to the last commit,** not to
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
- **Orca and Codex:** Orca 1.4.216 does not recognise Codex 0.158 as ready; `worker-start` times out
  at `agent_readiness` unless the temporary wrapper `~/.local/share/orca-codex-compat/codex` exists
  (`--agent codex` uses it automatically). Three failures on one Task fail it permanently; stop
  after two.
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
  before relying on it. **Changed today:**
  - `Library/Preferences` went from 16,778 files (66 MB) to 9: the app's own plist (byte-identical
    before and after) plus the app-created `*-ui-test*` suites. Backup of the folder:
    `~/Manga-Reader-sim-backup-2026-09-29-pre-296-prefs`.
  - `tmp/` went from 47,743 entries (3.7 GB) to 17: the Files inbox, fixed-name UI-test folders,
    WebKit folders, `deflated.cbz`. Not backed up (download scratch and test fixtures only).
  - Library still holds the three local test series ("Trilogy Check", "Open In Check",
    "In Place Check"); Files still holds the test `.cbz`/`.zip`/`.pdf` files.
  - The installed app is #302's branch build, which is what merged.
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
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
