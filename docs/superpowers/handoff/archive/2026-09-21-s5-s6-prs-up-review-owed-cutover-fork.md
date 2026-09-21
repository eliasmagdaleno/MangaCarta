# Handoff — S5 (#193) and S6 (#192) are up and unreviewed; the cutover needs the user's pick before ADR-0003 A5

Date: 2026-09-21, 13:50 PDT
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-21-s5-s6-prs-up`, off `main` at `e701236`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Standing instructions from the user

- **Codex `gpt-5.6-luna` medium for implementation; Claude for review and decisions** (2026-09-19).
  `gpt-5.4` is refused on this account.
- **Astra** (OpenAI frontier Codex model): only for *hard* tasks — have it plan, then fan out to
  subagents. Burns quota. Orca model id unverified. Nothing queued needs it.

## Where the phase stands

Plan: `docs/superpowers/plans/2026-09-11-phase-4-repository-format-installer.md` (owns slices,
criteria, briefs). #168 tracks state (D0–S4 ticked).

| Slice | State |
|---|---|
| D0–S4, #176/#177 | ✅ merged; `main` = `e701236` |
| S5 Settings UI + declared-age gate (criterion 10) | **PR #193 open, unreviewed** |
| S6 WeebCentral installed + production transport + budgets (criterion 11, #187) | **PR #192 open, unreviewed** |
| WeebCentral **cutover** (compiled source out of `builtInSources()`) | **blocked on the user's pick (§2), then ADR-0003 Amendment 5, then a follow-up dispatch** |

Unit suite on `main`: 1064/1059/0/5. #192 claims 1070/1065/0/5 on plain 17; #193 claims
1074/1069/0/5 on the Pro. **Both touch `AppComposition.swift`**, so whichever merges second needs a
rebase and a re-run.

## What is owed

### 1. Review #192 and #193 by the protocol, then merge with the user's say-so

Both workers ran on Codex Luna medium in `run_e932a373e558` (coordinator terminal now
`term_59f4a37e-7786-4eed-ad98-199acd1a7284` — a plain "Terminal 1" in the S5 worktree; the original
one was closed and had to be rebound with `run-use --id … --from …`). Both dispatches settled
`completed` and their terminals are **retained** (`worker-retain`) for follow-ups:
S5 `ctx_435126adbaeb` on `term_78afb03f-f0ad-4a0f-a73a-b306941880bd`, S6 `ctx_f9d5354a34b0` on
`term_f73f3658-da00-4053-8f5c-a52bfb2d726b`. Release them when the PRs merge.

Worktrees: `~/orca/workspaces/Manga-Reader/phase4-s5-settings-ui` (2 commits) and
`…/phase4-s6-weebcentral-installed` (1 commit), both clean, both off `4648d59`.

**Suggested order: #192 first** (smaller blast radius on the app; it also changes the `MangaSource`
protocol — `webURL(forManga:)` is now `async throws` — which #193 does not depend on). Then rebase
#193 and re-run.

Mutations worth re-running yourself (count clauses, not tests; run *every* test class the slice
added — the S4 lesson):
- **#192:** (a) substitute `HTMLSelectorThemeEngine.bundleScript` for the package bytes in
  `ExtensionSource.init` → `testInstalledPackageRunsWeebCentralAgainstPinnedPortFixtures` must
  redden on the byte-equality clause; (b) `<=` → `<` in the transport's script-size check →
  `testScriptAtLimitIsAcceptedAndOneByteOverIsRefused`; (c) bypass `RepositoryIndexValidator` in
  `fetchIndex` → `testIndexIsParsedAndValidatedBeforeReturning`. Also check the PR's claim that
  the production transport is the composition default and that `UnavailableRepositoryTransport`
  is no longer reachable in production; and read the redirect handling ("returns permanent
  redirects for explicit confirmation") against format design §6.6 — the brief did not ask for it.
- **#193:** (a) force the age-answer continuation to `true` →
  `testDecliningAgeGateReturnsFalseWithoutPersistingConfirmation` and the UI decline test; (b)
  return only the adult-registration condition →
  `testAdultToggleRequiresBothAgeConfirmationAndRegisteredAdultSource`; (c) drop the HTTPS scheme
  check → the two bad-URL tests. **Read the gate copy yourself** against ADR-0022 A2 ("must not
  imply developer moderation") — a test asserting the absence of one word is not that. Confirm
  the fixture transport lives behind a `-uitest-…` launch argument and cannot be reached in a
  production launch. `ci.yml` gains `RepositorySettingsUITests` — check it is in the
  `-only-testing` list, not a new job.

Full suite after each rebase, totals from the result bundle, on the Pro
(`id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691`).

### 2. The cutover fork — the user's pick, asked 2026-09-21 13:0x, unanswered

The user asked for "ADR-0003 Amendment 5 and widen S6 to the cutover". Drafting stalled on a real
fork, put to the user in prose:

- Compiled WeebCentral's id is the bare `"weebcentral"`; an installed Source's id is
  `<repo-uuid>:weebcentral` (format design §5.2; the id spaces deliberately cannot collide). So
  the cutover changes WeebCentral's identity and needs a one-time migration of every Listing,
  history entry and pin stamped `"weebcentral"` — including the seeded simulator fixture's
  `works.json`.
- **Option 1 — ship nothing; the reader installs WeebCentral from a repository they add.**
  Cleanest against ADR-0003 A4 (no default repository) and ADR-0022 A2's Review defence; reverses
  ADR-0022's "the public release ships MangaDex and WeebCentral"; nothing to migrate *to*.
- **Option 2 (recommended) — a bundled package.** The app bundle carries the WeebCentral
  index + script + declaration, installs it at first launch under a fixed app-owned repository
  UUID, updates only with app updates; no network repository, no URL. Product unchanged; Review
  sees what it sees today (a `none`-class source). The amendment must say explicitly that A2's
  "shipping a default repository reopens this" is about a *network* repository offering adult
  Sources. Cost: the deterministic id migration + re-seeding the fixture.
- Either way: say whether WeebCentral stays disable/uninstall/erase-able once installed (I'd say
  yes — it is a Source like any other; the app just re-offers it).

**Once picked:** write ADR-0003 Amendment 5 (owner of the decision; the format design owns any new
wire shape for a bundled package), then dispatch the cutover as a follow-up on S6's retained
terminal after #192 merges. #192's "Cutover boundary" section lists exactly what the cutover PR
deletes. Do **not** fold the cutover into #192.

### 3. Findings from S4 still open

#186 (paging request shape — **human decision**), #188 (Home rails unconditional), #189 (registry
fallback after uninstall — triage), #190 (silent nil on corrupt extension storage). #187 closes with
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
- After both PRs merge: `orca worktree rm` both worktrees; `worker-release` both dispatches.
- Evidence gate 1 now has S6's numbers (`docs/superpowers/research/2026-09-21-phase-4-s6-budget-
  measurements.md`); closing the gate is still unowned.

## Dispatch mechanics learned this pass

- **A closed coordinator terminal makes the inbox silently unreadable** (`check` errors "no
  stable pane identity"; `worker-start` refuses). Fix: `run-use --id <run> --from <live terminal>`.
  Bind the run to a terminal that will outlive the session, not whatever happens to be open.
- **`check` without `--ack` replays the same delivery forever.** A poll loop must ack
  heartbeat-only deliveries or it reports the same heartbeat every minute.
- **`--only-testing:<Target>/<Class>` runs one class; a file can hold several.** List every class
  a slice added before trusting a mutation's silence.
- **Luna stops honestly.** S5 sent `worker_done --outcome failed` at 17 min with working code
  uncommitted and no PR because its evidence table was incomplete. A continuation dispatch on the
  *same terminal* (`worker-start --spec … --terminal <handle> --worktree id:…`) finished it in
  22 min. Tell continuations to commit first.
- The Codex stop hook still dies cosmetically ("invalid stop hook JSON output").

## Supervision protocol

Unchanged. 1) worktree `status` + terminal preview; 2) rebase, pbxproj keep-both; 3) full suite,
result-bundle totals; 4) review by mutation, every class; 5) merge with the user's say-so.

## Repository state

- `main` at **`e701236`**. Merged this pass: #183, #184, #191.
- **Open PRs:** #192 (S6), #193 (S5), this handoff.
- Open issues: #168, #186, #188, #189, #190, #150, #90. #187 closes with #192.
- Orca run `run_e932a373e558`; coordinator `term_59f4a37e-7786-4eed-ad98-199acd1a7284`.
- `docs/superpowers/handoff/` holds this file and `archive/` (86 archived handoffs plus README).
