# Handoff — persisted Source ID migration is in PR #254

Date: 2026-09-25. This is the one live handoff. The prior handoff was moved to `archive/` before this one was written. Recheck GitHub and working trees before acting.

## Completed

- WeebCentral and MangaDex engines were published in the separate `proxy-link/mangacarta-sources` repository before this session; the prior handoff records the byte and index checks. Live site behavior was not verified.
- In isolated worktree `/private/tmp/mangacarta-source-id-migration`, branch `feat/installed-source-id-migration`, commits `7a68d71` and `e03927e`, PR [#254](https://github.com/eliasmagdaleno/MangaCarta/pull/254) now implements reader-approved rebinding of saved bare `mangadex` and bundled-qualified WeebCentral data to a specific reader-installed Source. It runs before stores load at next launch, preserves JSON number bytes, and refuses Listing collisions. Data remains dormant if no valid target is installed. ADR-0003 Amendment 7 records the decision. Built-in Sources remain in this preparatory PR.
- The iPhone 17 Pro simulator build passed. Seven `InstalledSourceIDMigrationTests` passed locally with parallel testing enabled, including actual Work, update-state, and preference store round trips, retries, collisions, old entries without source IDs, and the bundled WeebCentral identity. `git diff --check` passed. The final `e03927e` push queued a new CI run (#36196697633) behind the earlier run; **CI is not yet verified**.
- `AGENTS.md` in the shared checkout is a symlink to `CLAUDE.md` (checked again this session); the two project instruction files cannot drift.

## Next

1. Check PR #254's final pushed head and CI jobs. Fix any CI/review finding, then merge if green. CI uses Xcode 16.4 / Swift 6.0, while local Xcode is 26.x. The isolated worktree has ignored `Secrets.xcconfig` copied only for local builds; do not stage it.
2. In a new isolated worktree based on current `origin/main`, remove compiled MangaDex registration, bundled WeebCentral auto-install/resources/transport, and adjust empty states, seed fixtures, and tests. Keep the app and App Store listing free of default, suggested, or linked repository URLs (ADR-0003 Amendment 6). Verify old installed bundled records remain dormant and reconnect through #254's choice path. Remove the Host API flat-request compatibility shim by slice 6.
3. Update `CLAUDE.md`'s current-state section only after removal lands; `AGENTS.md` follows through its symlink.

## Other outstanding work

1. **Live MangaDex install smoke test (owner):** install `https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/index.json` on the seeded iPhone 17 Pro simulator; confirm the `adult: mixed` age sheet, search “Yotsuba”, read a chapter, and check scanlation-group credit. Coordinate before changing that simulator's state. Engine fixture tests and raw-byte verification do not cover live API/CDN behavior.
2. **Rate-limit hint gap:** `ExtensionRuntime` preserves `Retry-After`, but `ExtensionSource.invoke` drops `retryAfterSeconds` while mapping `ExtensionInvocationError` to `SourceError.invocation`. Implement and test adapter behavior separately. The MangaDex research also records the unimplemented at-home image-fetch report path; decide its handling before claiming complete AUP coverage.
3. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's original/public-domain sample and screenshot art, sample URL/attachment, and contact placeholders. Recheck every claim against the eventual empty-source release.
4. **Local import:** ComicInfo/open-in and Series grouping remain per the local-import design. Check current code and ownership before starting either.
5. **Human gates:** manual VoiceOver device pass (#90); MAL live-write check (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); MangaCarta name reservation/trademark check (#150); app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- Shared checkout `/Users/eliasmagdaleno/Manga-Reader` is clean on current `main` (its `project.pbxproj` change was Xcode normalization only and was discarded with the owner's approval). Use isolated worktrees.
- `MALAuthenticatedClientTests` "Concurrent 401s share one refresh" is order-dependent: the scripted transport serves responses in sequence, so if one task's retry runs before the other's first request it receives the second 401. It failed #254's first CI run unrelated to the change.
- Local `xcodebuild` name-based destination selection saw duplicate iPhone 17 Pro clones. Simulator ID `ADDAB2F8-38C7-4D44-97EA-4E98281CF691` selected the required seeded device; keep `-parallel-testing-enabled YES`.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
