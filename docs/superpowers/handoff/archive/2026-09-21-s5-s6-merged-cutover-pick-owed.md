# Handoff — S5 and S6 are merged; the cutover still needs the user's pick before ADR-0003 A5

Date: 2026-09-21, 15:00 PDT (updated in place: cutover picked and dispatched)
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-21-s5-s6-merged`, off `main` at `3bca188`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Standing instructions from the user

- **Codex `gpt-5.6-luna` medium for implementation; Claude for review and decisions** (2026-09-19).
  `gpt-5.4` is refused on this account.
- **Astra** (OpenAI frontier Codex model): only for *hard* tasks — have it plan, then fan out to
  subagents. Burns quota. Orca model id unverified. Nothing queued needs it.

## Where the phase stands

Plan: `docs/superpowers/plans/2026-09-11-phase-4-repository-format-installer.md`. #168 tracks state
(D0–S6 all ticked as of this pass).

| Slice | State |
|---|---|
| D0–S6 | ✅ merged; `main` = `3bca188` |
| WeebCentral **cutover** (compiled source out of `builtInSources()`) | **blocked on the user's pick (§1), then ADR-0003 Amendment 5, then a dispatch** |

Unit suite on `main`: 1080 unit + 4 `RepositorySettingsUITests` (1084/1079/0/5 in one bundle on the
Pro). Both PRs were reviewed by mutation this pass — every listed mutation reddened its clause; the
records are in the PR threads' review summaries only, not in a document, which is fine because the
merged tests are the record.

What the review changed before merge (both small, both in the squashes):
- #192: SwiftLint failed CI on two >200-char lines in the budget `print`; wrapped. Deleted
  `UnavailableRepositoryTransport` (zero references once `URLSessionRepositoryTransport` became the
  composition default).
- #193: the age sheet now **always** appears for a `mixed`/`adultOnly` install — a confirmed reader
  sees the Source and class named and gets "Install" instead of the age question (format design
  §7.1 said so; the PR skipped the sheet entirely). Copy is now *"{repository} declares {source} as
  adult-only. Confirm that you are 18 or over to install it."* — the maintainer is named as the
  classifier, and the class is a word, not the enum case. One UI assertion made to wait
  (`testAddedRepositoryCanBeRemoved` reddened once on CI on a bare `.exists`).

## What is owed

### 1. The cutover — picked (bundled package), recorded, **dispatched and in flight**

The user picked **Option 2, a bundled package**, 2026-09-21 14:49. Recorded in ADR-0003
**Amendment 5** (+ ADR-0022 Amendment 3, format design §12, glossary "Bundled package") — #199,
merged. The reader-controls question was answered by the recommendation (stays
disable/uninstall/erase-able; no Remove / Change URL on the bundled repository) and is in A5 part 4.

**Dispatched 2026-09-21 14:58** on S6's retained Codex Luna terminal, so it inherits S6's
context: task `task_0f17ed20f91b`, dispatch `ctx_0da5b1e054a0`, terminal
`term_f73f3658-da00-4053-8f5c-a52bfb2d726b`, run `run_e932a373e558`. Brief:
`docs/superpowers/plans/2026-09-21-phase-4-cutover-brief.md` (nine clauses, each with a mutation
owed; branch `eliasmagdaleno/phase4-cutover-bundled-weebcentral` off `main`). The worker was told
to push a draft PR as soon as the first test is green.

**Owed on completion:** the same review-by-mutation protocol as S5/S6 — re-run clause mutations
yourself, every test class the slice touched; read the migration (clause 6) against every store it
names *and* the ones it says need no rewrite; confirm the bundled index is `none`-class and the
`mixed`/`adultOnly` refusal is tested; confirm exactly one copy of the engine script remains; run the
seeded-fixture proof (clause 9) yourself on the Pro. Then merge with the user's say-so, close #168,
update `CLAUDE.md` "Current state" (the worker owns one sentence there; check it), and release both
Orca workers + remove both worktrees.

### 2. Review findings filed this pass

- **#196** — `URLSessionRepositoryTransport` does no private-destination/DNS or per-hop redirect
  check (format design §2.2 names them). Not blocking for fixture-fed slices.
- **#197** — overlapping adult installs strand the first `CheckedContinuation` in
  `RepositorySettingsViewModel`.
- Not filed, noted: the Settings "Change URL" duplicates the HTTPS check in the view instead of
  calling the view model.

### 3. Findings from S4 still open

#186 (paging request shape — **human decision**), #188 (Home rails unconditional), #189 (registry
fallback after uninstall — triage), #190 (silent nil on corrupt extension storage). #187 closed with
#192.

### 4. Launch decisions — the user's

- **#150** — the name; gates the hosted privacy-policy URL (text still owed; names MAL, fields,
  retention, revocation).
- **App icon** — send `docs/design/app-icon-brief.md` to a designer. Placeholder ships until then.

### 5. Device-in-hand items — before launch, date unset

MAL live-write verify (`scripts/mal_live_write.py`; `TEST_RUNNER_MAL_LIVE_WRITE=1`); VoiceOver
pass #90 (`./scripts/voiceover-pass.sh`).

### 6. Small debts

- `-uitest-updates-state` seeds `two-listings`; rename if a third state appears.
- **Orca cleanup not done yet:** both worktrees (`~/orca/workspaces/Manga-Reader/phase4-s5-settings-ui`,
  `…/phase4-s6-weebcentral-installed`) and both retained worker terminals (S5 `ctx_435126adbaeb`
  on `term_78afb03f-…`, S6 `ctx_f9d5354a34b0` on `term_f73f3658-…`, run `run_e932a373e558`) are
  still live. S6's was kept for the cutover dispatch; if the cutover goes to a fresh worktree
  instead, `orca worktree rm` both and `worker-release` both. The merged branches cannot be deleted
  locally until the worktrees go.
- Evidence gate 1 now has S6's numbers (`docs/superpowers/research/2026-09-21-phase-4-s6-budget-
  measurements.md`); closing the gate is still unowned.

## Dispatch mechanics learned (carried)

- **A closed coordinator terminal makes the inbox silently unreadable** (`check` errors "no
  stable pane identity"; `worker-start` refuses). Fix: `run-use --id <run> --from <live terminal>`.
- **`check` without `--ack` replays the same delivery forever.**
- **`--only-testing:<Target>/<Class>` runs one class; a file can hold several.** List every class
  a slice added before trusting a mutation's silence.
- **Luna stops honestly.** A continuation dispatch on the *same terminal* finishes a
  `worker_done --outcome failed`. Tell continuations to commit first.
- **SwiftLint is a CI gate the workers do not run.** Both S5/S6 PRs were pushed with lint never
  having run locally; #192 was red on line length. `swiftlint lint --quiet <files>` before pushing.
- **CI's UI job is slower than the Pro; a bare `.exists` right after an async action is a race.**
  Use `waitForExistence`.

## Supervision protocol

Unchanged. 1) worktree `status` + terminal preview; 2) rebase, pbxproj keep-both; 3) full suite,
result-bundle totals; 4) review by mutation, every class; 5) merge with the user's say-so.

## Repository state

- `main` at **`3bca188`**. Merged this pass: #192, #193.
- **Open PRs:** none at write time; the cutover PR is expected from the dispatch above.
- Open issues: #168 (all slices ticked; close with the cutover), #186, #188, #189, #190, #196,
  #197, #150, #90.
- Orca run `run_e932a373e558`; coordinator `term_59f4a37e-7786-4eed-ad98-199acd1a7284`.
- `docs/superpowers/handoff/` holds this file and `archive/` (87 archived handoffs plus README).
