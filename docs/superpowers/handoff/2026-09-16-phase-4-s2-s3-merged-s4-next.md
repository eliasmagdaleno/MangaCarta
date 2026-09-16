# Handoff — Phase 4: S2 and S3 merged, S4 is next

Date: 2026-09-16
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-16-s2-s3-merged`, off `main` at `4dc56dc`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Where the phase stands

Phase 4 is the repository format and installer — the path from a URL a reader types to a Source in
the picker. The plan is `docs/superpowers/plans/2026-09-11-phase-4-repository-format-installer.md`;
**it owns the slice breakdown, the eleven acceptance criteria and the worker briefs, and this
handoff does not restate them.** #168 tracks slice state.

| Slice | What | State |
|---|---|---|
| D0 | Repository format design + decisions | ✅ merged `9f70750` (#169) |
| S1 | Host capability bridge — `host.http`, `host.storage`, `host.log` | ✅ merged `4de2f43` (#170) |
| S2 | Package parsing + validation (criterion 1, 2-parsing) | ✅ **merged `425154f` (#173), 2026-09-16** |
| S3 | `RepositoryStore` + installer pipeline (criteria 2-registry, 3–6) | ✅ **merged `4dc56dc` (#175), 2026-09-16** |
| S4 | `ExtensionSource: MangaSource` + dynamic registration (criteria 8, 9) | **next — unblocked, not started** |
| S5 | Settings UI (criterion 10) | not started, needs S4 for anything to show |
| S6 | WeebCentral installed rather than compiled (criterion 11) | not started, needs S4 |

Unit suite on `main`: **1034 total, 1029 passed, 0 failed, 5 skipped** (iPhone 17 Pro, from the
result bundle). SwiftLint clean. CI green on both merges.

### What S2 and S3 left on `main`, for S4 to build on

- `Models/RepositoryIndex.swift` — `RepositoryIndexValidator.validate(json:indexURL:)` →
  `RepositoryIndex` / `RepositoryBundle` / `RepositorySourceRecord { rawJSON, localID }`.
  `RepositoryFormatLimits` (1 MiB index, 10 MiB script) — **`maximumScriptBytes` has no consumer
  yet**; whoever writes the production `RepositoryTransport` enforces it there.
- `Services/RepositoryTransport.swift` — the `RepositoryTransport` protocol and
  `RepositoryIndexFetchOutcome`. **No production conformer exists.** Tests use a fake; the
  `URLSession` one is "a few lines" per S3 and belongs to whichever slice first needs a real fetch
  (S5 or S6).
- `Services/RepositoryStore.swift` — `repositories.json` + `extension-scripts/<uuid>/<bundle>.js`.
- `Services/ExtensionInstaller.swift` — `@MainActor`, wraps `SourceLifecycleRegistry`.
  `restoreInstalledSources()` is the launch call; `qualifiedID(repositoryID:localId:)` the one
  minter. **Nothing calls it from `AppComposition` yet** — S3 left that to S4 deliberately, because
  wiring half of it would be a second owner.
- `SourceDeclaration` now has a `fileprivate init` inside `SourceDeclarationValidator.swift` (#161).
  A test that needs one goes through `SourceDeclarationValidator.validate(json:qualifiedId:)` —
  see `ExtensionRuntimeFixtures` for the pattern.

### The gap S4 closes — still true

`ExtensionRuntime(` is constructed **only in `MangaCartaTests`**, and `SourceRegistry.builtInSources()`
returns a hard-coded `[MangaDexSource(), WeebCentralSource(...)]`. The parser and installer change
nothing a reader can see until S4 exists. Its brief is in the plan, ready to paste, plus the
preamble above it.

## What is owed

### 1. Dispatch S4

Brief: plan → "S4 — `ExtensionSource: MangaSource` and dynamic registration", with the shared
preamble verbatim on top. Two things to add to the brief that the plan predates:

- The launch wiring: `AppComposition` constructs a `RepositoryStore` + `ExtensionInstaller`, calls
  `restoreInstalledSources()`, and the registry takes installed Sources from the lifecycle registry.
  The injected-registry rule stands — `AppComposition.registry` is the one, never `.shared`.
- **#176 and #177** (below) are S3 follow-ups an S4 worker will be near; either fix them in a
  separate PR first or leave them alone, but do not fold them into S4.

One worker, Claude or Codex; if Codex, expect the stop-hook death (see "Dispatch mechanics").

### 2. Two S3 follow-ups, filed from review — #176, #177

- **#176** — `disable` / `enable` / `uninstall` / `removeRepository` move the registry *before*
  persisting, the reverse of the installer's own header contract. A failed commit leaves the
  registry and `repositories.json` disagreeing until relaunch, when the record wins and a disabled
  Source comes back. Fix is reordering; the registry cannot refuse those moves.
- **#177** — a corrupt `repositories.json` decodes to an empty snapshot and the next commit
  overwrites it, erasing every qualified-id binding §8.2 promises to retain. Move the file aside and
  refuse to commit instead.

Both `ready-for-agent`, both small, both orthogonal to S4.

### 3. Phase 4's remaining slices after S4

S5 (Settings UI) and S6 (WeebCentral as an installed package). S6 should **measure** — serialized
storage size, wall-clock per operation, request counts, and the actual index/script sizes it
installs — for evidence gate 1 (spec §16, design §10), even though closing the gate is not its job.

### 4. The launch decisions — four, none of them features, all the user's

- **#149 — MAL privacy label.** The shipped manifest is wrong today (empty
  `NSPrivacyCollectedDataTypes`); recommendation is Name, User ID, Product Interaction.
- **#150 — the name.** Whether to commission a clearance search before launch.
- **#171 — App Review posture for installable adult Sources.** ADR-0022 Amendment 1 decided the
  app *allows* them; nobody has decided what we tell Review. Citations if it goes badly: 1.1.4 and
  1.2. Refusing later is a one-line installer change; refusing now cannot be undone without an
  app update.
- **No real app icon.** Twelve handoffs. Outsource it, order it early, *MangaCarta* on it. The
  placeholder (#165) is not progress — replace the file, do not refine it.

### 5. Device-in-hand items — the user's to run, one sitting for both

- **Live-verify MAL progress push.** Sign in, read a chapter to the end, confirm the number moves on
  myanimelist.net. `scripts/mal_live_write.py` isolates the API path;
  `testLiveHorimiyaCompletionPushesProgress` is behind `TEST_RUNNER_MAL_LIVE_WRITE=1`.
- **Manual VoiceOver pass, #90.** `ready-for-human`, no row has a verdict, no results file in
  `docs/accessibility/`. `./scripts/voiceover-pass.sh` drives it. Needs a real iPhone. Rows most
  needing eyes: 4.3, 6.5, 7.2, 7.5, 7.6. Close #90 when every row has a verdict, not when every
  defect is fixed.

### 6. Naming debt, small

`-uitest-updates-state` seeds a fixture unrelated to updates (`two-listings`). Rename if a third
unrelated state appears.

## Dispatch mechanics

Everything in the archived `2026-09-11-phase-4-underway-s2-s3-in-flight.md` still holds — the
Codex stop-hook death, `orca terminal send` recovery, watching the preview not just `check`, the
partial isolation of a second simulator device, the pbxproj keep-both conflict. What this session
added:

- **The GitHub UI merge did not take, twice.** #173 showed as merged to the user and was not:
  `gh pr view --json state,mergedAt` said `OPEN` / `null` and `origin/main` had not moved.
  `gh pr merge <n> --squash` from the session, with the user's explicit say-so, worked first time on
  both PRs. **Check `mergedAt`, not the UI.**
- **`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` failed to resolve** from this
  session's shell ("Unable to find a device matching…" listing only My Mac), while
  `id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691` worked. The device was booted and listed by `simctl`.
  Not diagnosed; if the name form fails, use the id from `xcrun simctl list devices available`.
- **Integrating a seam is deleting it.** S3's `RepositoryIndexSeam.swift` carried S2's exact shapes;
  integration was one file deleted, two types moved, zero call sites touched. Worth repeating when
  two slices are dispatched in parallel against an interface only one owns.
- **Xcode churn in the main checkout** showed up as 114 lines of `project.pbxproj` and a reordered
  `Info.plist` with nothing behind them — discarded with `git checkout --` before pulling.

## Supervision protocol

Unchanged; it earned its place again. Both S2 and S3 were reviewed by re-running one of the
worker's own mutations (S2's cross-bundle `localId` branch; S3's c3b, mint-under-a-fresh-UUID) and
each reddened exactly the tests the PR body claimed. Then a read, then the full bundle after the
rebase, then merge.

1. `git -C <worktree> status` and the terminal preview — the dispatch status lies.
2. Rebase onto `main`; a `project.pbxproj` conflict is keep-both.
3. Full `MangaCartaTests` after the rebase; totals from the result bundle.
4. Review by mutation, not by reading — count clauses, not tests.
5. Merge, and check the PR body names a test *and a mutation* per criterion.

## Repository state

- `main` at **`4dc56dc`**. Merged 2026-09-16: **#173** (S2), **#175** (S3).
- **No open PRs.**
- Open issues: **#168** (Phase 4 tracking), **#176**, **#177** (S3 follow-ups, new), **#171**
  (App Review posture), **#149**, **#150** (decisions owed), **#90** (VoiceOver, ready-for-human).
- Branch protection requires `Build & unit tests`, `SwiftLint`, `Hermetic UI tests`.
- **Worktrees: four.** The main checkout; `Manga-Reader-worktree-helper` (unrelated);
  `phase4-s2-package-parsing` and `phase4-s3-installer` under `~/orca/workspaces/Manga-Reader/` —
  **both merged, safe to remove**, not yet removed.
- Orca run `run_a28b59b9c029`, coordinator `term_15c0eb64-b03c-4606-add4-e337286e7ea7` — may be
  dead after a runtime restart; a fresh S4 dispatch may need a fresh run.
- `docs/superpowers/handoff/` holds this file and `archive/` (81 archived handoffs plus README).
