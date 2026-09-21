# Handoff — S4 merged, S5/S6 wave next; delegate to Codex first, Astra only for hard planning

Date: 2026-09-21, 12:45 PDT
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
Branch: `docs/s4-landed-state`, off `main` at `4648d59`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Standing instructions from the user

- **Delegate implementation to Codex workers by default; spend Claude on review and decisions**
  (2026-09-19). Working Codex model: **`gpt-5.6-luna`** (`--effort medium`). `gpt-5.4` is refused
  on this account — the worker sits at a 400; `worker-stop` it and retry.
- **Astra** (OpenAI's frontier Codex model, 2026-09-19): for *hard* tasks, have Astra do the
  planning and fan the plan out to subagents. It burns quota fast — never for routine slices,
  follow-ups or docs. Its Orca model id is unverified; check the model listing before dispatch.
  Of what is queued, only S6 is a candidate.

## Where the phase stands

Phase 4 is the repository format and installer. The plan is
`docs/superpowers/plans/2026-09-11-phase-4-repository-format-installer.md`; **it owns the slice
breakdown, the eleven acceptance criteria and the worker briefs.** #168 tracks slice state and is
current as of this handoff.

| Slice | State |
|---|---|
| D0–S4, #176/#177 | ✅ all merged. S4 = #184, `4648d59`, 2026-09-21 |
| S5 — Settings UI (criterion 10) + declared-age gate | **next; unblocked** |
| S6 — WeebCentral installed rather than compiled (criterion 11) + production transport | **next; unblocked** |

Unit suite on `main`: **1064 / 1059 / 0 / 5** (iPhone 17 Pro, result bundle, on the S4 branch
rebased onto `b51cfca` — identical to what merged). `CLAUDE.md` → "Current state" now describes what
S4 left on `main`.

**S4 review record.** Both handoff-named mutations held: mis-stamping `sourceId` as `"mangadex"`
reddened 5 tests across both classes (incl. `testTheHostStampsTheQualifiedIdAndTheEngineCannotOverrideIt`,
`testAMangaFromTheInstalledSourceRoutesBackToIt`); dropping the `isActive` guard reddened all three
`unavailable` tests. "Without data loss" is asserted directly (listings, pin, history, `.uninstalled`
record, reinstall reconnects). **Gotcha:** the S4 tests are two classes in one file
(`ExtensionSourceTests`, `InstalledSourceRegistrationTests`); `-only-testing:…/ExtensionSourceTests`
runs half of them and made a mutation look weaker than it was.

## What is owed

### 1. S5 and S6 — dispatch as a two-provider wave

Decisions already made by the user (2026-09-16), do not re-ask:
- **Parallel**, not sequenced. Assemble each brief from the plan's preamble + slice section + a
  "what is on main since the plan" block (the plan predates every merge — S2, S3, #183, S4).
- **S5 — Codex `gpt-5.6-luna` medium, iPhone 17 Pro** (`id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691`;
  it needs the seeded fixture for a hermetic UI test). Owns: Settings UI for
  add/refresh/install/update/disable/uninstall/remove (criterion 10); the **declared-age gate** as
  the install sheet for `mixed`/`adultOnly` (ADR-0022 Amendment 2, design §7.1, glossary
  "Declared-age gate") wired through `AdultInstallAcknowledgementHandle.present` (fail-closed until
  set); the "installed Sources could not be read" state (`try store.loadIfNeeded()` is how to
  detect it — #183). Uses the **test fake transport** behind the UI; does **not** write the production
  transport. Takes **#188** (Home rails) if it blocks the UI test, and **#190** if cheap.
- **S6 — Claude if budget remains, otherwise Codex Luna; consider an Astra planning pass first;
  plain iPhone 17** (`id=2A0D54DF-5961-4286-A2B6-F24B4F7537B4`). Owns: the production `URLSession`
  `RepositoryTransport` composed with `RepositoryIndexValidator`, enforcing
  `RepositoryFormatLimits.maximumScriptBytes` (no consumer yet); WeebCentral installed as a package and
  the compiled `WeebCentralSource` removed from `builtInSources()` (criterion 11); **#187** (`webURL`
  → `async`); the stale "S5's to write" comment in `AppComposition.swift` (user decided S6 owns the
  transport). **Must measure** for evidence gate 1 (spec §16, design §10): serialized storage size,
  wall-clock per operation, request counts, actual index/script sizes. Producing the numbers is its
  job; closing the gate is not.

Mechanics: `orca worktree create … --setup skip --no-parent --base-branch main`, then
`cp Secrets.xcconfig <worktree>/` (repo root). `worker-start --spec "$(cat brief.md)" --task-title …
--worktree id:<repo>::<path> --agent codex --model gpt-5.6-luna --effort medium --run
run_9df2075071af --from <live terminal>`.

### 2. S4 findings, filed 2026-09-21

- **#186** — Host API design `{query, page:{cursor,limit}}` vs the engine's flat `cursor`/`limit`.
  **Human decision**: amend the design or migrate the engine, before a second engine exists.
- **#187** — `webURL` async (S6).
- **#188** — Home loads all rails unconditionally; popular-only Source breaks Home (S5/S6).
- **#189** — `source(for:)` falls back to the active source for an uninstalled extension id;
  `needs-triage`: distinguish legacy ids from once-installed ones, or close as intended.
- **#190** — `AppComposition.extensions == nil` on corrupt `extension-storage.json`, silent; #177's
  treatment (agent-ready, small).

### 3. Launch decisions — two left, the user's

- **#150 — the name.** Whether to commission a clearance search. Also gates the privacy-policy URL.
- **App icon.** Brief merged: `docs/design/app-icon-brief.md` (#182). **Send it to a designer.**
  The placeholder (#165) ships until then.

Decided: #149 (`PrivacyInfo.xcprivacy`, #181); `docs/superpowers/research/2026-09-11-issue-149-…`
owns the App Store Connect answers. Still owed from it: the **hosted privacy policy text** (names
MAL, fields, retention, revocation — ADR-0022 Amendment 2 commits to it), blocked on #150 for a URL.

### 4. Device-in-hand items — before launch, date unset

- **Live-verify MAL progress push.** `scripts/mal_live_write.py`;
  `testLiveHorimiyaCompletionPushesProgress` behind `TEST_RUNNER_MAL_LIVE_WRITE=1`.
- **Manual VoiceOver pass, #90.** `./scripts/voiceover-pass.sh`; rows 4.3, 6.5, 7.2, 7.5, 7.6.

### 5. Small debts

- `-uitest-updates-state` seeds `two-listings`. Rename if a third unrelated state appears.
- **Worktrees to remove (all merged):** `phase4-s2-package-parsing`, `phase4-s3-installer`,
  `phase4-s3-followups`, `phase4-s4-extension-source`. Release their Orca terminals
  (`ctx_2c0c2e83031f`, `ctx_8aef3c477b61`).
- PR #185 (the 2026-09-19 handoff) is superseded by this file — close it without merging.

## Dispatch mechanics

Everything in the archived 2026-09-16 and 2026-09-19 handoffs still holds (Claude session-limit
recovery via `orca terminal send`; Codex retries; auto-merge fires; the Codex stop hook dies
cosmetically). Added this pass:
- `gh pr merge --auto --squash` on #183 fired at 12:51 with no intervention. #184 was merged by
  the user directly.

## Supervision protocol

Unchanged. Used on #183 and #184; mutation claims held exactly on both.

1. `git -C <worktree> status` and the terminal preview — the dispatch status lies.
2. Rebase onto `main`; a `project.pbxproj` conflict is keep-both.
3. Full `MangaCartaTests` after the rebase; totals from the result bundle.
4. Review by mutation, not by reading — count clauses, not tests. Run *every* test class the
   slice added.
5. Merge with the user's say-so, and check the PR body names a test *and a mutation* per criterion.

## Repository state

- `main` at **`4648d59`**. Merged since the 09-19 handoff: #183, #184.
- **Open PRs:** #185 (superseded, close), this one.
- Open issues: #168 (tracking), #186–#190 (S4 findings), #150, #90.
- Branch protection requires `Build & unit tests`, `SwiftLint`, `Hermetic UI tests`.
- Orca run `run_9df2075071af`, coordinator `term_a8a4b76b-d9ad-4513-9e10-0531230af89e`.
- `docs/superpowers/handoff/` holds this file and `archive/` (85 archived handoffs plus README).
