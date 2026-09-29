# Handoff: image-load reports are complete on the app side; the engine change waits for a release

Date: 2026-09-28 (night). This is the one live handoff. The prior live handoff
(`2026-09-28-rate-limit-pause-shipped.md`) was moved to `archive/` before this one was written. A
later draft, #278, never merged and was closed as superseded; every open item in it is carried
here. Recheck GitHub and the working trees before acting.

## Completed this session

All four CI checks passed on each of these before it merged:

- **#279 (step 4):** `ImageLoadReporter` sends each report fire-and-forget, with no cookies and a
  cap of 64 in flight per Source. `AppComposition` owns one `ImageCache`, which is injected as
  `\.imageCache`.
- **#281 (step 5):** the reader passes `source.imageLoadReportTarget` to prefetch and to both page
  views. Prefetch uses the injected cache rather than `ImageCache.shared`. `ReaderView` takes
  `imageCache:` in its init, as it already takes `source:`. **The app now sends reports for any
  installed Source that declares `network.imageLoadReports`. No published Source does yet.**
- **#280 (step 6 and the owner's rulings, ADR-0003 Amendment 10):**
  - `PrivacyInfo.xcprivacy` declares Performance Data: not linked, not tracking, purpose App
    Functionality.
  - The install acknowledgement sheet is the in-app disclosure. It appears for a Source that
    declares reports, on install and on an update that adds them. Declining persists nothing.
  - `docs/app-store/submission-copy.md` gained the App Review paragraph, a listing bullet and §5
    "Privacy label".
- Earlier the same day: #268, #271–#277 (rate-limit pause, Amendments 8 and 9, design, steps 1–3).

Steps 5 and 6 were implemented by Codex Luna workers through Orca and reviewed here. Both
workers' tests caught a mutation. **CI on main passed after #280 and #281 merged**
(`ec7db61`), so the two work together.

**Working trees are clean.** The only worktree besides the shared checkout is this handoff's,
`/private/tmp/mangacarta-handoff`. Remove it and its branch once this PR merges. The shared
checkout's `project.pbxproj` has an unrelated uncommitted change: Xcode churn, from before this
session.

## Next

1. **The engine change, only after an App Store build with Host API 1.3 ships.** It is made in
   `proxy-link/mangacarta-sources`. Push it through the SSH alias only, and never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`.
   - If it ships too early, current builds see no version intersection and refuse the update.
   - Existing readers will see the update sheet (Amendment 10) the first time they update.
2. **A real report reaching an endpoint.** The sheet itself is now covered by the hermetic
   `RepositorySettingsUITests.testImageLoadReportsSheetGatesInstall` (`-uitest-repository-reports`).
   Delivery is not, and cannot be tested locally: `HostURLPolicy` refuses non-public addresses,
   loopback included, so the endpoint must be public HTTPS. Check it with the real engine against
   MangaDex once the engine change above ships.
3. **Rate-limit pause leftovers (small, optional):**
   - The rate-limited error copy could say how long to wait. `ExtensionSource.invoke` still drops
     `retryAfterSeconds`, so this means carrying it through.
   - A 429 with no retry header does not pause. Amendment 8 chose that on purpose. Revisit it
     only with evidence of a Source that sends bare 429s.
4. **Tests that read the real adult setting.** Any test that builds an `ExtensionSource` or
   `SourceRegistry` without passing `showAdultContent:` reads `UserDefaults.standard`. The full
   target is green with the switch off, so no known failure remains. The cleaner fix is a pinned
   test default, possibly alongside Other 3.

## Other outstanding work

1. **Flaky tests:**
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
     suspect the test's own launch timeout.
   - **New:** Swift Testing `realURLSessionLoopbackPeerNeverDecodes` (#247) failed once locally in
     a full parallel run with `-1005`, then passed five times alone. It looks like loopback
     contention.
2. **Deferred minors:**
   - `SourceRegistry.setInstalledSources` restores a stored chosen Source by existence alone.
     `active` still gates it, so it is contained.
   - `@Sendable` on `AdultContentSetting.current` is redundant.
   - Search runs a duplicate search when the switch hides the selected Source; the second request
     cancels the first.
   - **New:** a reader who turned adult content off, which clears the age confirmation, is asked
     their age again when an update adds reports to an adult Source they already have.
     Acceptable, but it reads oddly ("to install it" on an update).
3. **`MangaDexSource` / `MangaDexAPI`** still compile for AniList, MAL and the resolver, but
   nothing registers them. Narrowing them is a separate refactor, and injecting `UserDefaults`
   into `SourceRegistry` fits the same pass.
4. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's sample and
   screenshot art, a sample URL/attachment, and contact placeholders. Recheck every claim against
   the build that ships, §5 included.
5. **Local import:** ComicInfo/open-in and Series grouping remain.
6. **Human gates:**
   - a VoiceOver device pass (#90);
   - the MAL live-write check (`TEST_RUNNER_MAL_LIVE_WRITE=1`);
   - the name/trademark check (#150);
   - the app icon brief (`docs/design/app-icon-brief.md`).

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
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, is at its
  post-smoke state: MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`), and both
  `declaredAgeOver18` and `showAdultSources` are `true`. Backups are in
  `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`.
- **The app's data container directory is renamed on reinstall.** Look it up with
  `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` while the device is
  booted, then edit the plist with PlistBuddy while it is shut down. Never use
  `simctl spawn … defaults write`.
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above, and keep parallel
  testing on.
- **A new worktree needs `Secrets.xcconfig` copied in.** `/private/tmp` can be wiped between
  sessions, so push work before ending one.
- **The simulator GUI is Device Hub.** Live UI tests run by name on clones; see the header of
  `MangaCartaUITests.swift`.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
