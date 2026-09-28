# Handoff — live UI tests restored, smoke test passed, tiebreak decided

Date: 2026-09-27 (late). This is the one live handoff. The prior handoff
(`2026-09-27-no-built-in-sources-merged.md`) was moved to `archive/` before this one was written.
Recheck GitHub and working trees before acting.

## Completed

- **Mutation checks for #255's new tests: done.** Five deliberate breakages, each caught by the
  assertion that guards it:
  - retirement skipping the removal;
  - retirement dropping its only-if-active guard;
  - the registry ignoring retired ids;
  - the fallback browse Source ignoring adult Sources;
  - a `BundledRepositories/` folder reappearing.
  
  The `works.json`-unchanged check is weak evidence: retirement never touches that file, so no
  mutation could fail it. Data preservation is really guarded by #254's installer tests.
- **Owner smoke test on the seeded simulator: passed.**
  - The published repository installed, and the age sheet appeared for MangaDex (`mixed`).
  - Yotsuba searched and read, with the scanlation-group credit shown.
  - The reconnect prompt moved all 24 legacy `mangadex` rows and 3 bundled-WeebCentral rows in
    `works.json` and `updates.json` to the installed Sources, with none left on the old ids.
  
  This was #254's first end-to-end run. The simulator now has one repository, "MangaCarta
  Sources" (`5E2AC712…`), with MangaDex active.
- **#258 merged:** the live UI tests install the published repository. The DEBUG-only
  `-uitest-install-repository <index URL>` installs every listed Source through the real
  installer. It is idempotent by URL: an active repository is refreshed, never re-added, so
  reconnected Listings keep their UUID. `-uitest-source mangadex` now resolves by `localId`.
  After the smoke test, three live tests passed on the simulator:
  - `testShowAllChaptersOpensFullListWithSortAndSelect`;
  - `testADR0018Decision1ResumeFromHistoryKeepsTheId`;
  - `testForYouRailReachesTheScreenWithCards`.
- **#259 merged:** Settings → Repositories → **Add** now dismisses the keyboard, because Add's
  result and any error rendered under it, and it now trims a pasted URL. Found during the smoke
  test, where Add appeared to do nothing.
- **#260 open (owner decided):** ADR-0004 Amendment 2. There is no built-in favourite; with no
  primary source, **install order settles ties**, and "No preference" says so. Matching an
  installed MangaDex by `localId` was rejected, because any repository could claim that name.
  CI was pending at the time of writing.

## Next

1. **Owner: merge #260** once CI is green (`gh pr merge 260 --squash`, without
   `--delete-branch`), then remove the worktree `/private/tmp/mangacarta-tiebreak` and the
   branch `fix/no-preference-means-install-order`.
2. **Product question, to start the next session — `mixed` Sources are hidden by default.**
   - Any Source with `adult != none` counts as adult (`ExtensionSourceRegistrar`, `isNSFW`), and
     adult Sources are hidden until "Show adult sources" is on.
   - MangaDex declares `mixed`, so a new reader who installs it sees an empty Home until they find
     that toggle. The owner hit exactly this during the smoke test.
   - Options:
     - keep today's behaviour;
     - show `mixed` Sources while hiding only their adult titles;
     - decide at install time.
   - This is ADR-0022's territory, and the owner prefers to discuss a fork like this in prose.
     It overlaps with item 3 under "Other outstanding work".
3. **The remaining live UI tests.** Only 3 of the 16 that browse were run after #258. Run the
   rest by name, and sort failures into "the catalog moved" and "real regression". Retire the ones
   that only proved the compiled Source.

## Other outstanding work

1. **Rate-limit hint gap:** `ExtensionSource.invoke` drops `retryAfterSeconds` when it maps
   `ExtensionInvocationError` to `SourceError.invocation`. The MangaDex research also records the
   unimplemented at-home image-fetch report path. Decide both before claiming complete AUP
   coverage.
2. **Flaky tests:**
   - `MALAuthenticatedClientTests` "Concurrent 401s share one refresh" depends on order: the
     scripted transport serves responses in sequence.
   - **New:** `LocalImportUITests.testImportReadAndDelete` failed twice on 2026-09-27, both times
     passing on a re-run with no change:
     - on #259, at line 18 (the empty-Library copy, after about 55s);
     - on #260, with "Timed out while launching application via Xcode" at line 15.
     
     It is the first hermetic UI test to launch the app, so the likely cause is a cold-start
     timeout on the CI simulator rather than the test itself. A warm-up launch, or a longer launch
     timeout for the first test, is the probable fix.
3. **Adult fallback edge:** with only adult-classed Sources installed and "Show adult sources"
   off, `SourceRegistry.active` still falls back to one. Decide this together with Next 2.
4. **README is stale:** its Features line still says "MangaDex plus a Cloudflare-protected,
   HTML-scraped site", as if both were built in. Since #255 neither ships.
5. **`MangaDexSource` / `MangaDexAPI`** still compile because AniList, MAL and the resolver use
   them, but nothing registers them. Deleting or narrowing them is a separate refactor.
6. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's original or
   public-domain sample and screenshot art, a sample URL/attachment, and contact placeholders.
   Recheck every claim against this build.
7. **Local import:** ComicInfo/open-in and Series grouping remain, per the local-import design.
8. **Human gates:** a manual VoiceOver device pass (#90); the MAL live-write check
   (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); the MangaCarta name
   reservation/trademark check (#150); the app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- **Simulator backups** from before the smoke test: `~/Manga-Reader-sim-backup-2026-09-27`
  (legacy ids, bundled WeebCentral). After it: `~/Manga-Reader-sim-backup-2026-09-27-post-smoke`.
  The backups hold Application Support and the app's preferences plist.
- **The hermetic `RepositorySettingsUITests` clear two real settings** at launch:
  `settings.declaredAgeOver18` and `settings.showAdultSources` in the app's standard defaults. On
  the seeded simulator, restore both afterwards:
  `xcrun simctl spawn <id> defaults write Elias-Magdaleno.Manga-Reader <key> -bool true`.
- **Simulator typing:** without Simulator → I/O → Keyboard → **Capture Keyboard**, the Mac keyboard
  drops keys in some fields. That is not an app bug.
- Name-based `xcodebuild` destination selection fails. Use
  `-destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691'`, the seeded
  iPhone 17 Pro. Keep `-parallel-testing-enabled YES`.
- A new worktree needs `Secrets.xcconfig` copied from the main checkout. Under `/private/tmp`,
  `xcp` needs the `/tmp/...` spelling of the path, or it reports "Group not found".
- The agent's permission classifier blocks `gh pr merge` and force pushes, even after the owner
  approves in chat, so the owner runs those. Merge **without** `--delete-branch` when the branch
  lives in a worktree. The agent can remove the worktree and branches afterwards; that step is
  not blocked.
- `SettingsView.swift` has three pre-existing `swiftlint --strict` violations (two line lengths
  and one `else` position). CI lints without `--strict` and passes.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
