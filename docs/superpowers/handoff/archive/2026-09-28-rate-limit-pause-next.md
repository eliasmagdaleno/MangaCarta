# Handoff — host rate-limit pause designed, not built; at-home reporting chosen as option (a)

Date: 2026-09-28 (evening). This is the one live handoff. The prior handoff
(`2026-09-28-title-filter-pr-open.md`) was moved to `archive/` before this one was written.
Recheck GitHub and the working trees before acting.

## Completed this session

- **#265 merged:** the mixed-Source title filter (ADR-0022 A6), plus ADR-0022 **Amendment 7**,
  which records the three rulings made while building it. CI caught a real bug before merge:
  `enforceAdultGating` never re-sourced away from a hidden Source. It was fixed in the PR.
- **#266 merged:** `MangaCartaTests` and `activeSourceIndependence` restore `source.activeID`.
- **#267 merged:** the previous handoff.
- **#269 merged:** the README no longer calls the app "powered by the MangaDex API". It
  describes installing Sources from repositories, local import, and the adult-content gate, and
  it names no repository (ADR-0003 A6).
- **All 17 live browse UI tests have now run** (3 last session, 14 this one). 15 pass, and
  `testLiveHorimiyaCompletionPushesProgress` skips by design because it writes to the real MAL
  account. `testADR0018WindBreakerAcquiresMalIdThroughSearch` failed on stale state, not a
  regression: Wind Breaker is already in the seeded library, so "Add to Library" never appears.
  **#268 retires it** (open, CI was pending at hand-off). None of the 17 "only proved the compiled
  Source"; all ran through the installed MangaDex.
- **Permissions:** `Bash(gh pr merge:*)` is now in `autoMode.allow` in `~/.claude/settings.json`,
  and the agent merged #265–#267 and #269 itself. Branch deletion goes through when the owner
  approves it in chat.

## Next

1. **Merge #268** once CI is green, then remove the worktree `/private/tmp/mangacarta-retire-wb`
   and delete the branch `test/retire-windbreaker-live-test`, locally and on origin.
2. **Build the host rate-limit pause (owner approved).** No code is written yet. The design:
   - **Why:** the host throttle (#242, `HostRateLimiterRegistry` + `RateLimiter`) spaces
     requests but learns nothing from a 429. `ExtensionSource.invoke` also drops the preserved
     `retryAfterSeconds`. Carrying the seconds up to the view models would only improve the error
     text, and background refresh and matching would keep sending. So pause at the host.
   - **Read the right header.** MangaDex sends **`X-RateLimit-Retry-After` as a Unix timestamp**
     (confirmed on api.mangadex.org/docs/2-limitations), on every response, as the end of the
     current window. `HostHTTPClient.retryAfter(from:)` reads only `Retry-After` (seconds or an
     HTTP date). Parse both, site-neutrally: a value over about 1e9 is an epoch instant, and a
     smaller one is seconds. **Act on it only for a 429.**
   - **Pause:** add `RateLimiter.pause(until:)`, which sets `nextSlot = max(nextSlot, until)` and
     drops released slots earlier than `until`. Waiters already sleeping must re-check after they
     wake: if a pause now extends past their slot, reserve a new slot after it. That keeps them
     spaced instead of releasing a burst when the pause ends. Add
     `HostRateLimiterRegistry.pause(sourceID:origin:until:)`, which pauses the origin limiter and
     every path limiter for that Source and origin. Call it from `HostHTTPClient.request` on a 429.
   - **Cap** the pause at 5 minutes, so a bad header cannot lock a Source out.
   - Optional: make the rate-limited error copy say how long to wait.
   - **Tests** go in the `@Suite("Host rate limiting")` block of
     `MangaCartaTests/HostCapabilityTests.swift` (around line 1218). It already has
     `RecordingRateLimiterSleeper` and a fake clock. Existing coverage at around line 517:
     "HTTP does not retry statuses and exposes parsed Retry-After".
3. **At-home image-fetch reporting: the owner chose option (a), a generic host hook.** MangaDex
   asks clients to report each page-image load (success, bytes, duration, cached) to
   `https://api.mangadex.network/report`. The host loads images itself and must stay site-neutral,
   so the plan is for a Source's declaration to opt in to "report image loads to this URL" and for
   the host to post the reports. **This is a new Host API feature: write an ADR (or an ADR-0003
   amendment) and a design before any code.** The research is
   `docs/research/2026-09-22-mangadex-engine.md` §Blocker 3. Check MangaDex's current report
   payload spec first, and remember that the engines live in `proxy-link/mangacarta-sources`,
   where the MangaDex declaration would need to opt in.
4. **Tests that read the real adult setting.** Any test that builds an `ExtensionSource` or
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

- **Seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, is at its
  post-smoke state: MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`), and both
  `declaredAgeOver18` and `showAdultSources` are `true`. Backups are in
  `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`, including the device-level preferences file
  that was moved aside because it shadowed the app's settings.
- **The app's data container directory is renamed on reinstall.** It happened twice this session.
  Look it up with `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` while
  the device is booted, then edit the plist with PlistBuddy while it is shut down. Never use
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
- Name-based `xcodebuild` destinations fail. Use the simulator id above and keep parallel testing
  on. A new worktree needs `Secrets.xcconfig` copied in. `/private/tmp` can be wiped between
  sessions, so push work before ending one.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
