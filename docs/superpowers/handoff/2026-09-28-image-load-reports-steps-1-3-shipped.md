# Handoff — image-load reports: steps 1–3 shipped, step 4 built and pushed, steps 5–6 remain

Date: 2026-09-28 (night). This is the one live handoff. The prior handoff
(`2026-09-28-rate-limit-pause-shipped.md`) was moved to `archive/` before this one was written.
Recheck GitHub and the working trees before acting.

## Completed this session

All merged, all four CI checks green on each:

- **#268:** retires the expired ADR-0018 Wind Breaker live test.
- **#271:** the host rate-limit pause. A 429 pauses a Source's budgets for that origin until
  `Retry-After` / `X-RateLimit-Retry-After`, capped at 5 minutes.
- **#272:** **ADR-0003 Amendment 8** records that pause and the #242 throttle.
- **#273:** **ADR-0003 Amendment 9**, the owner's rulings on image-load reports:
  - an explicit origin list;
  - a fixed host payload;
  - no reader switch.
- **#274:** the design, `docs/superpowers/specs/2026-09-28-image-load-reports-design.md`.
- **#275 (step 1):** declarations may use `network.imageLoadReports {endpoint, origins}`, and
  Host API 1.3 is supported. Declarations whose range allows 1.3 now select it; only feature
  gates and logging read the selected version.
- **#276 (step 2):** `ImageLoadReportTarget` and the protocol requirement
  `MangaSource.imageLoadReportTarget`, which `ExtensionSource` builds from its declaration.
- **#277 (step 3):** `ImageCache` times each network attempt of a covered URL, keeps the
  `X-Cache` HIT flag, and hands reports to an injected `ImageLoadReporting`. The default,
  `NoImageLoadReports`, sends nothing.

**Nothing is sent to MangaDex yet.** No caller passes a report target until step 5.

## Next

1. **Step 4: built, tested, pushed; no PR yet.** Branch `feat/image-load-report-reporter` at
   `2419053`, also checked out in the worktree `/private/tmp/mangacarta-report-cache` as local
   branch `feat/image-load-report-cache`.
   - **What it adds:**
     - `ImageLoadReporter`, a fire-and-forget sender over `HostHTTPClient`. It uses a fresh
       cookie jar per report, the shared rate-limiter registry, and a 64 in-flight cap per Source.
     - **The composition owns the image cache** (owner's ruling, option 1). `AppComposition`
       builds `imageLoadReporter` and one `imageCache`, and the app root injects it as
       `\.imageCache`. `CachedAsyncImage` reads the environment. `ImageCache.shared` remains
       only as the key's default for previews.
     - The design doc records that ruling.
   - **Its commit sits on the pre-squash step-3 commit.** Replay only it:
     `git rebase --onto origin/main 84eaddc` in that worktree. Rerun the full unit suite, then
     open the PR.
   - It passed locally before the rebase: 1,027 XCTest (0 failures, 5 skipped) and 259 Swift
     Testing tests.
2. **Step 5: wire the reader.** This is the step that starts sending reports.
   - `ReaderViewModel` reads `source.imageLoadReportTarget` once and passes it to prefetch and
     to the page views. `CachedAsyncImage` gains an optional `reportTarget:`, and the two
     `ReaderView` call sites (around `:722` and `:765`) pass it.
   - **The prefetch closure** in `ReaderViewModel.init` still defaults to
     `ImageCache.shared.prefetch`. It must use the environment's `imageCache`, whose reporter
     `.shared` lacks, or prefetched pages are never reported. The view builds the view model,
     so pass the cache from there.
   - Tests: the view model passes the Source's target to prefetch, and a Source with no target
     passes `nil` (design §7).
3. **Step 6: privacy copy.** `docs/app-store/submission-copy.md` and any in-app privacy text
   must say that an installed Source may have the app send image-delivery statistics to that
   Source's operator (Amendment 9).
4. **Then the engine**, in `proxy-link/mangacarta-sources`. Push via the SSH alias only, and
   never commit as Elias.
   - Add `https://api.mangadex.network` to `httpOrigins`.
   - Add
     `"imageLoadReports": {"endpoint": "https://api.mangadex.network/report", "origins": ["https://*.mangadex.network"]}`.
   - Raise `hostAPI.minimum` to `1.3`.
   - **Only after an app build with Host API 1.3 ships.** Otherwise current builds see no
     version intersection and refuse the update.
5. **Rate-limit pause leftovers (small, optional):**
   - The rate-limited error copy could say how long to wait. `ExtensionSource.invoke` still
     drops `retryAfterSeconds`, so this means carrying it through.
   - A 429 with no retry header does not pause. Amendment 8 chose that on purpose. Revisit it
     only with evidence of a Source that sends bare 429s.
6. **Tests that read the real adult setting.** Any test that builds an `ExtensionSource` or
   `SourceRegistry` without passing `showAdultContent:` reads `UserDefaults.standard`. The full
   target is green with the switch off, so no known failure remains. The cleaner fix is a pinned
   test default, possibly alongside Other 3.

## Other outstanding work

1. **Flaky tests:**
   - `MALAuthenticatedClientTests` "Concurrent 401s share one refresh" depends on order.
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
     suspect the test's own launch timeout.
2. **Deferred minors:**
   - `SourceRegistry.setInstalledSources` restores a stored chosen Source by existence alone.
     `active` still gates it, so it is contained.
   - `@Sendable` on `AdultContentSetting.current` is redundant.
   - Search runs a duplicate search when the switch hides the selected Source; the second request
     cancels the first.
3. **`MangaDexSource` / `MangaDexAPI`** still compile for AniList, MAL and the resolver, but
   nothing registers them. Narrowing them is a separate refactor, and injecting `UserDefaults`
   into `SourceRegistry` fits the same pass.
4. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's sample and
   screenshot art, a sample URL/attachment, and contact placeholders. Recheck every claim against
   the build that ships (including step 6's privacy line).
5. **Local import:** ComicInfo/open-in and Series grouping remain.
6. **Human gates:**
   - a VoiceOver device pass (#90);
   - the MAL live-write check (`TEST_RUNNER_MAL_LIVE_WRITE=1`);
   - the name/trademark check (#150);
   - the app icon brief (`docs/design/app-icon-brief.md`).

## Operating notes

- **A merge-when-green script must fail closed.** This session's background merge scripts
  piped `gh pr checks` into `grep -qv '^pass$'`. For #277 the first `gh` call died with
  "connection reset by peer", the empty output read as "nothing failing", and the script merged
  unverified. The checks turned out green, but only by luck. Next time, require exactly the
  expected number of `pass` lines, e.g. 4 today, before merging, and treat a `gh` error as
  "do not merge".
- **Boot the seeded simulator before testing.** A cold boot by `xcodebuild` can fail with
  `SBMainWorkspace ... Busy ("Application failed preflight checks")`, on clones and on the
  seeded device alike, and the code is not the cause. Fix it with
  `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 && xcrun simctl bootstatus <udid>`.
  Clones live in `~/Library/Developer/XCTestDevices`.
- **A test that awaits a condition needs a deadline.** Step 4's backlog test first waited
  forever when the stub never sent, and it hung the whole run. Bound such waits, as
  `ReportTransport.waitForRequests` now does with 5 seconds, so a missing behaviour fails
  instead. macOS has no `timeout` command; run long `xcodebuild` jobs in the background instead.
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, is at its
  post-smoke state: MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`), and both
  `declaredAgeOver18` and `showAdultSources` are `true`. Backups are in
  `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`, including the device-level preferences file
  that was moved aside because it shadowed the app's settings. This session ran only the
  rate-limiter suite on the device itself (it touches no settings); everything else ran on clones.
- **The app's data container directory is renamed on reinstall.** Look it up with
  `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` while the device is
  booted, then edit the plist with PlistBuddy while it is shut down. Never use
  `simctl spawn … defaults write`: it writes a device-level file the app does not own.
- **Running one unit test with `-parallel-testing-enabled NO`** runs it on the seeded device, not
  a clone. Since #266 the registry tests restore `source.activeID`, but check it afterwards anyway.
- **The simulator GUI is Device Hub** (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`).
  When driving it with computer-use:
  - press and hold to flip toggles;
  - send letters as separate key presses;
  - Cmd+Left/Right rotates the device;
  - drag to scroll.
- **Live UI tests** run by name on clones. They are listed in `MangaCartaUITests.swift`; its header
  explains why they are not a CI gate.
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above and keep parallel
  testing on.
- **A new worktree needs `Secrets.xcconfig` copied in.** `/private/tmp` can be wiped between
  sessions, so push work before ending one. Step 4 is pushed.
- **The auto-mode classifier** returned "no verdict" on every Bash call twice this session, for a
  few minutes each time, then recovered. It is transient; stop and ask instead of burning retries.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
