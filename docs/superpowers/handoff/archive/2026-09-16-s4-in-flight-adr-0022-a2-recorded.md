# Handoff — S4 in flight, ADR-0022 Amendment 2 recorded, three launch decisions left

Date: 2026-09-16, 16:40 PDT (supersedes the same day's 16:20 handoff)
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-16-evening`, off `main` at `50aa355`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Where the phase stands

Phase 4 is the repository format and installer. The plan is
`docs/superpowers/plans/2026-09-11-phase-4-repository-format-installer.md`; **it owns the slice
breakdown, the eleven acceptance criteria and the worker briefs.** #168 tracks slice state.

| Slice | What | State |
|---|---|---|
| D0, S1, S2, S3 | design, host bridge, parser, installer | ✅ all merged; S2 `425154f` (#173), S3 `4dc56dc` (#175), both 2026-09-16 |
| S4 | `ExtensionSource: MangaSource` + dynamic registration (criteria 8, 9) | **in flight — see §1** |
| S5 | Settings UI (criterion 10) — **now carries the declared-age gate** | not started, needs S4 |
| S6 | WeebCentral installed rather than compiled (criterion 11) | not started, needs S4 |

Unit suite on `main`: **1034 total, 1029 passed, 0 failed, 5 skipped** (iPhone 17 Pro, result
bundle). CI green on every merge today.

`CLAUDE.md` → "Current state" says what S2/S3 left on `main` and that none of it is reachable from
the app until S4. The archived 16:20 handoff has the per-file inventory (`RepositoryTransport` has
no production conformer; `maximumScriptBytes` has no consumer) — still true, and S4's brief carries
both.

## What is owed

### 1. S4 — dispatched 16:20 PDT, mid-mutation pass at 16:40. Supervise it.

Claude `claude-opus-5` high, worktree `~/orca/workspaces/Manga-Reader/phase4-s4-extension-source`,
branch `eliasmagdaleno/phase4-s4-extension-source` off `4dc56dc`. **Orca run `run_9df2075071af`**,
coordinator `term_a8a4b76b-d9ad-4513-9e10-0531230af89e`, task `task_cef7b617642a`, dispatch
`ctx_2c0c2e83031f`, agent terminal `term_173f94dd-a2e8-4626-8ec8-85bf77fb016a`. It has the
iPhone 17 Pro.

**At 16:40 it had one checkpoint commit, `0d7570b` "wip: S4 ExtensionSource and dynamic
registration (checkpoint before mutation pass)"** — 8 files, +1331/−8: `Models/ExtensionSource.swift`
(370), `Services/ExtensionSourceRegistrar.swift` (116, still being edited), `AppComposition.swift`
(+83), `SourceRegistry.swift`, `SourceLifecycleRegistry.swift` (+11), `MangaCartaApp.swift` (+4),
`MangaCartaTests/ExtensionSourceTests.swift` (717), and the pbxproj entries for it. Preview showed it
working, no questions in the inbox. Twenty minutes from dispatch to a full checkpoint is fast;
**the mutation pass is where the evidence is, so do not review the checkpoint.**

Its brief is the plan's S4 section under the shared preamble (plan's "Amendment 3" corrected to
4), plus: the launch wiring is its job; no production `RepositoryTransport` needed for 8/9;
**#176 and #177 stay out of it**; installed Sources are *added* to `builtInSources()`, never
substituted; baseline 1034/1029/0/5. **It does not know about ADR-0022 Amendment 2** (decided after
dispatch) — that is fine, the gate is S5's, and nothing in S4's scope touches the install sheet.

Check: `orca orchestration check --terminal term_a8a4b76b-d9ad-4513-9e10-0531230af89e --types
worker_done,escalation,question --json`; the worktree's `git status -sb` and
`git log --oneline origin/main..HEAD`; the agent terminal's preview from `orca terminal list --json`,
grepped for `hook failed`, `invalid stop hook`, `agent_prompt_blocked`, `hooks need review`, rate or
session limits; `gh pr list --head eliasmagdaleno/phase4-s4-extension-source`.

**Review it by the protocol below.** The mutations worth re-running yourself: whichever one proves
`sourceId` is stamped with the qualified id on *every* conversion path (criterion 8's last clause —
the MangaDex rule `toManga` follows), and whichever one proves uninstall degrades an open Listing to
unavailable *without data loss* (criterion 9). Also check what the diff to `SourceRegistry.swift`
did **not** do: `SourceRegistry.shared` must still be only the production default, and no view or
view model may read it — the 2026-09-02 bug.

After merge: S5 and S6 both unblock. They are independent of each other and can run as a
two-provider wave (S5 Codex on the plain iPhone 17, unit tests only — but S5 *is* the UI slice and
needs a hermetic UI test, which needs the seeded Pro; so give **S5 the Pro and S6 the plain 17**).

### 2. Three launch decisions left — the user's

#171 is **decided and closed** today (ADR-0022 Amendment 2, PR #179, `50aa355`). Remaining:

- **#149 — MAL privacy label.** The shipped manifest is wrong today (empty
  `NSPrivacyCollectedDataTypes`); recommendation is Name, User ID, Product Interaction. Amendment 2
  also commits the privacy *policy* to naming MAL, the fields, retention and revocation — same pass.
- **#150 — the name.** Whether to commission a clearance search before launch.
- **No real app icon.** Thirteen handoffs. Outsource it, order it early, *MangaCarta* on it.
  The placeholder (#165) is not progress — replace the file, do not refine it.

### 3. What Amendment 2 decided, so nobody re-derives it

Read the amendment, not this. In one line each: submit with reader-installed adult Sources
reachable; the install sheet is a **declared-age gate** (18+, once per device, stored beside and
cleared with the adult-sources preference, toggle hidden until confirmed); the fitting guideline is
**4.7**, not 1.2, and "software *offered in* your app" is why a build with no default repository is
defensible — **shipping a default repository reopens the amendment**; Paperback *is* on the App
Store (16+, "Komga client … scripting API"), Aidoku is not — Amendment 1's premise was wrong and is
corrected there. The four App Store answers (age rating, description register, review notes,
privacy policy) are decided in the amendment; fill the listing from it.

### 4. Two S3 follow-ups — #176, #177

Both `ready-for-agent`, both small, both orthogonal to S4. #176: `transition`/`removeRepository`
move the registry before persisting, the reverse of the installer's header contract. #177: a
corrupt `repositories.json` decodes to an empty snapshot and the next commit overwrites it. Could go
to a cheap Codex worker now on the plain iPhone 17, or after S4 to avoid a small `AppComposition`
rebase. **Not dispatched; the user was asked and did not choose.**

### 5. Device-in-hand items — the user's, one sitting for both

- **Live-verify MAL progress push.** `scripts/mal_live_write.py`;
  `testLiveHorimiyaCompletionPushesProgress` behind `TEST_RUNNER_MAL_LIVE_WRITE=1`.
- **Manual VoiceOver pass, #90.** `./scripts/voiceover-pass.sh`; real iPhone; rows 4.3, 6.5, 7.2,
  7.5, 7.6 most need eyes. Close when every row has a verdict.

### 6. Evidence gate 1 — budgets — S6 measures

Serialized storage size, wall-clock per operation, request counts, actual index/script sizes.
Spec §16, design §10. S6's brief should say so in as many words.

### 7. Naming debt, small

`-uitest-updates-state` seeds `two-listings`. Rename if a third unrelated state appears.

## Dispatch mechanics

The archived `2026-09-11-phase-4-underway-s2-s3-in-flight.md` and `2026-09-11-phase-3-done…` hold
the full list (Codex stop-hook death and `orca terminal send` recovery; watch the preview not just
`check`; a second simulator device is partial isolation; pbxproj conflicts are keep-both; command
spellings). Today added:

- **`run-create` needs `--from <live terminal handle>`** from outside an Orca terminal, and the
  old coordinator terminal was gone, so `run_a28b59b9c029` is dead. Any live terminal serves as
  coordinator — `term_a8a4b76b…` is a plain "Terminal 1" in the S2 worktree.
- **`worker-start --spec "$(cat brief.md)" --task-title … --worktree id:<repo>::<path> --agent
  claude --model claude-opus-5 --effort high`** worked first time; the brief was assembled from the
  plan's preamble + slice section + a "what is on main since the plan" block. Assemble it that way
  again for S5/S6 — the plan predates every merge.
- **`orca worktree create … --setup skip --no-parent`, then `cp Secrets.xcconfig <worktree>/`.**
  It is at the repo root, not under `MangaCarta/`.
- **The GitHub UI merge did not take, twice.** `gh pr view --json state,mergedAt` is the truth;
  `gh pr merge <n> --squash` with the user's explicit say-so worked every time (four merges today).
- **`-destination name='iPhone 17 Pro'` failed to resolve** from this session's shell; `id=ADDAB2F8-
  38C7-4D44-97EA-4E98281CF691` worked. Undiagnosed. Briefs now carry both forms.
- **Xcode churn in the main checkout** — 114 pbxproj lines and a reordered `Info.plist` with
  nothing behind them — was discarded with `git checkout --` before pulling. Check before every
  `git add`.
- **A self-paced wake-up loop** (`ScheduleWakeup`, ~20 min) was the monitor for S4 this session.
  It dies with the session; a fresh session re-establishes it or checks by hand.

## Supervision protocol

Unchanged. Used twice today; both PRs' mutation claims held exactly.

1. `git -C <worktree> status` and the terminal preview — the dispatch status lies.
2. Rebase onto `main`; a `project.pbxproj` conflict is keep-both.
3. Full `MangaCartaTests` after the rebase; totals from the result bundle.
4. Review by mutation, not by reading — count clauses, not tests.
5. Merge, and check the PR body names a test *and a mutation* per criterion.

## Repository state

- `main` at **`50aa355`**. Merged today: #173 (S2), #175 (S3), #178 (handoff), #179 (ADR-0022 A2).
- **No open PRs.**
- Open issues: **#168** (Phase 4 tracking), **#176**, **#177** (S3 follow-ups), **#149**, **#150**
  (decisions owed), **#90** (VoiceOver, ready-for-human). **#171 closed today.**
- Branch protection requires `Build & unit tests`, `SwiftLint`, `Hermetic UI tests`.
- **Worktrees: five.** Main checkout; `Manga-Reader-worktree-helper` (unrelated);
  `phase4-s2-package-parsing` and `phase4-s3-installer` (**merged, safe to remove, not removed**);
  `phase4-s4-extension-source` (**live — do not touch**).
- Orca run **`run_9df2075071af`** (S4), coordinator `term_a8a4b76b-d9ad-4513-9e10-0531230af89e`.
- `docs/superpowers/handoff/` holds this file and `archive/` (82 archived handoffs plus README).
