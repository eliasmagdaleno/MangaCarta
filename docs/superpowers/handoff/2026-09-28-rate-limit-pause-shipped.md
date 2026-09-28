# Handoff — host rate-limit pause shipped; at-home reporting ADR is next

Date: 2026-09-28 (late evening). This is the one live handoff. The prior handoff
(`2026-09-28-rate-limit-pause-next.md`) was moved to `archive/` before this one was written.
Recheck GitHub and the working trees before acting.

## Completed this session

- **#268 merged:** retires the expired ADR-0018 Wind Breaker live test. Its worktree and branch
  are gone.
- **#271 merged:** the host rate-limit pause. A 429 pauses every budget the Source has for that
  origin until `Retry-After` or MangaDex's `X-RateLimit-Retry-After`, capped at 5 minutes. Waiters
  already asleep re-reserve spaced slots after the pause. The decision and its rules are
  **ADR-0003 Amendment 8**, which also records the #242 throttle that never had an ADR. The code
  is in `RateLimiter.pause(until:)`, `HostRateLimiterRegistry.pause(sourceID:origin:retryAfter:)`,
  `HostRetryAfter`, and `HostHTTPClient.pauseIfRateLimited`. Tests are in
  `@Suite("Host rate limiting")`.
- The **full unit suite passed** locally (1,015 XCTest with 5 skipped, 243 Swift Testing, 0
  failures), and all four CI checks passed on #271.

## Next

1. **At-home image-fetch reporting: the owner chose option (a), a generic host hook.** MangaDex
   asks clients to report each page-image load (success, bytes, duration, cached) to
   `https://api.mangadex.network/report`. The host loads images itself and must stay site-neutral,
   so the plan is for a Source's declaration to opt in to "report image loads to this URL" and for
   the host to post the reports. **This is a new Host API feature. Write an ADR (or an ADR-0003
   amendment) and a design before any code.** The research is
   `docs/research/2026-09-22-mangadex-engine.md` §Blocker 3. Check MangaDex's current report
   payload spec first. The engines live in `proxy-link/mangacarta-sources`, and the MangaDex
   declaration there would need to opt in.
2. **Rate-limit pause leftovers (small, optional):**
   - The rate-limited error copy could say how long to wait. `ExtensionSource.invoke` still drops
     `retryAfterSeconds`, so this means carrying it through.
   - A 429 with no retry header does not pause. Amendment 8 chose that on purpose ("a guessed
     value is still a guess"). Revisit it only with evidence of a Source that sends bare 429s.
3. **Tests that read the real adult setting.** Any test that builds an `ExtensionSource` or
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
   the build that ships.
5. **Local import:** ComicInfo/open-in and Series grouping remain.
6. **Human gates:**
   - a VoiceOver device pass (#90);
   - the MAL live-write check (`TEST_RUNNER_MAL_LIVE_WRITE=1`);
   - the name/trademark check (#150);
   - the app icon brief (`docs/design/app-icon-brief.md`).

## Operating notes

- **Boot the seeded simulator before testing.** Three runs this session failed with
  `SBMainWorkspace ... Busy ("Application failed preflight checks")` when `xcodebuild`
  cold-booted the device, on clones and on the seeded device alike. The code was not the cause.
  `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 && xcrun simctl bootstatus <udid>` fixed
  it, and parallel runs then worked. Neither `-parallel-testing-worker-count 1` nor deleting the
  clones helped. The clones live in `~/Library/Developer/XCTestDevices`, not in the `testing` set.
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
  sessions, so push work before ending one.
- **The auto-mode classifier** returned "no verdict" on every Bash call for a few minutes this
  session, then recovered. It is transient; stop and ask instead of burning retries.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.
