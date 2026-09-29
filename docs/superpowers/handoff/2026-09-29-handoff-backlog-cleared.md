# Handoff: the handoff backlog is cleared; what remains waits on a release, a design, or the owner

Date: 2026-09-29. This is the one live handoff. The prior one
(`2026-09-28-image-load-reports-app-side-shipped.md`) is in `archive/`; every open item in it is
carried here. Recheck GitHub and the working tree before acting.

## Completed this session

All merged with four green CI checks:

- **#282** the previous handoff.
- **#283** `RepositorySettingsUITests` keyboard wait: 3s → `waitForNonExistence(timeout: 10)`. The CI
  log showed ~2s per accessibility query, so 3s saw the keyboard mid-dismissal.
- **#284** hermetic UI test for the image-load reports sheet (`-uitest-repository-reports` adds a
  general-content fixture Source that declares reports). Covers title, copy, Cancel installs
  nothing, Install installs.
- **#285** the rate-limited message names the wait: `ExtensionSourceError.rateLimited(retryAfterSeconds:)`,
  rounded up, seconds / minutes / "later" past an hour; host pause unchanged.
- **#286** `MALAuthenticatedClientTests` concurrent-401 flake: the test double answered in arrival
  order. Now token-aware, with the refresh gated until both 401s land (5s deadline). Production
  code was correct.
- **#287** one search (not two) when the adult switch hides the searched Source
  (`SearchViewModel.adultContentChanged`); the age question says "update" on an update.
- **Checked, no change:** no test depends on the real adult switch (full target green with it
  forced on); owner declined the guard.

**Working tree:** `main` at `31db88e` plus this handoff. The shared checkout's `project.pbxproj`
has unrelated Xcode churn; leave it out of commits. No other worktrees.

## Next

1. **CI job timeouts (small, ready).** `.github/workflows/*.yml` sets no `timeout-minutes`, so a
   hung simulator holds a runner for GitHub's 6-hour default. #286's UI job took ~25 min (normal
   9–11) and passed. Suggested: 30 min on the UI job, a matching cap on build & unit tests
   (normally 7–13 min).
2. **The engine change, only after an App Store build with Host API 1.3 ships.** It is made in
   `proxy-link/mangacarta-sources`. Push it through the SSH alias only, and never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`.
   - If it ships too early, current builds see no version intersection and refuse the update.
   - Existing readers will see the update sheet (Amendment 10) the first time they update.
3. **A real report reaching an endpoint.** Only the sheet is covered (#284). Delivery cannot be
   tested locally: `HostURLPolicy` refuses non-public addresses, loopback included. Check it with
   the real engine against MangaDex once item 2 ships.
4. **Bare 429s (optional):** a 429 with no retry header does not pause. Amendment 8 chose that on
   purpose. Revisit only with evidence of a Source that sends bare 429s.

## Other outstanding work

1. **Flaky tests:**
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
     suspect the test's own launch timeout.
   - Swift Testing `realURLSessionLoopbackPeerNeverDecodes` (#247) failed once locally in a full
     parallel run with `-1005`, then passed alone. Looks like loopback contention; act only if it
     recurs.
2. **Deferred minor:** `SourceRegistry.setInstalledSources` restores a stored chosen Source by
   existence alone. `active` still gates it, so it is contained. (`@Sendable` on
   `AdultContentSetting.current` is **not** redundant: Swift 5 mode without
   `InferSendableFromCaptures`. Keep it.)
3. **`MangaDexSource` / `MangaDexAPI`** still compile for AniList, MAL and the resolver, but nothing
   registers them. Narrowing them is a separate refactor; injecting `UserDefaults` into
   `SourceRegistry` fits the same pass.
4. **Local import:** ComicInfo/open-in and Series grouping remain. Needs a design pass first.
5. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's sample and
   screenshot art, a sample URL/attachment, and contact placeholders. Recheck every claim against
   the build that ships, §5 included.
6. **Human gates:**
   - a VoiceOver device pass (#90);
   - the MAL live-write check (`TEST_RUNNER_MAL_LIVE_WRITE=1`);
   - the name/trademark check (#150);
   - the app icon brief (`docs/design/app-icon-brief.md`).
   - Design nit, owner's call: the reports/age sheet styles Install and Cancel identically.

## Operating notes

- **Orca and Codex:** Orca 1.4.216 does not recognise Codex 0.158 as ready. `worker-start` times
  out at `agent_readiness` and never sends the task. The owner installed a temporary wrapper at
  `~/.local/share/orca-codex-compat/codex`, and `--agent codex` uses it automatically. If the
  timeouts return, check that the wrapper exists. Three failures on one Task make Orca fail it
  permanently, so stop after two.
- **Orca from outside an Orca terminal:** run `orca terminal create --worktree path:<wt>` and pass
  that handle as `--from` to `run-create` / `worker-start`. A consuming `check` takes
  `--terminal <handle> --run <id>`, not `--from`. Never pipe `check --wait` into `head`: its
  heartbeat lines fill the limit and kill the wait.
- **Worker claims need checking.** A worker reported SwiftLint clean when a 237-character line
  failed CI. Run `swiftlint lint` on the changed files yourself.
- **Gate branch cleanup on MERGED.** `gh pr view -q .state && git push --delete …` deletes the
  branch whatever the state is; that closed #278 by accident. Test that the state equals `MERGED`.
- **A merge-when-green script must fail closed.** Require exactly the expected number of `pass`
  lines (4 today) and treat a `gh` error as "do not merge".
- **Boot the seeded simulator before testing.** A cold boot by `xcodebuild` can fail with
  `Busy ("Application failed preflight checks")` or "failed to launch", and the code is not the
  cause. Run `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 && xcrun simctl bootstatus <udid>`.
- **A test that awaits a condition needs a deadline.** A wait with no deadline hung a whole run
  once.
- **Swift Testing ignores `-test-iterations`.** To reproduce a scheduling flake, force the bad
  order (e.g. delay one task) rather than looping the test; that is how #286 was proven.
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, is at its
  post-smoke state: MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`).
  `settings.showAdultSources` read `false` on 2026-09-28 (earlier notes said `true`); read it
  before relying on it. Backups are in
  `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`.
- **The app's data container directory is renamed on reinstall.** Look it up with
  `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` while the device is
  booted, then edit the plist with PlistBuddy while it is shut down. Never use
  `simctl spawn … defaults write`.
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above, and keep parallel
  testing on.
- **A new worktree needs `Secrets.xcconfig` (repo root) copied to its root.** `/private/tmp` can be wiped between
  sessions, so push work before ending one.
- **The simulator GUI is Device Hub.** Live UI tests run by name on clones; see the header of
  `MangaCartaUITests.swift`.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
