# Handoff — no-built-in-Sources merged; follow-ups

Date: 2026-09-27. This is the one live handoff. The prior handoff
(`2026-09-25-no-built-in-sources-removed.md`) was moved to `archive/` before this one was written.
Recheck GitHub and working trees before acting.

## Completed

- **#254** merged (`95759a5`): readers can reconnect legacy Source data to an installed Source
  (ADR-0003 Amendment 7). A reconnect binding is spent once it applies or collides.
- **#255** merged (`80d09be`): the app ships no built-in or bundled remote Source (ADR-0003
  Amendment 6). `builtInSources()` is Local alone, and bundled WeebCentral installs are retired at
  launch with their data kept. All four CI checks passed, including the hermetic UI suites.
- **#256** merged (`6585aa3`): the pre-#186 flat paging shim is gone. The host sends paging only as the nested
  `page` value. Before removing it, both published engines in `proxy-link/mangacarta-sources`
  (`381b4a3`) were checked: they read only `request.page`. The `engine-v1.js` fixture and its test
  were deleted, and the Host API spec records the removal.

## Next

1. **Mutation checks for #255's new tests.** They were never done. The tests cover retiring the
   bundled install, the retired legacy ids in `SourceRegistry.source(for:)`, and the non-adult
   fallback browse Source. Break each behaviour and confirm a test goes red. #254's two fix tests
   were mutation-checked; these were not.
2. **Live UI tests** in `MangaCartaUITests.swift` (not CI-gated) still drive the compiled MangaDex
   through `-uitest-source mangadex`, so they fail now. Adapt them to install the MangaDex engine
   from a local fixture repository, or retire the ones that only proved the compiled Source.
3. **Live MangaDex install smoke test (owner):** install
   `https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/index.json` on the seeded
   iPhone 17 Pro simulator. Confirm the `adult: mixed` age sheet, search "Yotsuba", read a chapter,
   and check the scanlation-group credit. The seed fixture's rows carry `sourceId: "mangadex"`, so
   on this build they are dormant legacy data. Accepting the reconnect prompt after the install is
   also the first end-to-end test of #254. Coordinate before changing that simulator's state.

## Other outstanding work

1. **Rate-limit hint gap:** `ExtensionSource.invoke` drops `retryAfterSeconds` when it maps
   `ExtensionInvocationError` to `SourceError.invocation`. The MangaDex research also records the
   unimplemented at-home image-fetch report path. Decide it before claiming complete AUP coverage.
2. **Flaky test:** `MALAuthenticatedClientTests` "Concurrent 401s share one refresh" depends on
   order. The scripted transport serves responses in sequence, so if one task's retry runs before
   the other's first request, it gets the second 401. It failed #254's first CI run.
3. **Adult fallback edge:** if only adult-classed Sources are installed and "Show adult sources" is
   off, `SourceRegistry.active` still falls back to one, because the registry does not read that
   setting. Home and Search then show no chip for it. Decide whether `active` should be nil there.
4. **`MangaDexSource` / `MangaDexAPI`** still compile because AniList, MAL and the resolver use
   them, but nothing registers them. Deleting or narrowing them is a separate refactor.
5. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's original or
   public-domain sample and screenshot art, a sample URL/attachment, and contact placeholders.
   Recheck every claim against this build.
6. **Local import:** ComicInfo/open-in and Series grouping remain, per the local-import design.
7. **Human gates:** a manual VoiceOver device pass (#90); the MAL live-write check
   (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); the MangaCarta name
   reservation/trademark check (#150); the app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- Name-based `xcodebuild` destination selection currently fails ("Unable to find a device
  matching"). Use `-destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691'`,
  which is the seeded iPhone 17 Pro. Keep `-parallel-testing-enabled YES`.
- Killing an `xcodebuild test` mid-run can leave a parallel-testing clone that hangs the next run
  with the test host never launching. `xcrun simctl --set testing shutdown all` cleared it.
- A new worktree needs the gitignored `Secrets.xcconfig` copied from the main checkout, or the build
  fails with "Unable to open base configuration reference file".
- The agent's permission classifier blocks `gh pr merge` and force pushes, even after the owner
  approves in chat. The owner runs those with `!`. If a PR's branch is checked out in a worktree,
  `--delete-branch` merges but then fails to delete the local branch. Remove the worktree, then
  delete the local and remote branch.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
