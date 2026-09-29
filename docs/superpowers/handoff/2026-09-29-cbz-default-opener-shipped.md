# Handoff: .cbz opens in MangaCarta from Files; Series grouping and two new bugs are next

Date: 2026-09-29 (evening). This is the one live handoff. The prior one
(`2026-09-29-local-import-slice5-shipped.md`) is in `archive/`; every open item in it is carried
here. Recheck GitHub and the working tree before acting.

## Completed this session

All merged with four green CI checks. The owner asked for the merges this session; before that,
merging was theirs (see Operating notes).

- **#292** the previous handoff. **#288**, the draft it superseded, is closed.
- **#293** CI job timeouts: `timeout-minutes` 45 on build & unit tests (green runs 6–20 min over the
  last 30) and on the hermetic UI tests (8–14 min, one at 27); 10 on SwiftLint. The earlier
  suggestion of 30 for UI was too close to that 27-minute green run.
- **Manual check of Open in (#291)** on the seeded simulator: Share → MangaCarta imports; the
  app-wide banner shows on Home; ComicInfo title, `FrontCover`, Writer, Genre, Summary and the
  "Vol. 2 · Ch. 5" label all land; nothing is left in `Documents/Inbox` or `tmp/` (the system's
  `tmp/…-Inbox` directory remains, empty); ZIP and PDF offer MangaCarta without it being their
  default. **One failure:** Files never offered MangaCarta for a `.cbz`. Fixed in #294.
- **#294** MangaCarta is the default `.cbz` opener: `LSSupportsOpeningDocumentsInPlace` → `true`,
  `.cbz` at `Owner` rank (ZIP/PDF stay `Alternate`). Spec decision 14 amends 12 and records the
  measurement. New tests: an Info.plist guard, and "a handed-over file outside the container is
  imported and kept" (a mutant dropping the container check fails it). Verified on the simulator
  after the change: Open With shows "MangaCarta — Default", a tap imports, and the original stays in
  Files.
- **Filed #295 and #296** (see Next).

**Working tree:** `main` at `7668df5` plus this handoff; no other worktrees or open PRs.
`stash@{0}` is still the Xcode `project.pbxproj` reformat churn from before #291. It is noise;
`git stash drop` is fine, and `git stash pop` would conflict.

## Next

1. **Fix #295 before slice 6: covers of imported books break when the container moves.**
   `LocalImportViewModel.importOne` stores `local.coverURL(itemId:)`, an absolute `file://` URL, in
   `library.items`. Every reinstall, and on a device every restore from backup, moves the container,
   and the cover goes to the placeholder. Both local books on the seeded simulator show this now.
   Doing this first keeps slice 6 from building on the stale-URL model; the issue has fix directions
   and a test approach.
2. **Local-import slice 6: Series grouping** (spec §4 and §8 slice 6, owner decision 7). Files whose
   ComicInfo `Series` matches (case- and whitespace-normalised) an existing local Work join it, in
   the same batch or later, chapters ordered by `Volume`, then `Number`, then natural filename sort;
   files without `Series` stay one Work each. This changes the `itemId`-per-file model (a Work would
   hold chapters from several files, and delete/re-import must still restore history), so it needs a
   short design pass before dispatch. Bring the design question to the owner in prose.
3. **#294's unchecked cases.** In place hands over the reader's original file, not a copy:
   - an iCloud `.cbz` that has not been downloaded yet (may need a coordinated read);
   - a real device, ideally with another comic app that also claims `.cbz` at `Owner`.
4. **#296: unit tests leave their `UserDefaults(suiteName:)` plists behind.** 15,467 files (61 MB) in
   the seeded simulator's `Library/Preferences`, in the same container as the fixture. Remove each
   suite when its test ends. It is **not** a leak into the real `library.items`; that was checked
   and ruled out.
5. **The engine change, only after an App Store build with Host API 1.3 ships.** It is made in
   `proxy-link/mangacarta-sources`. Push it through the SSH alias only, and never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`.
   - If it ships too early, current builds see no version intersection and refuse the update.
   - Existing readers will see the update sheet (Amendment 10) the first time they update.
6. **A real report reaching an endpoint.** Only the sheet is covered (#284). Delivery cannot be
   tested locally (`HostURLPolicy` refuses non-public addresses, loopback included). Check it with
   the real engine against MangaDex once item 5 ships.
7. **Bare 429s (optional):** a 429 with no retry header does not pause. Amendment 8 chose that on
   purpose. Revisit only with evidence of a Source that sends bare 429s.

## Other outstanding work

1. **Per-title reading direction (#290).** Needs a design (keyed by Work or Listing, where it is set,
   precedence over the global setting). ComicInfo `Manga=YesAndRightToLeft` is the natural initial
   value for local imports once it exists.
2. **App Store prep** (`docs/app-store/submission-copy.md`):
   - still needs the owner's sample and screenshot art, a sample URL/attachment, and contact
     placeholders; recheck every claim against the build that ships, §5 included;
   - the asset catalog still ships `SourceLogo-mangadex` and `SourceLogo-weebcentral`.
     `SourceLogoView` looks logos up as `SourceLogo-<sourceID>`, so they now match only the legacy
     built-in ids, not installed Sources' qualified ids. Decide whether third-party site logos belong
     in a no-content build before submitting;
   - the copy may now mention ComicInfo metadata, Open in, and opening `.cbz` from Files (#291,
     #294). That is the owner's call.
3. **Flaky tests:** `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes
   red again, suspect the test's own launch timeout. The loopback test now retries and logs; if it
   recurs, search the CI log for `[loopback-flake]` (#289).
4. **Deferred minor:** `SourceRegistry.setInstalledSources` restores a stored chosen Source by
   existence alone. `active` still gates it, so it is contained. (`@Sendable` on
   `AdultContentSetting.current` is **not** redundant: Swift 5 mode without
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

- **New today — merging.** The owner merged PRs themselves until this session; they then asked for
  #292–#294 to be merged. Treat that as a per-request permission, not a standing one. The merges used
  `gh pr merge <n> --squash` once all four checks passed, or `--squash --auto` to wait for CI.
- **New today — how Files decides who opens a document (iOS 26.5).** "Open With" lists only apps with
  `LSSupportsOpeningDocumentsInPlace = true`; a tap opens the app only at `Owner` rank. Launch
  Services lists every claimant regardless, so a probe of Launch Services alone does not predict
  Files. Spec decision 14 has the full table.
- **New today — a probe app for Launch Services questions.** A 60-line UIKit app built with
  `xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator`, a hand-written
  `Info.plist`, `codesign -s -`, then `simctl install` and `simctl launch --console-pty` gets answers
  in seconds without touching MangaCarta. Vary one Info.plist key per install and check Files by
  hand. The probe lived in session scratch; it is not in the repo.
- **New today — putting files into the simulator's Files app.** Copy them into the
  `group.com.apple.FileProvider.LocalStorage` app group's `File Provider Storage` directory (find it
  via each AppGroup's `.com.apple.mobile_container_manager.metadata.plist`); they appear under
  On My iPhone. The seeded simulator now holds four test files there.
- **New today — Device Hub click hazard.** Dismissing a Files context menu by clicking where a menu
  item sits runs that item. One click ran "New Folder with Item". Dismiss by clicking well outside the
  menu.
- **New today — a single Swift Testing free function runs with**
  `-only-testing:'MangaCartaTests/<functionName>()'`.
- **Orca and Codex:** Orca 1.4.216 does not recognise Codex 0.158 as ready; `worker-start` times out
  at `agent_readiness` unless the temporary wrapper `~/.local/share/orca-codex-compat/codex` exists
  (`--agent codex` uses it automatically). Three failures on one Task fail it permanently; stop after two.
- **Reusing an idle Codex terminal fails.** `worker-start --task <t> --terminal <old>` for a follow-up
  fails at `agent_readiness` (the wrapper only fixes a *fresh* start). Release the settled worker and
  start a fresh one in the same worktree:
  `worker-start --task <t> --retry-of <failed-dispatch> --worktree "id:<repo-id>::<abs path>" --agent codex …`.
  `--terminal` also needs that `--worktree id:` selector, or it fails with `terminal_worktree_mismatch`.
- **Messages do not wake an idle Codex worker.** It shows "You have N orchestration messages" and
  waits. Prompt it with
  `orca terminal send --terminal <handle> --text "<instruction>" --enter --wait-submit 20 --json`.
  Follow-up work can go to a still-open Dispatch as a message instead of a new Task.
- **Check the `worker_done` payload.** A worker truncated its task id; Orca rejected the report
  (`_orcaLifecycleRejection`) and the Dispatch stayed open. The rejection arrives as an ordinary
  message, so read the payload, not just the subject.
- **Orca from outside an Orca terminal:** `orca terminal create --worktree path:<wt>` and pass that
  handle as `--from` to `run-create` / `worker-start` / `task-create` / `send`. A consuming `check`
  takes `--terminal <handle>`. `worker-release` takes neither. Never pipe `check --wait` into `head`;
  its output is heartbeat lines followed by one JSON object — drop `"_keepalive"` lines, then parse.
- **Worker claims need checking, and so does "succeeded".** A Luna pass once reported `succeeded`
  with most acceptance tests missing and four real bugs. Review the diff against the acceptance list,
  run `swiftlint lint` yourself, and re-run at least one mutation.
- **Gate branch cleanup on MERGED** (test `state == MERGED`; #278 was closed by accident).
  Orca-made worktrees are removed with `orca worktree rm --worktree path:<wt>`.
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
  that drops one connection is invisible to the client; use this when writing network tests.
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, iOS 26.5:
  MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`). Read `settings.showAdultSources`
  before relying on it (it read `false` on 2026-09-28). **Changed today:** Library holds two local
  test books, "Open In Check" and "In Place Check", both with broken covers (#295); the Files app
  holds `open-in-check.cbz`, `in-place-check.cbz`, `plain-archive.zip` and `plain-document.pdf`.
  Backups: `~/Manga-Reader-sim-backup-2026-09-29-pre-openin/` (before today's check) and
  `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`.
- **The app's data container moves on every reinstall, and every test run reinstalls.** It moved
  four times today. Look it up with
  `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` right before use while
  booted, then edit plists with PlistBuddy while shut down. Never use `simctl spawn … defaults write`.
  When reading the app's settings, open `Library/Preferences/Elias-Magdaleno.Manga-Reader.plist`
  only. That folder also holds thousands of test-suite plists (#296), and scanning it whole is what
  produced today's false "tests pollute the real library" reading.
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above, and keep parallel testing on.
- **A new worktree needs `Secrets.xcconfig` (repo root) copied to its root.** `/private/tmp` can be
  wiped between sessions, so push work before ending one.
- **Keep build products out of the repo.** `build/` is not ignored; use a `-derivedDataPath` under
  session scratch.
- **The simulator GUI is Device Hub.** Live UI tests run by name on clones; see the header of
  `MangaCartaUITests.swift`.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
