# Handoff: local import is feature-complete (slices 1–6); #294's unchecked cases and #296 are next

Date: 2026-09-29 (late). This is the one live handoff. The prior one
(`2026-09-29-cbz-default-opener-shipped.md`) is in `archive/`; every open item in it is carried
here. Recheck GitHub and the working tree before acting.

## Completed this session

- **#297** the previous handoff, merged.
- **#298 fixes #295:** covers of imported books no longer break when the app's data container
  moves. `LocalLibraryPaths.relocated(_:root:)` re-roots a saved local cover URL onto the current
  `LocalLibrary` directory, and the `LibraryItem` and `ReadingEntry` decoders apply it, so covers
  already saved on devices repair themselves the next time they load. Merged.
- **#299, local-import slice 6, Series grouping.** **Auto-merge is queued; when this was written its
  build & unit tests job was still pending.** Check that it is `MERGED` before building on it (see
  Next 1). Decisions 15–17 and a "Slice 6 design" section were added to
  `docs/superpowers/specs/2026-09-22-local-import-design.md`:
  - a series is `series-<32 hex>` from the normalised ComicInfo `Series`, even with one member;
  - chapter numbers are stable (`Number`, else `Volume`, else filename digits, else position;
    folder chapters `base.k`; collisions `.1`) and always decimal-parseable;
  - deleting a series deletes every member;
  - a one-shot, idempotent launch migration moves pre-slice-6 items that have a `Series`.
  Built by two Codex Luna passes through Orca and reviewed here. The review found a real bug:
  `WorkStore.moveListing` gave two Works the same series Listing. It also removed a duplicate
  launch migration and added the whole-series delete test. Checked on the simulator with a real
  three-volume series imported in the order 2, 3, 1.

With #299 merged, **all six local-import slices have shipped.** Per-volume delete, manual merge
and split, filename grouping, and matching local series against MAL or AniList are recorded out
of scope in the spec.

**Working tree:** `main` at `a63fd2c` plus this handoff. One extra worktree remains,
`~/orca/workspaces/Manga-Reader/feat-local-series-grouping` (#299's). `stash@{0}` is still the
Xcode `project.pbxproj` churn from before #291. It is noise: `git stash drop` is fine, and
`git stash pop` would conflict.

## Next

1. **Close out #299.** Once `gh pr view 299 --json state -q .state` prints `MERGED`, remove its
   worktree (`orca worktree rm --worktree path:<wt> --json`) and delete the branch
   `eliasmagdaleno/feat-local-series-grouping`, locally and on origin. If CI failed instead, the PR
   is still open: read the failing job before changing anything, since flaky live-network UI
   tests exist (see Other outstanding work 3).
2. **#294's unchecked cases.** Opening in place hands over the reader's original file, not a copy:
   - an iCloud `.cbz` that has not been downloaded yet (may need a coordinated read);
   - a real device, ideally with another comic app that also claims `.cbz` at `Owner`.
3. **#296: unit tests leave their `UserDefaults(suiteName:)` plists behind.** 15,467 files (61 MB)
   sit in the seeded simulator's `Library/Preferences`, in the same container as the fixture.
   Remove each suite when its test ends; a helper returning a suite plus its cleanup covers most
   prefixes. This is not a leak into the real `library.items`; that was checked.
4. **The engine change, only after an App Store build with Host API 1.3 ships.** It is made in
   `proxy-link/mangacarta-sources`. Push it through the SSH alias only, and never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`.
   - If it ships too early, current builds see no version intersection and refuse the update.
   - Existing readers will see the update sheet (Amendment 10) the first time they update.
5. **A real report reaching an endpoint.** Only the sheet is covered (#284). Delivery cannot be
   tested locally (`HostURLPolicy` refuses non-public addresses, loopback included). Check it with
   the real engine against MangaDex once item 4 ships.
6. **Bare 429s (optional):** a 429 with no retry header does not pause. Amendment 8 chose that on
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
   - the MAL live-write check (`TEST_RUNNER_MAL_LIVE_WRITE=1`);
   - the name/trademark check (#150);
   - the app icon brief (`docs/design/app-icon-brief.md`);
   - design nit, owner's call: the reports/age sheet styles Install and Cancel identically.

## Operating notes

- **New today — Luna's "succeeded" is not evidence, twice in one day.** On slice 6 the first pass
  reported `succeeded` while its own summary said most acceptance tests were missing and no mutation
  had run. What worked: a follow-up spec that listed each review finding, required every acceptance
  item mapped to a named test, named the exact mutations to run, and said "report succeeded ONLY
  if every item above is done". Even then the item-6 test was single-member and asserted nothing
  after the delete; review caught it. Keep reading each test against its acceptance item.
- **New today — a branch's unit tests run its launch migrations on the seeded fixture.** Unit tests
  are hosted in the app, so `xcodebuild test` installs and launches that branch's build on
  `ADDAB2F8-…`. Slice 6's migration moved the fixture's local items before any manual check. That
  was useful here, but a migration under test is not reversible by switching back to `main`. Back
  up the container first (see below) when a branch adds one.
- **New today — reading a `check --wait` result.** The consumed output is pretty-printed JSON across
  many lines after the dropped `_keepalive` lines, so parse from the first `{`, not the last line.
  A `worker_done`'s task, dispatch and outcome live in the message's `payload` string, not in
  top-level fields.
- **New today — Swift Testing and actors.** `#expect(... store.root ...)` on an actor's `let` fails
  to compile ("actor-isolated property … cannot be accessed from outside of the actor") inside the
  macro expansion. Hold the value in a local before the `#expect`.
- **Merging.** The owner merged PRs themselves until 2026-09-29, then asked for #292–#294, #297,
  #298 and #299 by number. Treat each request as covering the PRs it names, not as a standing
  permission. Merges used `gh pr merge <n> --squash` once all four checks passed, or
  `--squash --auto` to wait for CI.
- **How Files decides who opens a document (iOS 26.5).** "Open With" lists only apps with
  `LSSupportsOpeningDocumentsInPlace = true`, and a tap opens the app only at `Owner` rank. Launch
  Services lists every claimant regardless, so probing Launch Services alone does not predict
  Files. Spec decision 14 has the full table.
- **A probe app for Launch Services questions.** A 60-line UIKit app built with
  `xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator`, a hand-written
  `Info.plist`, `codesign -s -`, then `simctl install` and `simctl launch --console-pty` gets answers
  in seconds without touching MangaCarta. Vary one Info.plist key per install and check Files by
  hand. The probe lived in session scratch; it is not in the repo.
- **Putting files into the simulator's Files app.** Copy them into the
  `group.com.apple.FileProvider.LocalStorage` app group's `File Provider Storage` directory (find it
  via each AppGroup's `.com.apple.mobile_container_manager.metadata.plist`); they appear under
  On My iPhone. Tapping a `.cbz` there now opens MangaCarta and imports it, which is the quickest
  way to import by hand.
- **Device Hub click hazard.** Dismissing a Files context menu by clicking where a menu item sits
  runs that item. One click ran "New Folder with Item". Dismiss by clicking well outside the menu.
- **A single Swift Testing free function runs with**
  `-only-testing:'MangaCartaTests/<functionName>()'`.
- **Orca and Codex:** Orca 1.4.216 does not recognise Codex 0.158 as ready; `worker-start` times out
  at `agent_readiness` unless the temporary wrapper `~/.local/share/orca-codex-compat/codex` exists
  (`--agent codex` uses it automatically). Three failures on one Task fail it permanently; stop
  after two.
- **Orca from outside an Orca terminal:** `orca terminal create --worktree path:<wt> --json` and pass
  that handle as `--from` to `run-create` / `worker-start`. A consuming `check` takes
  `--terminal <handle>`. `worker-release` takes neither. Never pipe `check --wait` into `head`.
  A new worktree: `orca worktree create --name <n> --repo path:<repo> --base-branch main --setup skip --no-parent --json`,
  then copy `Secrets.xcconfig` in. A follow-up on a settled Task: release the worker, then
  `worker-start --spec` a new Task in the same worktree (`--worktree "id:<repo-id>::<abs path>"`).
  Reusing the idle terminal fails at `agent_readiness`.
- **Messages do not wake an idle Codex worker.** It shows "You have N orchestration messages" and
  waits. Prompt it with
  `orca terminal send --terminal <handle> --text "<instruction>" --enter --wait-submit 20 --json`.
- **Worker claims need checking.** Review the diff against the acceptance list, run
  `swiftlint lint` yourself, and re-run at least one mutation of your own.
- **Gate branch cleanup on MERGED** (test `state == MERGED`; #278 was closed by accident).
- **A merge-when-green script must fail closed.** Require exactly the expected number of `pass`
  lines (4 today) and treat a `gh` error as "do not merge".
- **Boot the seeded simulator before testing.** A cold boot by `xcodebuild` can fail with
  `Busy ("Application failed preflight checks")`, and the code is not the cause.
  `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 && xcrun simctl bootstatus <udid>`.
- **A test that awaits a condition needs a deadline.** A wait with no deadline hung a whole run once.
- **Swift Testing and `-test-iterations`.** It *does* repeat Swift Testing tests (200 runs verified
  2026-09-29). Looping does not change scheduling, though, so to reproduce a scheduling flake, force
  the bad order (e.g. delay one task).
- **URLSession retries a lost connection on its own** (three attempts before -1005). A test server
  that drops one connection is invisible to the client.
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, iOS 26.5:
  MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`). Read `settings.showAdultSources`
  before relying on it (it read `false` on 2026-09-28). **Changed today:**
  - Library holds three local test series: "Trilogy Check" (three volumes), plus "Open In Check"
    and "In Place Check", which the slice-6 migration moved to `series-…` ids.
  - Files holds `open-in-check.cbz`, `in-place-check.cbz`, `trilogy-v1…3.cbz`,
    `plain-archive.zip` and `plain-document.pdf`.
  - The installed app is #299's branch build.
  - Backups: `~/Manga-Reader-sim-backup-2026-09-29-pre-openin/` (before today's checks, so before
    any test books or migration) and `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`.
- **The app's data container moves on every reinstall, and every test run reinstalls.** Look it up
  with `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` right before use
  while booted, then edit plists with PlistBuddy while shut down. Never use
  `simctl spawn … defaults write`. Read the app's settings from
  `Library/Preferences/Elias-Magdaleno.Manga-Reader.plist` only; that folder also holds thousands of
  test-suite plists (#296).
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above, and keep parallel testing on.
- **Keep build products out of the repo.** `build/` is not ignored; use a `-derivedDataPath` under
  session scratch.
- **`/private/tmp` can be wiped between sessions**, so push work before ending one.
- **The simulator GUI is Device Hub.** Live UI tests run by name on clones; see the header of
  `MangaCartaUITests.swift`.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
