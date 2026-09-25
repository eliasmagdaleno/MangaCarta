# Handoff — docs queue merged; WeebCentral publication is next

Date: 2026-09-25, 13:38 PDT. This is the one live handoff. The prior handoff was moved to `archive/` before this one was written. Recheck GitHub and the working trees before acting.

## Completed since the previous handoff

- Fetched current `main` after the shared checkout's local `main` proved stale. PR #251 had already replaced the earlier handoff and recorded the merged MangaDex engine (#249), rate-limiter test fix (#250), and published MangaDex engine/index. This session left the shared checkout and its pre-existing `project.pbxproj` change untouched.
- Reviewed and merged the four remaining docs PRs: #227 (`122b001`, ADR-0019 external-ID bridge), #220 (`8e50a60`, App Store submission draft), #221 (`8500009`, MangaDex engine research), and #222 (`891292e`, local-import slice-2 plan). #227's registry and concurrency claims match current code. #221 and #222 now identify themselves as historical snapshots with implemented outcomes.
- Resolved #220's conflict by retaining ADR-0022 Amendments 4 and 5 in order. The draft now names PDF in the subtitle because #235 shipped; removes the unshipped ComicInfo listing claim; matches the current “Import from Files” empty state; and tells the submitter to answer Apple's content questionnaire accurately, using its higher-age override if needed to target the owner's chosen 16+. Apple's current age-rating help documents that override. All four docs PR heads passed CI, but docs-only jobs skipped build and tests.
- Verified #90 and #150 remain open. No PR remained open immediately after the docs merges.

## Next implementation slice

**Publish WeebCentral as an ordinary package in `proxy-link/mangacarta-sources`.** The public index currently contains only the MangaDex bundle. The app already has a bundled WeebCentral `engine.js` and format-1 index under `MangaCarta/Resources/BundledRepositories/weebcentral/`. Copy the engine, convert the index's `bundled.invalid` script URL to a public raw URL, pin the actual SHA-256, and validate installability and served bytes. Keep the publication separate from app removal. Do not add a repository URL to the app, App Store copy, or project website (ADR-0003 Amendment 6). Review site-specific script behavior before claiming live functionality; the bundled fixtures alone cannot prove it. Use an isolated worktree and the `proxy-link` repository identity/SSH alias used for MangaDex.

After publication, specify and implement migration for the bare `mangadex` id and already-installed bundled WeebCentral records **without deleting dormant Works, pins or history**. Then remove compiled MangaDex registration, bundled WeebCentral auto-install/resources/transport, and adapt seed fixtures and tests. ADR-0003 Amendment 6 leaves existing bundled-record handling to the removal PR. The Host API flat-request compatibility shim is also owed by slice 6. Current `SourceRegistry.builtInSources()` still returns MangaDex and Local, and `MangaCartaApp` still calls `installBundledSources()`.

## Other outstanding work

1. **Live MangaDex install smoke test (owner):** install `https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/index.json` on the seeded iPhone 17 Pro simulator; confirm the `adult: mixed` age sheet, search “Yotsuba”, read a chapter, and check scanlation-group credit. Coordinate before changing that simulator's state. The engine fixture tests and raw-byte verification do not cover live API/CDN behavior.
2. **Rate-limit hint gap:** `ExtensionRuntime` preserves `Retry-After`, but `ExtensionSource.invoke` drops `retryAfterSeconds` while mapping `ExtensionInvocationError` to `SourceError.invocation`. Implement and test adapter behavior separately; #249 did not meet the end-to-end hint condition.
   The MangaDex research also records the still-unimplemented at-home image-fetch report path;
   decide its handling before claiming complete AUP coverage.
3. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's original/public-domain sample and screenshot art, sample URL/attachment, and contact placeholders. Recheck every claim against the actual no-built-in-Sources release after removal. The current development binary still contains the compiled and bundled remote Sources.
4. **Local import:** ComicInfo/open-in and Series grouping remain per the local-import design. Check current code and ownership before starting either.
5. **Human gates:** manual VoiceOver device pass (#90); MAL live-write check (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); MangaCarta name reservation/trademark check (#150); app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- The shared checkout `/Users/eliasmagdaleno/Manga-Reader` is on an old local `main` with a pre-existing modified `MangaCarta.xcodeproj/project.pbxproj`. Do not discard, stage, or merge that change without checking its owner. Work on current `origin/main` in an isolated worktree.
- For code PRs, review the final pushed head and actual CI test jobs. Every `xcodebuild` invocation uses the iPhone 17 Pro simulator with parallel testing enabled. CI uses Xcode 16.4 / Swift 6.0.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
