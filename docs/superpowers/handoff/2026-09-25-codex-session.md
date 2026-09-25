# Handoff — Codex session, rate limiter merged

Date: 2026-09-25, 10:07 PDT. This is the one live handoff. The previous file was moved to
`archive/` before this one was written. Recheck GitHub status before acting on any PR.

## Work completed this session

- Merged **#215** (ADR-0003 Amendment 6: no built-in or bundled remote content Sources) as
  `ead55e2`. Reviewed **#216**, corrected its stale implementation status, UUID item-id plan,
  refresh fallback, and UI-fixture description, then merged it as `d059667`.
- Closed superseded handoff PR **#228**. Refreshed **#238** after the September 24 merges, removed
  unrelated `project.pbxproj` churn, merged it as `adb6844`, and verified main had exactly one
  live handoff.
- Reviewed **#242** against issue **#232**. The spec review found that cancelling a middle
  waiter did not return its slot; the old test expected that gap. Fixed slot reuse and added a
  regression assertion. Preserved AniList's historical behavior of running the operation after
  cancellation while waiting, with a test. Resolved the test-file conflict with main in an
  isolated worktree. Focused `AniListAPITests` and `HostRateLimiterTests` passed on the iPhone 17
  Pro simulator; all four CI checks passed on the final head. Merged #242 as **`21659b9`**;
  #232 closed. The temporary worktree and derived data were removed.
- The owner pointed out that Claude CLI should be logged in. They were right: sandboxed
  `claude auth status` falsely reported no login because the sandbox could not access its auth
  state. Outside the sandbox, auth reported the owner's Claude.ai Pro login and a noninteractive
  prompt succeeded. A subsequent **read-only Claude review of merged #242** found no correctness
  or regression bugs. It noted one design limit: budgets are per Source *and* origin, so two
  Sources using the same site can exceed a site-wide per-IP ceiling. #232 allowed Source or origin
  keys; revisit this if the MangaDex engine can be installed more than once.

## Outstanding work

1. **#245** is Claude's lint-rule PR and the shared checkout's branch
   `chore/lint-missing-interpolation-backslash`. Its CI was green at this handoff; review its
   final head and merge when ready. Do not edit the shared checkout for other work.
2. **Docs queue:** #227 (ADR-0019 external-id bridge), #221 (MangaDex-engine research), and #222
   (local-import slice-2 plan, whose code is already merged) remain open. #220 (App Store copy and
   ADR-0022 Amendment 5) conflicts with main after #215; resolve it and check every listing
   claim against the release build. The owner chose a 16+ target and no test repository. The
   prior `CBZ & ZIP comic reader` subtitle predates the merged PDF slice and needs a fresh choice.
   Original or public-domain sample and screenshot art is still owed.
3. **No-built-in-Sources plan:** removal slices 1–4 and the three host prerequisites are merged,
   including #242. The next implementation slice is the MangaDex JSON-API engine. Later work:
   remove bundled WeebCentral, publish engines/index under `proxy-link/mangacarta-sources`,
   migrate persisted `mangadex` IDs without deleting dormant data, remove compiled MangaDex,
   and adapt tests/seed fixtures. Read ADR-0003 Amendment 6 and the repository format design,
   then validate the next slice against current code.
4. **Local import:** slices 1–4 and the #240 follow-ups (#246) are merged. ComicInfo/open-in and
   Series grouping remain per the local-import design. Check current code before scoping them.
5. **Human gates:** VoiceOver device pass (#90); MAL live-write check
   (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); MangaCarta name reservation and
   trademark check (#150); app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- This session did not change Claude's shared #245 checkout. Use an isolated worktree for new
  implementation. Old merged-PR Orca worktrees remain; verify their PRs and workers before
  removal.
- For code PRs, review the final pushed head and actual CI test jobs. Docs-only CI jobs can
  report success while skipping build and tests. Every `xcodebuild` invocation targets an
  iPhone 17 Pro with parallel testing enabled, per `CLAUDE.md`.
- Claude CLI needs access outside the filesystem sandbox for its login state. A sandboxed
  `loggedIn: false` result alone does not mean the user is signed out.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
