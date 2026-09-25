# Handoff — MangaDex engine published; live install check owed

Date: 2026-09-25, 13:18 PDT. This is the one live handoff. The previous handoff was moved to `archive/`. Recheck GitHub status and the working trees before acting.

## Completed in this session

- PR **#249** added the format-1 MangaDex JSON-API engine, Source declaration, captured fixtures, 16 integration tests, and SHA pin. A whole-branch review found that Latest Updates skipped unreturned titles when a chapter fetch contained more unique manga than the requested title count. A regression failed first, the cursor/exhaustion logic was fixed, and all 16 engine tests passed. All four CI checks passed. PR #249 merged as **`930fa72`**.
- The engine and index were published byte-identically to `proxy-link/mangacarta-sources` as **`d0ff16e`**, using its `github-proxy-link` SSH alias and `proxy-link` commit identity. The public raw URLs served bytes identical to the app fixtures. Engine SHA-256: `00841cf59575c3e5ea3045879e4d38e113c1fbf0008aaef3e4c981f929ccef49`.
- Local full-suite runs exposed a scheduling race in the existing rate-limiter cancellation test. PR **#250** replaced yield-count timing with a signal that the waiter entered the sleeper. In an isolated checkout, 984 XCTest tests (5 skipped) and 223 Swift Testing tests passed; all four CI checks passed. PR #250 merged as **`9f02e22`**. No production rate-limiter code changed.
- PR **#245** (SwiftLint missing-interpolation rule) had already merged as **`25802f9`** earlier today. The older handoff still listed it as open.

## Outstanding now

1. **Live install smoke test (owner):** on a simulator app, add `https://raw.githubusercontent.com/proxy-link/mangacarta-sources/main/index.json` in Settings → repositories; install MangaDex; confirm the `adult: mixed` age sheet; search “Yotsuba”; open a chapter; check scanlation-group credit. The fixture tests and raw-byte check cannot establish live MangaDex API/CDN behavior. The iPhone 17 Pro simulator is the seeded device; coordinate before changing its state.
2. **No-built-in-Sources continuation:** the MangaDex engine is published, but the compiled MangaDex Source is still registered and WeebCentral is still bundled. Scope the next slices from ADR-0003 Amendment 6 and the repository-format design: publish WeebCentral, migrate persisted bare `mangadex` IDs without losing dormant data, remove the compiled/bundled remote Sources, adapt seed fixtures/tests, then remove the Host API flat-request compatibility shim by slice 6. Use an isolated worktree and check Claude's current work before choosing files.
3. **Rate-limit hint gap:** the engine and `ExtensionRuntime` preserve MangaDex `Retry-After`, but `ExtensionSource.invoke` maps `ExtensionInvocationError` to `.invocation(error.code)` and drops `retryAfterSeconds`. The engine test proves `.rateLimited` reaches the app, not that callers can see the hint. Decide and implement the host adapter behavior in a separate change; the #249 PR body calls this out. Do not claim the plan's end-to-end hint condition is met yet.
4. **Docs queue:** PRs #220 (App Store copy), #221 (MangaDex engine research), #222 (local-import slice-2 plan), and #227 (ADR-0019 external-id bridge) remain open. Recheck their heads and merge states. #220 previously conflicted with #215; confirm all release-build claims and reconsider the old CBZ/ZIP-only subtitle now that PDF imports ship. Original/public-domain sample and screenshot art remains owed. #221 may need its implementation status updated after #249.
5. **Local import:** ComicInfo/open-in and Series grouping remain, per the local-import design. Check current code and Claude ownership before scoping an independent slice.
6. **Human gates:** VoiceOver device pass (#90), MAL live-write check (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`), MangaCarta name reservation/trademark check (#150), and the app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- The shared checkout `/Users/eliasmagdaleno/Manga-Reader` was left on `main` with a pre-existing modified `MangaCarta.xcodeproj/project.pbxproj`. This session did not edit it. Do not discard or stage that change without checking its owner.
- The isolated engine worktree `/Users/eliasmagdaleno/Manga-Reader-mangadex-engine` is clean but its local branch predates the squash merge; use main's `930fa72` for new work. Temporary `/private/tmp` checkouts and test logs are scratch, not authoritative handoffs.
- CI's Xcode 16.4/Swift 6.0 gate passed #249 and #250. The engine's local full suite failed three times only at the old rate-limiter test before #250; #250's fixed test passed CI. Every `xcodebuild` command used the iPhone 17 Pro simulator with parallel testing left enabled.
- For a new handoff, archive this file first and carry every still-open item into the replacement.
