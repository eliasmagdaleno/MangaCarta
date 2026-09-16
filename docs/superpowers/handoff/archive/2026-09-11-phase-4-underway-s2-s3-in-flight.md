# Handoff — Phase 4 is underway: design landed, S1 merged, S2 and S3 in flight

Date: 2026-09-11 (later the same day as the handoff this supersedes)
Repository: `/Users/eliasmagdaleno/Manga-Reader` (directory unchanged; GitHub is
`eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-11-phase-4`, off `main`.

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
| D0 | Repository format design + the decisions the phase could not start without | ✅ **merged `9f70750`** (#169) |
| S1 | Host capability bridge — `host.http`, `host.storage`, `host.log` | ✅ **merged `4de2f43`** (#170, closed #164) |
| S2 | Package parsing + validation (criteria 1, 2-parsing) | **PR #173 open, unreviewed** |
| S3 | `RepositoryStore` + installer pipeline (criteria 2-registry, 3, 4, 5, 6) | **in flight** |
| S4 | `ExtensionSource: MangaSource` + dynamic registration (criteria 8, 9) | not started — **unblocked** |
| S5 | Settings UI (criterion 10) | not started, needs S3 |
| S6 | WeebCentral installed rather than compiled (criterion 11) | not started, needs S3 + S4 |

Unit suite on `main`: **994 total, 989 passed, 0 failed, 5 skipped.** SwiftLint clean.

### The gap the plan found that no previous handoff recorded

**There is no `MangaSource` adapter over `ExtensionRuntime`.** `ExtensionRuntime(` is constructed
**only in `MangaCartaTests`**, and `SourceRegistry.builtInSources()` returns a hard-coded
`[MangaDexSource(), WeebCentralSource(...)]`. A perfect format and a perfect installer still change
nothing a reader can see until **S4** exists. It is a first-class slice, not a footnote about
"cutting over", and it is unblocked now that S1 bridged the capabilities.

### What D0 decided — read the amendments, not this summary

**ADR-0003 Amendment 4** (note: *four* — `main` already had three; the plan said "Amendment 3" and
was wrong) closes Host API design **evidence gates 3 and 4**, decides **#161**, and places signing:

- **Identity is installer-minted** — a UUID at first add, bound to the URL it came from, shown as
  that URL. **The reader's gesture is the only thing distinguishing a move from a replacement**, and
  in format 1 that is sufficient. Migration to key-based identity is named, not implied.
- **The maintainer attests, the reader trusts, and there is no "approved" status in v1** because no
  authority exists to grant it. An under-classified Source is **elevated locally by the reader**;
  the design's "disabled pending corrected metadata" assumed a reviewer this project does not have.
- **#161: a `SourceDeclaration` exists only as the validator's output.** `reinstall` keeps its typed
  parameter; the memberwise initialiser becomes inaccessible outside `SourceDeclarationValidator`.
  Making `reinstall` take raw JSON was rejected — the registry would need the qualified id and the
  host's supported versions, which are the *installer's* inputs. A consequence worth knowing: **a
  stored declaration is raw JSON re-validated at every launch**, so a tightened validator refuses a
  Source with a sentence instead of running it under rules it was never checked against.
- **Signing deferred to format 2**, with the seams (`scriptSHA256`, `boundKey`) already in place.
  **Signing protects updates, not first install** — without a curated key list, first install is
  trust-on-first-use either way.

**ADR-0022 Amendment 1**: a reader-installed adult Source **is** reachable, behind the existing
default-off gate, with a one-time acknowledgement at install. Both product calls were the user's and
the user chose the recommended branch on each.

## What is owed

### 1. The two workers in flight — supervise, do not assume

**S2 — finished, and its PR is #173, open and awaiting review.** `phase4-s2-package-parsing`,
Codex `gpt-5.6-luna` high, commit `5f4ffd6`, rebased and containing `origin/main`. 611 insertions,
no deletions, three files. Reports **1006 total, 1001 passed, 0 failed, 5 skipped** on the iPhone 17
Pro — the baseline plus exactly its 12 new tests — with 11 tests for criterion 1 and three
mutations.

**What was checked, and what was not.** Static review confirms the two things that mattered:
declaration validation delegates to `SourceDeclarationValidator` from the raw `JSONValue` and never
constructs a `SourceDeclaration` (so it is compatible with S3's #161 change), and duplicate
`localId` errors name **both** occurrences, which is what criterion 4 leans on. **An independent
re-run of one of its mutations was deliberately not done** — S3 was mid-`xcodebuild` and a second
build produces the wedge that looks like a real failure. **Do that before merging**; the
cross-bundle `localId` duplicate branch is the one worth picking.

**Its worker then died on the same stop-hook failure as S1** (`Worked for 26m 55s`), *after* the PR
was open and pushed. Benign — it cost only the `worker_done` message.

**S3 — still running at the time of writing.** `phase4-s3-installer`, Claude `claude-opus-5` high,
terminal `term_e9ac50f7-9ba1-461d-93b5-6b1571289f9a`. One commit, `0e06ee1`, doing the #161
type-level change first — right, because it ripples through every test that hand-builds a
declaration. Last seen running its own mutation checks against `ExtensionInstallerTests` on the
iPhone 17 (`mut-c3f`, `mut-c4a` — it is working clause by clause, which is what was asked).

**Nothing is watching it any more.** The session monitor that was watching both workers died with
its session. A fresh session should re-establish one, or check by hand:
`orca orchestration check --terminal term_15c0eb64-b03c-4606-add4-e337286e7ea7 --types
worker_done,escalation,question`, the worktree's `git status -sb`, and — the part `check` cannot
tell you — the terminal preview.

**A deliberate exception is running right now, and it is not the repository convention.** Both are
code slices that need to run tests, so serializing one of them would have made TDD impossible for it.
**S2 has the iPhone 17 Pro; S3 was given the plain iPhone 17** and told: unit tests only, no UI
tests (that device has no seeded fixture), report which device its totals came from, and expect its
conventional full-bundle run to happen at review. **If S3's PR reports totals without naming the
device, that is the thing to check first.**

**A collision was caught and fixed mid-flight:** both workers created
`MangaCarta/Models/RepositoryIndex.swift`. S2 owns that path; S3 moved its seam to
`RepositoryIndexSeam.swift`. Their *designs* agreed independently — index-level validation is S2's,
declaration-level validation under the minted qualified id is S3's, because the qualified id is the
installer's input and nothing else has one. **Integration should be deleting S3's seam and importing
S2's types, not renaming call sites.** Verify that at rebase.

### 2. Phase 4's remaining slices

S4, then S5 and S6. Briefs are in the plan, written to be pasted whole. S4 is the one that makes
installation mean anything.

### 3. The launch decisions — now four, none of them features

- **#149 — MAL privacy label. The shipped manifest is wrong today** (empty
  `NSPrivacyCollectedDataTypes`); the recommendation is Name, User ID, Product Interaction. Decide,
  then change the manifest and the App Store answers together.
- **#150 — the name.** Decide whether to commission a ~$1,000–$2,000 clearance search before launch.
- **#171 — NEW, opened today. The App Review posture for installable adult Sources.** ADR-0022
  Amendment 1 decided the app *allows* them; what nobody has decided is what we tell App Review.
  The citations if Review reads this as an unmoderated browser for adult content are **1.1.4** and
  **1.2**. The honest note in the amendment: that is the posture Paperback and Aidoku take, and
  **neither is on the App Store**. Refusing later is a one-line installer change; refusing now
  cannot be undone without an app update.
- **No real app icon.** Eleven handoffs. Still outsourced, still order it early, still needs the
  *MangaCarta* name on it. The placeholder (#165) is not progress against this — **replace that
  file, do not refine it.**

### 4. Live-verify MAL progress push — the user's to run

Built, wired, tested. What no unit test shows: sign in on a device, read a chapter to the end,
confirm the number moves on myanimelist.net. `scripts/mal_live_write.py` isolates the API path.
`testLiveHorimiyaCompletionPushesProgress` is gated behind `TEST_RUNNER_MAL_LIVE_WRITE=1`.

### 5. The manual VoiceOver pass — #90, the user's to run

Open, `ready-for-human`, **no row has a verdict yet** and no results file in `docs/accessibility/`.
`./scripts/voiceover-pass.sh` parses the checklist at runtime, takes pass/fail/skip per row, writes
`docs/accessibility/voiceover-results-<date>.md`, and resumes. **Needs a real iPhone** — simulator
VoiceOver differs on the rotor and focus restoration, which is most of what these rows test. Rows
most needing eyes: **4.3, 6.5, 7.2, 7.5, 7.6**. Section 8's two expected passes are **not closed**:
a trait being present is not VoiceOver speaking it. Close #90 when every row has a verdict, **not**
when every defect is fixed.

Items 4 and 5 both want a device in hand; one sitting is worth more than two.

### 6. Evidence gate 1 — budgets — still open, still unowned

Spec §16. The corpus is thin and every additional engine makes it more representative and the gate
no cheaper. **S6 should measure** — serialized storage size, wall-clock per operation, request counts
— even though closing the gate is not its job. Measuring nothing was Phase 3 S6's one real gap.
D0 left the storage quota to this corpus deliberately rather than picking a number.

### 7. Naming debt, small and deliberate

`-uitest-updates-state` seeds a fixture that has nothing to do with updates (`two-listings`). Rename
it if a third unrelated state appears.

## Dispatch mechanics

Everything in the previous handoff still holds. What today added:

- **A Codex worker can end its turn on a stop-hook failure and go idle without escalating. This is
  reproducible, not a one-off — it has now happened to both Codex workers dispatched today**, S1 and
  S2, at 17m and 27m respectively. **It is worth diagnosing at the source**: the hook is Orca's own
  global agent hook in `~/.claude/settings.json`, the repository has no `.claude/settings.json`, and
  it appears to return invalid JSON when Codex rather than Claude reads its output. Until then,
  every Codex dispatch here will hit it. S1 did:
  the preview read `Hook failed / hook returned invalid stop hook JSON output` after `Worked for
  17m 10s`, its commit was intact, and **`orca orchestration check` reported nothing** — a hook
  killing a turn is not an escalation. Cost ~25 minutes of assuming it was still working. The hook is
  Orca's own global agent hook in `~/.claude/settings.json`; the repo has no `.claude/settings.json`.
  **Worth fixing at the source, since every future Codex worker here will hit it.**
- **So watch the terminal preview, not just `check`.** The session monitor now also greps previews
  for `hook failed`, `invalid stop hook`, `agent_prompt_blocked`, `hooks need review`, and session
  or rate limits.
- **Recovery is just `orca terminal send`** with a "your turn ended on a hook failure, your commits
  are intact, carry on" message plus the remaining steps. S1 opened its PR two minutes later.
- **`orca terminal send` can warn `input was accepted but no turn start was observed`.** If the agent
  was mid-turn, the input is *queued*, not lost — S3's rename landed within a minute. Do not resend
  blind; check whether the instruction took effect.
- **Two code slices can run in parallel by giving one a different simulator device**, at the cost of
  the second not having the seeded fixture. Say so in the brief, in as many words, and bound it to
  unit tests. **But the isolation is partial, and the claim made when this was set up was too
  strong.** S2 reported two full-scheme attempts hitting the `DebuggerLLDB.DebuggerVersionStore`
  wedge after its unit tests while its unit-target bundle completed cleanly — the CoreSimulator
  service is shared even when the devices are not. The split still let both workers do TDD, which was
  the point; it is not clean isolation, and **a reviewer should still not build while a worker is
  building.**
- **Watch for two workers creating the same file.** Cheap to catch with
  `git -C <worktree> status --porcelain` on each; expensive at rebase.
- **`gh pr merge` and the GitHub MCP merge are both blocked by auto mode's classifier.** The user
  merges, or authorizes it explicitly. A PR that looks merged may not be — check `mergedAt` and
  `origin/main`, not the GitHub UI's two-step flow.
- Command spellings, `--from` requirements, provider-split rules, and worktree preparation are
  unchanged — see the archived handoff `2026-09-11-phase-3-done-phase-4-is-next.md`.

## Supervision protocol

Unchanged, and it earned its place again today.

1. `git -C <worktree> status` and the terminal preview — **the dispatch status lies.**
2. Rebase onto `main`; expect a `project.pbxproj` conflict if a peer landed first — resolution is
   **keep-both**.
3. Re-run the **full** `MangaCartaTests` bundle after the rebase; totals from the result bundle.
4. **Review by mutation, not by reading** — and **count clauses, not tests.**
5. Only then merge, and check the PR body names a test *and a mutation* per criterion it claims.

**Re-run one of the worker's own mutations yourself.** Done on S1: setting the shared
`error.code.rawValue` assignment to a literal made
`testEachCapabilityPreservesHostErrorCodesAcrossTheEngineBoundary` fail, which is what established
the clause was load-bearing rather than decorative. It cost one targeted `xcodebuild` run.

**Check what a refactor did *not* touch.** S1's strongest evidence was that its diff to
`HostCapabilityTests.swift` deletes zero lines — `HostBrowserJSCapability` shrank by 111 lines onto
a shared path with its tests untouched.

## Gotchas

The archived handoff's list stands in full; re-verify any that becomes load-bearing. Added today:

- **A PR body's totals are not CI's.** #170 reported 994/989/0/5 and CI agreed — but CI is what
  gates, and `Build & unit tests` took 6m38s while `Hermetic UI tests` took 8m6s. A code change is
  ~12 minutes end to end; the docs-only fast path is 2–6 seconds and is confirmed working again.
- **A plan can be wrong about the repository and a worker should check.** The Phase 4 plan said
  "ADR-0003 Amendment 3"; `main` already had three amendments. D0 numbered it 4 and was right.
- **`gh issue close` on an already-closed issue is a no-op with a `!` warning**, not a failure — a
  PR body's `Closes #N` will have done it already.

## Repository state

- `main` at **`4de2f43`**. Merged today: **#167** (Phase 4 plan), **#169** (D0 design + two ADR
  amendments), **#170** (S1 capability bridge).
- **No open PRs.**
- Open issues: **#168** (Phase 4 tracking), **#171** (App Review posture — new), **#149**, **#150**
  (both researched, decisions owed), **#90** (VoiceOver, ready-for-human). **#161 and #164 closed
  today.**
- **Branch protection requires three checks:** `Build & unit tests`, `SwiftLint`,
  `Hermetic UI tests`.
- **Worktrees: four.** The main checkout; `Manga-Reader-worktree-helper` (unrelated, from
  2026-08-21); and the two in-flight slice worktrees, `phase4-s2-package-parsing` and
  `phase4-s3-installer`. **The two slice worktrees are live work — do not clean them up.**
- **Orca run `run_a28b59b9c029`**, coordinator `term_15c0eb64-b03c-4606-add4-e337286e7ea7` —
  **record it**, every orchestration command needs it after a runtime restart.
- The remote branch `docs/phase-4-plan` still exists post-merge (merged via the MCP tool, which has
  no delete-branch option). Harmless; no worktree holds it.
- `docs/superpowers/handoff/` holds this file and `archive/` (80 archived handoffs plus its README).
  Two `.md` files at this level means someone skipped the rule.
