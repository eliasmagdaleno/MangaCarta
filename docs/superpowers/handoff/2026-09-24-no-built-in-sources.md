# Handoff — no built-in Sources, 2026-09-25

Updated 2026-09-25 00:43 PDT. This is the one live handoff; the previous one is moved to `archive/` in this PR. Check GitHub before acting on PR status.

## Current state

- ADR-0003 Amendment 6 is merged (#215): the App Store build will have no built-in or bundled remote content Sources. ADR-0025 and the local-import design are merged (#216). The decisions and reasoning live in those documents.
- Removal slices 1–4 are merged (#223, #224, #229, #234). Local-import slices 1–4 are merged (#217, #225, #236, #235). The host prerequisites for the MangaDex engine are merged except rate limiting: wildcard asset origins #237, scanlation-group credit #241, and connect hardening #243/#247.
- #239 renumbered the Host API paging amendment; #246 completed the local-import follow-ups from issue #240. The shared checkout is on Claude's `chore/lint-missing-interpolation-backslash` branch (#245); leave it alone. Do implementation in an isolated worktree.
- PR #228, the older in-place handoff update, is closed. This PR (#238) replaces it and archives the prior live file.

## Next

1. **Review the remaining code PRs.** #242 is the per-site rate limiter for issue #232; #245 is Claude's lint rule. Both were open with green CI at the last session checkpoint. Review the current heads and checks before merging. No unclaimed `ready-for-agent` issue remained at that checkpoint.
2. **Finish the docs queue.** #227 records the registry-sourced external-id bridge; #221 is MangaDex-engine research; #222 is the local-import slice-2 plan (implementation already merged). #220 contains App Store submission copy and ADR-0022 Amendment 5, but currently conflicts with main after #215. Resolve it and verify every listing claim against the release build. The owner chose a 16+ target, no test repository, and `CBZ & ZIP comic reader` as the subtitle until PDF ships; screenshot and App Review sample art is still owed.
3. **Resume the no-built-in-Sources plan after #242.** Build the MangaDex JSON-API engine, remove bundled WeebCentral and its transport/installer path, publish the engines and index to `proxy-link/mangacarta-sources`, migrate persisted `mangadex` ids without deleting dormant data, then remove compiled MangaDex and adapt tests/seed fixtures. The implementation sequence and constraints are in ADR-0003 Amendment 6 and the archived 2026-09-24 handoff; validate them against current code before scoping a slice.
4. **Continue local import.** The remaining design slices are ComicInfo/open-in and Series grouping. Recheck the local-import spec and current code before starting; #246 already delivered several UX follow-ups. Original or public-domain sample art for screenshots and App Review remains an owner item.
5. **Human gates:** VoiceOver device pass (#90), MAL live-write check (`scripts/mal_live_write.py` with `TEST_RUNNER_MAL_LIVE_WRITE=1`), and MangaCarta name reservation/trademark check (#150). App icon brief: `docs/design/app-icon-brief.md`.

## Worktree and review cautions

- Keep clear of the shared #245 checkout and the in-flight #242 worktree. Old merged-PR worktrees remain under `~/orca/workspaces/Manga-Reader/`; remove them only after confirming their PRs and any Orca workers are finished.
- CI skips build/unit/UI jobs on docs-only PRs. A green docs PR does not establish that the current app build passes. For code PRs, check the final pushed head and the actual test counts; prior worker focused runs missed failures that the full suite caught.
- Any `xcodebuild` run uses the iPhone 17 Pro simulator with parallel testing enabled, per `CLAUDE.md`. Local Xcode 26 / Swift 6.2 accepts syntax CI's Xcode 16.4 / Swift 6.0 does not.
- A new handoff must archive this live file first and carry every still-open item forward, per `CLAUDE.md`.
