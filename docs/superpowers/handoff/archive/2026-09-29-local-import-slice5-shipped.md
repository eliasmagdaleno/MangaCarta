# Handoff: local-import slice 5 (ComicInfo + Open in) shipped; Series grouping is next

Date: 2026-09-29 (afternoon). This is the one live handoff. The prior live handoff
(`2026-09-28-image-load-reports-app-side-shipped.md`) is in `archive/`. An intermediate draft,
**#288** (`2026-09-29-handoff-backlog-cleared.md`), never merged; every item in it is carried here,
with one correction (see "Swift Testing and `-test-iterations`" below), and #288 should be closed as
superseded once this merges. Recheck GitHub and the working tree before acting.

## Completed today

All merged with four green CI checks.

From the morning (recorded in #288):

- **#282** the previous handoff.
- **#283** `RepositorySettingsUITests` keyboard wait: 3s → `waitForNonExistence(timeout: 10)`. The CI
  log showed ~2s per accessibility query, so 3s saw the keyboard mid-dismissal.
- **#284** hermetic UI test for the image-load reports sheet (`-uitest-repository-reports`).
- **#285** the rate-limited message names the wait (`ExtensionSourceError.rateLimited(retryAfterSeconds:)`).
- **#286** `MALAuthenticatedClientTests` concurrent-401 flake: the test double answered in arrival
  order; now token-aware. Production code was correct.
- **#287** one search (not two) when the adult switch hides the searched Source; the age question
  says "update" on an update.
- **Checked, no change:** no test depends on the real adult switch; the owner declined the guard.

This afternoon:

- **#289** `realURLSessionLoopbackPeerNeverDecodes` flake (-1005, once, 2026-09-28). Not
  reproducible: 200 serial runs, repeated full-target runs, and 5,504 stress fetches at up to
  128-way concurrency under CPU load were all green. Falsified: cross-process port collision, and
  the server closing on a partial read. **Found:** URLSession itself makes three connection
  attempts before it reports -1005, so the failure means three losses in a row. The test's setup
  fetch now retries once, and `LoopbackHTTPServer` logs what it saw — **if it recurs, search the CI
  log for `[loopback-flake]`**; the log says whether the server accepted, read and answered.
- **#291** local-import **slice 5**: ComicInfo.xml (Series → title, Volume/Number → chapter label,
  FrontCover → cover, Summary/Writer/Genre → detail page) and **Open in** (document types; `.cbz` at
  `Default` rank, ZIP/PDF at `Alternate`; `.onOpenURL`; the handed-over copy is deleted only inside
  the app container). Imports now queue instead of dropping, a file shared right after Cancel is
  still imported, and the progress banner is app-wide. Decisions 10–13 are recorded in
  `docs/superpowers/specs/2026-09-22-local-import-design.md`.
- **#290 filed:** per-title reading direction (owner wants it later). ComicInfo's `Manga` element is
  deliberately unused until it lands.

**Working tree:** `main` at `de018be` plus this handoff; no other worktrees. The shared checkout's
Xcode `project.pbxproj` reformat churn is **stashed** as `stash@{0}` ("Xcode pbxproj reformat churn
(pre-#291)"), because it blocked the fast-forward. It is noise; `git stash drop` is fine, and
`git stash pop` would conflict with #291's pbxproj entries.

## Next

1. **Manual check of Open in (#291).** XCUITest cannot drive the Share sheet. On the seeded
   simulator: share a `.cbz` from Files to MangaCarta; confirm the app-wide banner appears, the book
   lands in Library with its ComicInfo title, and nothing is left in the container's `Documents/Inbox`
   or `tmp/`. Also confirm MangaCarta is *offered* for a ZIP/PDF but is not the default opener.
2. **Local-import slice 6: Series grouping** (spec §4 and §8 slice 6, owner decision 7). Files whose
   ComicInfo `Series` matches (case- and whitespace-normalised) an existing local Work join it, in the
   same batch or later, chapters ordered by `Volume`, then `Number`, then natural filename sort; files
   without `Series` stay one Work each. This changes the `itemId`-per-file model (a Work would hold
   chapters from several files, and delete/re-import must still restore history), so it needs a short
   design pass before dispatch.
3. **CI job timeouts (small, ready; from #288).** `.github/workflows/*.yml` sets no `timeout-minutes`,
   so a hung simulator holds a runner for GitHub's 6-hour default. Suggested: 30 min on the UI job,
   a matching cap on build & unit tests (normally 7–13 min).
4. **The engine change, only after an App Store build with Host API 1.3 ships.** Made in
   `proxy-link/mangacarta-sources`; push through the SSH alias only, and never commit as Elias.
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

1. **Per-title reading direction (#290).** Needs a design (keyed by Work or Listing, where it is set,
   precedence over the global setting). ComicInfo `Manga=YesAndRightToLeft` is the natural initial
   value for local imports once it exists.
2. **App Store prep** (`docs/app-store/submission-copy.md`):
   - still needs the owner's sample and screenshot art, a sample URL/attachment, and contact
     placeholders; recheck every claim against the build that ships, §5 included;
   - **new:** the asset catalog still ships `SourceLogo-mangadex` and `SourceLogo-weebcentral`.
     `SourceLogoView` looks logos up as `SourceLogo-<sourceID>`, so they now match only the legacy
     built-in ids, not installed Sources' qualified ids. Decide whether third-party site logos belong
     in a no-content build before submitting;
   - the copy may now mention ComicInfo metadata and Open in (#291) — owner's call.
3. **Flaky tests:** `LocalImportUITests.testImportReadAndDelete` should be fixed by #263; if it goes
   red again, suspect the test's own launch timeout. The loopback test now retries and logs (#289).
4. **Deferred minor:** `SourceRegistry.setInstalledSources` restores a stored chosen Source by
   existence alone; `active` still gates it, so it is contained. (`@Sendable` on
   `AdultContentSetting.current` is **not** redundant: Swift 5 mode without
   `InferSendableFromCaptures`. Keep it.)
5. **`MangaDexSource` / `MangaDexAPI`** still compile for AniList, MAL and the resolver, but nothing
   registers them. Narrowing them is a separate refactor; injecting `UserDefaults` into
   `SourceRegistry` fits the same pass.
6. **Human gates:**
   - a VoiceOver device pass (#90);
   - the MAL live-write check (`TEST_RUNNER_MAL_LIVE_WRITE=1`);
   - the name/trademark check (#150);
   - the app icon brief (`docs/design/app-icon-brief.md`);
   - design nit, owner's call: the reports/age sheet styles Install and Cancel identically.

## Operating notes

- **Orca and Codex:** Orca 1.4.216 does not recognise Codex 0.158 as ready; `worker-start` times out
  at `agent_readiness` unless the temporary wrapper `~/.local/share/orca-codex-compat/codex` exists
  (`--agent codex` uses it automatically). Three failures on one Task fail it permanently; stop after two.
- **New today — reusing an idle Codex terminal fails.** `worker-start --task <t> --terminal <old>`
  for a follow-up fails at `agent_readiness` (the wrapper only fixes a *fresh* start). Release the
  settled worker and start a fresh one in the same worktree:
  `worker-start --task <t> --retry-of <failed-dispatch> --worktree "id:<repo-id>::<abs path>" --agent codex …`.
  `--terminal` also needs that `--worktree id:` selector, or it fails with `terminal_worktree_mismatch`.
- **New today — messages do not wake an idle Codex worker.** It shows "You have N orchestration
  messages" and waits. Prompt it with
  `orca terminal send --terminal <handle> --text "<instruction>" --enter --wait-submit 20 --json`.
  Follow-up work can go to a still-open Dispatch as a message instead of a new Task.
- **New today — check the `worker_done` payload.** A worker truncated its task id; Orca rejected the
  report (`_orcaLifecycleRejection`) and the Dispatch stayed open. The rejection arrives as an
  ordinary message, so read the payload, not just the subject.
- **Orca from outside an Orca terminal:** `orca terminal create --worktree path:<wt>` and pass that
  handle as `--from` to `run-create` / `worker-start` / `task-create` / `send`. A consuming `check`
  takes `--terminal <handle>`. `worker-release` takes neither. Never pipe `check --wait` into `head`;
  its output is heartbeat lines followed by one JSON object — drop `"_keepalive"` lines, then parse.
- **Worker claims need checking — and so does "succeeded".** Today Luna's first pass reported
  `succeeded` with most acceptance tests missing and four real bugs (FrontCover ignored past page 0,
  cleanup rooted at `Documents/`, Cancel leaving the queue, file-wide `swiftlint:disable`). It took
  three rounds. Review the diff against the acceptance list, run `swiftlint lint` yourself, and
  re-run at least one mutation.
- **Gate branch cleanup on MERGED** (test `state == MERGED`; #278 was closed by accident).
  Owner-approved merges here have used `gh pr merge <n> --squash --auto`, which waits for CI.
  Orca-made worktrees are removed with `orca worktree rm --worktree path:<wt>`.
- **A merge-when-green script must fail closed.** Require exactly the expected number of `pass`
  lines (4 today) and treat a `gh` error as "do not merge".
- **Boot the seeded simulator before testing.** A cold boot by `xcodebuild` can fail with
  `Busy ("Application failed preflight checks")` — it happened again today mid-mutation, and the code
  was not the cause. `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 && xcrun simctl bootstatus <udid>`.
- **A test that awaits a condition needs a deadline.** A wait with no deadline hung a whole run once.
- **Swift Testing and `-test-iterations` (corrects #288).** It *does* repeat Swift Testing tests:
  on 2026-09-29, `-only-testing:'MangaCartaTests/ImageCacheNetworkTests/realURLSessionLoopbackPeerNeverDecodes()'
  -test-iterations 200 -run-tests-until-failure` logged "(repetition 2)" onward, 200 runs. The lesson
  from #286 still holds for a different reason: looping does not change scheduling, so to reproduce a
  scheduling flake, force the bad order (e.g. delay one task).
- **URLSession retries a lost connection on its own** (three attempts before -1005). A test server
  that drops one connection is invisible to the client; use this when writing network tests.
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, is at its
  post-smoke state: MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`).
  `settings.showAdultSources` read `false` on 2026-09-28 (earlier notes said `true`); read it before
  relying on it. Backups are in `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`. Today's unit and
  UI runs imported local fixtures only into temporary directories.
- **The app's data container directory is renamed on reinstall.** Look it up with
  `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` while booted, then edit the
  plist with PlistBuddy while shut down. Never use `simctl spawn … defaults write`.
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above, and keep parallel testing on.
- **A new worktree needs `Secrets.xcconfig` (repo root) copied to its root.** `/private/tmp` can be
  wiped between sessions, so push work before ending one.
- **The simulator GUI is Device Hub.** Live UI tests run by name on clones; see the header of
  `MangaCartaUITests.swift`.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
