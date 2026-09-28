# Handoff — mixed-Source title filter is PR #265; test-leak fix is PR #266

Date: 2026-09-28 (late afternoon). This is the one live handoff. The prior handoff
(`2026-09-28-mixed-source-title-filter.md`) was moved to `archive/` before this one was written.
Recheck GitHub and the working trees before acting.

## Completed

- **The title filter branch is finished and open as #265** (`feat/mixed-source-title-filter`). It
  was rebased onto main. `/private/tmp` had been wiped, which took the old worktree and the untracked
  SDD ledger with it; the branch itself survived.
  - Task 6 verified: the full `MangaCartaTests` target passed (1,258, 0 failures), with the adult
    switch **on** and again with it **off**. `RepositorySettingsUITests` passed 4/4.
  - Whole-branch review done in-session. The one finding, a doc comment left on the wrong
    declaration in `SourceRegistry`, is fixed.
  - Simulator check passed, per the PR comment. With the switch off, Home shows MangaDex rails and
    a search for "Berserk" drops Berserk (1989), which is rated `erotica`. With the switch on, Search
    refetches without retyping and the title comes back.
  - **CI caught a real bug that the local run missed.** `enforceAdultGating` guarded on
    `active?.isNSFW`. After Task 3, `active` already skips a hidden Source, so the gate never fired
    and `activeSourceID` kept naming the hidden Source (`SearchView` reads it directly). Fixed in
    `daf1741` by checking the stored choice. A mutation check reproduces CI's exact failure. It
    passed locally only because the test read the seeded device's real setting, which is on.
  - **ADR-0022 Amendment 7** is committed on the branch. It records the three rulings the previous
    handoff said to promote: notification redaction, the fallback preference, and a page the filter
    empties ending the feed.
- **#266 opened, CI green:** `MangaCartaTests` saves and restores `source.activeID` in
  `setUp`/`tearDown`, and `activeSourceIndependence` does the same. Several tests had been writing a
  mock id into the real key. This session confirmed the leak on the live fixture: one non-parallel
  run left the seeded app's `source.activeID` set to `"adult"`, which was restored by hand.

## Next

1. **Owner: merge #265, then #266.** Both are green on every CI job. Use `gh pr merge <n> --squash` without
   `--delete-branch`. They touch different lines of `MangaCartaTests.swift`; if the second one
   reports a conflict, run `gh pr update-branch`.
2. **Cleanup the agent could not do (classifier-blocked again):** delete the merged branches
   `fix/no-preference-means-install-order` (#260), `docs/handoff-2026-09-28` (#264) and
   `docs/adr-0022-mixed-title-filter` (#262), locally and on origin. After #265 and #266 merge, also
   remove the worktrees `/private/tmp/mangacarta-mixed-titles` and `/private/tmp/mangacarta-test-leak`
   and their branches.
3. **The remaining live UI tests.** Only 3 of the 16 that browse were run after #258. Run the rest by
   name, sort failures into "the catalog moved" and "real regression", and retire the ones that only
   proved the compiled Source.
4. **Tests that read the real adult setting.** Two were caught, but any test that builds an
   `ExtensionSource` or `SourceRegistry` without passing `showAdultContent:` reads
   `UserDefaults.standard`. Running the full target with the switch off is now green, so no known
   failure remains. The cleaner fix is a test-target default that pins the switch; consider it
   alongside Other 5.

## Other outstanding work

1. **Rate-limit hint gap:** `ExtensionSource.invoke` drops `retryAfterSeconds` when it maps
   `ExtensionInvocationError` to `SourceError.invocation`. The MangaDex research also records the
   unimplemented at-home image-fetch report path. Decide both before claiming complete AUP coverage.
2. **Flaky tests:**
   - `MALAuthenticatedClientTests` "Concurrent 401s share one refresh" depends on order.
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it fails again on CI,
     the next suspect is the test's own launch timeout, not the boot.
3. **Deferred minors from the SDD run:**
   - `SourceRegistry.setInstalledSources` restores a stored chosen Source by existence alone, not
     `isBrowsableNow`. `active` still gates it, so it is contained.
   - `@Sendable` on `AdultContentSetting.current` is redundant.
   - Search: when the switch hides the selected Source, `selectSource` and then `retry()` both run a
     search. The second cancels the first, so the only cost is one wasted request.
4. **README is stale:** its Features line still says "MangaDex plus a Cloudflare-protected,
   HTML-scraped site", as if both were built in. Since #255 neither ships.
5. **`MangaDexSource` / `MangaDexAPI`** still compile because AniList, MAL and the resolver use
   them, but nothing registers them. Deleting or narrowing them is a separate refactor. The central
   fix for Next 4, injecting `UserDefaults` into `SourceRegistry`, belongs in the same kind of pass.
6. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's original or
   public-domain sample and screenshot art, a sample URL/attachment, and contact placeholders. #265
   rewords the adult-content review note. Recheck every claim against the build that ships.
7. **Local import:** ComicInfo/open-in and Series grouping remain, per the local-import design.
8. **Human gates:** a manual VoiceOver device pass (#90); the MAL live-write check
   (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); the MangaCarta name
   reservation/trademark check (#150); the app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- **The previous handoffs' settings-restore command was wrong. Do not use it.**
  `xcrun simctl spawn <id> defaults write Elias-Magdaleno.Manga-Reader <key> -bool true` writes a
  device-level file (`data/Library/Preferences/Elias-Magdaleno.Manga-Reader.plist`), not the app's
  own preferences. That stray file then supplied `declaredAgeOver18 = true` after the test launch
  removed the key from the app, so the age sheet never appeared and two `RepositorySettingsUITests`
  failed locally on main and on the branch alike. The file was moved aside (a copy is in
  `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`), and the suite went 4/4.
  - Parallel runs use clones, so the hermetic suite **does not touch the seeded app's settings** and
    needs no restore.
  - To change a seeded setting by hand: boot the device, run
    `xcrun simctl get_app_container ADDAB2F8-38C7-4D44-97EA-4E98281CF691 Elias-Magdaleno.Manga-Reader data`,
    shut the device down, then run `PlistBuddy -c "Set :<key> true"` on
    `<container>/Library/Preferences/Elias-Magdaleno.Manga-Reader.plist`.
  - **The container directory is renamed on reinstall.** It changed twice this session, and the
    data moved with it each time. Look the path up right before every edit.
- **Seeded state at hand-off:** the MangaCarta Sources repository with MangaDex and WeebCentral
  active; `source.activeID` = `5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`;
  `declaredAgeOver18` and `showAdultSources` both `true`; `works.json` unchanged since 09-27.
- **Running one unit test with `-parallel-testing-enabled NO` runs it on the seeded device itself.**
  Until #266 merges, some registry tests there overwrite `source.activeID`. Check it afterwards.
- **The simulator GUI is Device Hub** (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`),
  not Simulator.app. When driving it with computer-use:
  - a quick click may not flip a toggle, so use mouse down, a 0.2s wait, then mouse up;
  - send letters as separate key presses;
  - Cmd+Left/Right rotates the device;
  - drag to scroll.
- **Use Orca for Luna, not raw `codex exec`.** From a session that is not in an Orca terminal,
  create one with `orca terminal create` in the worktree and pass its handle as `--from`. Luna
  force-adds `.superpowers/` report files; check `git ls-files .superpowers` before pushing.
- Name-based `xcodebuild` destination selection fails. Use
  `-destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691'`, the seeded
  iPhone 17 Pro, and keep parallel testing on.
- A new worktree needs `Secrets.xcconfig` copied from the main checkout. Under `/private/tmp`,
  `xcp` needs the `/tmp/...` spelling of the path. `/private/tmp` can be wiped (it was, between
  sessions), so push work before ending a session.
- The classifier blocks `gh pr merge`, force pushes and branch deletion for the agent. The owner
  merges without `--delete-branch`. `gh pr update-branch <n>` is allowed.
- `SettingsView.swift` has three pre-existing `swiftlint --strict` violations. CI lints without
  `--strict` and passes.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
