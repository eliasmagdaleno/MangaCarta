# Handoff — built-in and bundled Sources removed

Date: 2026-09-25. This is the one live handoff. The prior handoff was moved to `archive/` before
this one was written. Recheck GitHub and working trees before acting.

## Completed

- **#254** (reader-approved reconnection of legacy Source data, ADR-0003 Amendment 7) was reviewed
  and fixed in `24d27fa`: a reconnect binding is now spent once it applies or collides, instead of
  re-running every launch (which silently moved data the compiled Source recorded later and turned
  one later collision into a permanent launch error). The Settings row stopped parsing the stores
  in `body`. All four CI checks passed on `24d27fa`. **Merging it was blocked by the agent's
  permission classifier and needs the owner** — this branch is stacked on it (see Next).
- **The removal slice** (branch `feat/no-built-in-sources`, worktree
  `/private/tmp/mangacarta-no-built-in`):
  - `builtInSources()` is Local alone. `MangaDexSource`/`MangaDexAPI` still compile because
    AniList, MAL and the resolver use them; deleting them is a separate refactor.
  - The bundled WeebCentral package, `BundledRepositoryTransport`, `AppRepositoryTransport`, the
    `bundled.invalid` route, `installBundledSources()` and the Settings bundled-repository branches
    are gone. Only the fixed repository UUID remains (`RetiredBundledRepository.swift`).
  - `ExtensionComposition.retireBundledSources()` runs at composition, before any view reads the
    registry: an active bundled record is removed through `removeRepository`, which uninstalls the
    Source and deletes its script but keeps Listings, pins and history.
  - `SourceRegistry.source(for:)` treats the two legacy ids as retired, so their records fail as
    unavailable instead of falling back to the active Source.
  - The fallback browse Source now prefers a non-adult one, because no browsable built-in comes
    first any more (ADR-0022).
  - `CLAUDE.md` current state and the glossary were updated.
  - The WeebCentral engine and index moved to `MangaCartaTests/__Fixtures__/weebcentral/` for the
    port tests (engine SHA-256 `88ad0627…`, identical to the published copy).
  - **Verified:** full `MangaCartaTests` run on commit `f137700` — 1,226 tests, 1,221 passed,
    0 failed, 5 skipped. **Not done:** mutation checks for the new tests (the #254 fix's two tests
    were mutation-checked; this slice's were not), the hermetic UI suites locally, and CI (no PR
    yet).
- **Where this handoff lives:** until this branch merges, `main` still carries the older
  `2026-09-25-weebcentral-published.md` handoff. This file, on `feat/no-built-in-sources`, is the
  current one.

## Next

1. **Owner: merge #254**, then rebase this branch: `git rebase --onto origin/main 24d27fa` (the
   squash merge makes #254's own commits disappear from main's history), and open this PR against
   `main`. It is deliberately not opened as a PR stacked on #254's branch: a stacked PR here closes
   unrecoverably when its base branch is deleted, and gets no CI.
2. Check this PR's CI, especially the hermetic UI suites (they must not assume a built-in Source).
3. Remove the Host API flat-request compatibility shim (`ExtensionSource.swift`, "Compatibility shim
   for pre-#186 flat-shape engines") with the frozen `__Fixtures__/weebcentral/engine-v1.js`. Small,
   separate PR.
4. The live UI tests in `MangaCartaUITests.swift` (not CI-gated) drive the compiled MangaDex through
   `-uitest-source mangadex` and will fail now. Adapt them to install the MangaDex engine from a local
   fixture repository, or retire the ones that only proved the compiled Source.

## Other outstanding work

1. **Live MangaDex install smoke test (owner):** install
   `https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/index.json` on the seeded
   iPhone 17 Pro simulator; confirm the `adult: mixed` age sheet, search "Yotsuba", read a chapter,
   check scanlation-group credit. The seed fixture's rows carry `sourceId: "mangadex"`, so on this
   build they are dormant legacy data — accepting the reconnect prompt after the install is also the
   first end-to-end test of #254. Coordinate before changing that simulator's state.
2. **Rate-limit hint gap:** `ExtensionSource.invoke` drops `retryAfterSeconds` when mapping
   `ExtensionInvocationError` to `SourceError.invocation`. The MangaDex research also records the
   unimplemented at-home image-fetch report path; decide it before claiming complete AUP coverage.
3. **Flaky test:** `MALAuthenticatedClientTests` "Concurrent 401s share one refresh" is
   order-dependent — the scripted transport serves responses in sequence, so if one task's retry
   runs before the other's first request it gets the second 401. It failed #254's first CI run.
4. **Adult fallback edge:** if only adult-classed Sources are installed and "Show adult sources" is
   off, `SourceRegistry.active` still falls back to one (the registry does not read that setting).
   Home and Search show no chip for it. Decide whether `active` should be nil in that case.
5. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's original or
   public-domain sample and screenshot art, sample URL/attachment, and contact placeholders.
   Recheck every claim against this build.
6. **Local import:** ComicInfo/open-in and Series grouping remain per the local-import design.
7. **Human gates:** manual VoiceOver device pass (#90); MAL live-write check
   (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); MangaCarta name
   reservation/trademark check (#150); app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- Name-based `xcodebuild` destination selection currently fails ("Unable to find a device
  matching"); use `-destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691'`,
  which is the seeded iPhone 17 Pro. Keep `-parallel-testing-enabled YES`.
- Killing an `xcodebuild test` mid-run can leave a parallel-testing clone that hangs the next run
  with the test host never launching. `xcrun simctl --set testing shutdown all` cleared it.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
