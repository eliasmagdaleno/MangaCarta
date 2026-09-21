# Handoff — S5 and S6 are merged; the cutover still needs the user's pick before ADR-0003 A5

Date: 2026-09-21, 14:45 PDT
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

### 1. The cutover fork — the user's pick, asked 2026-09-21 13:0x, still unanswered

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
wire shape for a bundled package), then dispatch the cutover. #192's "Cutover boundary" section
lists exactly what the cutover PR deletes (`WeebCentralSource.swift`, the compiled entry in
`builtInSources()`, the compiled side of `WeebCentralPortTests`/`ExtensionPortHarness`). The
fixture `MangaCartaTests/__Fixtures__/weebcentral/repository-engine.js` is the Swift
`bundleScript` verbatim plus a trailing marker comment — after the cutover it, or the bundled
package, is the only copy.

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
- **Open PRs:** this handoff.
- Open issues: #168 (all slices ticked; close with the cutover), #186, #188, #189, #190, #196,
  #197, #150, #90.
- Orca run `run_e932a373e558`; coordinator `term_59f4a37e-7786-4eed-ad98-199acd1a7284`.
- `docs/superpowers/handoff/` holds this file and `archive/` (87 archived handoffs plus README).
