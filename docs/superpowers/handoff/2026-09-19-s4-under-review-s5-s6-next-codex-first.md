# Handoff — S4 under review (#184), #183 merging, S5/S6 next; delegate to Codex first

Date: 2026-09-19, 12:40 PDT
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-19`, off `main` at `9a1b7bf`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Standing instruction from the user (2026-09-19)

**Delegate implementation to Codex workers by default; spend Claude on review and decisions.** The
user is halfway through their Claude usage. Codex model that works with this account:
**`gpt-5.6-luna`** (`--effort medium`). `gpt-5.4` is refused ("not supported when using Codex with a
ChatGPT account") — the worker sits at a 400 and does nothing; `worker-stop` it and retry. Sol-high
burns the Codex quota fast (memory); Luna medium did #183 in seven minutes.

## Where the phase stands

Phase 4 is the repository format and installer. The plan is
`docs/superpowers/plans/2026-09-11-phase-4-repository-format-installer.md`; **it owns the slice
breakdown, the eleven acceptance criteria and the worker briefs.** #168 tracks slice state.

| Slice | What | State |
|---|---|---|
| D0–S3 | design, host bridge, parser, installer | ✅ merged |
| S3 follow-ups #176 / #177 | persist-first; corrupt-store quarantine | **PR #183, reviewed, auto-merge armed** (see §1) |
| S4 | `ExtensionSource: MangaSource` + dynamic registration (criteria 8, 9) | **PR #184, review half done** (see §2) |
| S5 | Settings UI (criterion 10) + declared-age gate | not started; unblocks on #184 |
| S6 | WeebCentral installed rather than compiled (criterion 11) + production `RepositoryTransport` | not started; unblocks on #184 |

Unit suite on `main` (`9a1b7bf`): 1034/1029/0/5. With #183: **1037/1032/0/5** (run by the reviewer
on the Pro). #184 claims **1061/1056/0/5** on its own branch — not yet re-run after a rebase.

## What is owed

### 1. #183 — land it

Reviewed by the protocol: both mutations re-run by the reviewer reddened exactly the claimed test
(revert the `transition` reorder → `testDisablePersistFailureLeavesRegistryRegistered`; drop the
unreadable state → `testCorruptRepositoryFileIsQuarantinedAndCommitRefusesToOverwriteIt`). Full suite
1037/1032/0/5 on the rebased branch. Rebased onto `9a1b7bf`, force-pushed, `gh pr merge --squash
--auto` armed at 12:33; CI was still running. **Check `gh pr view 183 --json state,mergedAt`.** If
auto-merge did not fire, `gh pr merge 183 --squash` with the user's say-so.

Non-blocking note for S5: lookups on an unreadable `RepositoryStore` return the empty snapshot
silently; `try store.loadIfNeeded()` (now internal, throwing) is how S5 detects "your installed
Sources could not be read". Nothing is destroyed either way — that was #177's job.

### 2. #184 (S4) — finish the review, then merge

Worktree `~/orca/workspaces/Manga-Reader/phase4-s4-extension-source`, branch
`eliasmagdaleno/phase4-s4-extension-source`, one commit `3921083`, +1331/−8, 8 files. The Orca
dispatch (`ctx_2c0c2e83031f`, run `run_9df2075071af`) sent `worker_done`; the terminal is idle.

**Done so far:**
- `SourceRegistry.shared` gate — **passes.** Every non-Preview mention is a doc comment; production
  reads go through `AppComposition.registry`; the registrar is handed that instance.
- Glossary verdict on `ExtensionSourceRegistrar` — **not a domain term**, no glossary entry. It is a
  mirror between two stores; the concepts it moves are already defined. The three "registr-" nouns
  (`SourceRegistry`, `SourceLifecycleRegistry`, `ExtensionSourceRegistrar`) are a naming cost the user
  has been told about and has not asked to change.
- Read: `SourceRegistry.swift`, `SourceLifecycleRegistry.swift`, `ExtensionSourceRegistrar.swift`,
  `AppComposition.swift`, the header of `ExtensionSource.swift`. Quality is high; the PR body names a
  test and a mutation per clause of criteria 8 and 9.

**Left to do, in order:**
1. After #183 lands: `git -C <worktree> fetch && git rebase origin/main`. #184 does not touch
   `ExtensionInstaller.swift` or `RepositoryStore.swift`, so no conflict expected; `project.pbxproj`
   is keep-both if it conflicts.
2. Full `MangaCartaTests` on the Pro (`id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691`; the name form has
   failed to resolve from a session shell). Expect 1064 total (1037 + 27).
3. Re-run the two mutations the previous handoff named: (a) stamp `sourceId` with `"mangadex"`
   instead of the qualified id in `ExtensionSource` →
   `testTheHostStampsTheQualifiedIdAndTheEngineCannotOverrideIt` and
   `testAMangaFromTheInstalledSourceRoutesBackToIt` must redden; (b) remove the `isActive` guard from
   `ExtensionSource.invoke` → the three "unavailable" tests and
   `testTheAdoptedInstanceDegradesToUnavailableAfterUninstall` must redden. Count clauses, not tests.
4. Push the rebase, `gh pr merge 184 --squash` with the user's say-so, check `mergedAt`.
5. Update #168 (S3 follow-ups and S4 done) and `CLAUDE.md` → "Current state" (the S4 paragraph
   there still says "None of it is reachable from the app yet" — after #184 that is false: installed
   Sources restore at launch into the graph's registry; what is still missing is a way to *add* a
   repository, which is S5, and a production transport, which is S6).

**S4's six findings, from the PR body — file as issues when merging, none folded in:**
1. Host API design's `{query, page:{cursor,limit}}` request shape vs the shipped engine's flat
   `cursor`/`limit` — one must be amended before a second engine exists.
2. `MangaSource.webURL(forManga:)` is sync; installed Sources return `nil`. Making it `async` is
   S6's to do during the cutover.
3. `HomeViewModel.loadHomeAsync` loads all three rails unconditionally; a popular-only Source breaks
   Home. Design §13 says an undeclared feed has no rail. S5/S6 UI work.
4. `SourceRegistry.source(for:)` falls back to the active source for an unknown `sourceId`; after
   an extension uninstall the detail page's next `adopt` asks MangaDex for a WeebCentral id. Pre-
   existing decision (`RegistryInjectionTests`), not reversed.
5. No production `RepositoryTransport` (`UnavailableRepositoryTransport` fails with a sentence);
   adult acknowledgement declines until S5 sets `AdultInstallAcknowledgementHandle.present`.
6. `AppComposition.extensions` is `nil` when `HostStorageRepository` cannot open — silent, same
   family as #177.

Also: a comment in `AppComposition.swift` says the production transport "is S5's to write". The
user decided (2026-09-16) **S6 owns it** — fix the comment in S6, not by reopening #184.

### 3. S5 and S6 — dispatch as a two-provider wave after #184 merges

Decisions already made by the user (2026-09-16), do not re-ask:
- **Parallel**, not sequenced. Assemble each brief from the plan's preamble + slice section + a
  "what is on main since the plan" block (the plan predates every merge).
- **S5 — Codex `gpt-5.6-luna` medium, iPhone 17 Pro** (it needs the seeded fixture for a hermetic
  UI test). Owns: Settings UI for add/refresh/install/update/disable/uninstall/remove (criterion
  10); the **declared-age gate** as the install sheet for `mixed`/`adultOnly` (ADR-0022 Amendment 2,
  design §7.1, glossary "Declared-age gate") wired through `AdultInstallAcknowledgementHandle.present`;
  the "installed Sources could not be read" state (§1 note). Uses the **test fake transport** behind
  the UI; does **not** write the production transport. Should also file/fix finding 3 if the rail
  problem blocks its UI test.
- **S6 — Claude if any budget remains, otherwise Codex Luna; plain iPhone 17**
  (`id=2A0D54DF-5961-4286-A2B6-F24B4F7537B4`). Owns: the production `URLSession`
  `RepositoryTransport` composed with `RepositoryIndexValidator`, enforcing
  `RepositoryFormatLimits.maximumScriptBytes` (no consumer yet); WeebCentral installed as a package
  and the compiled `WeebCentralSource` removed from `builtInSources()` (criterion 11);
  `webURL` → `async` (finding 2); the stale "S5's to write" comment. **Must measure** for evidence
  gate 1 (spec §16, design §10): serialized storage size, wall-clock per operation, request counts,
  actual index/script sizes. Closing the gate is not its job; producing the numbers is.

`worker-start --spec "$(cat brief.md)" --task-title … --worktree id:<repo>::<path> --agent codex
--model gpt-5.6-luna --effort medium --run run_9df2075071af --from <live terminal>` worked; create the
worktree first with `orca worktree create … --setup skip --no-parent --base-branch main`, then
`cp Secrets.xcconfig <worktree>/` (repo root).

### 4. Launch decisions — two left, the user's

- **#150 — the name.** Whether to commission a clearance search. Also gates the privacy-policy
  URL (below).
- **App icon.** Brief is written and merged: `docs/design/app-icon-brief.md` (#182). **The user's
  move is to send it** to a designer. The placeholder (#165) ships until then.

Decided and closed this pass: **#149** — `PrivacyInfo.xcprivacy` declares Name, User ID, Product
Interaction (#181, `9a1b7bf`); the research doc `docs/superpowers/research/2026-09-11-issue-149-…`
owns the App Store Connect answers and records the decision. Still owed from it: the **hosted
privacy policy text** (names MAL, fields, retention, revocation — ADR-0022 Amendment 2 commits to
it), blocked on #150 for a URL. No ADR amendment was written for the labels: Amendment 2 reserves
"Amendment 3" for a Review reversal, and the research doc is the owner.

### 5. Device-in-hand items — **before launch, date unset**

Re-labelled from "one sitting for both" at the user's agreement; they have been carried too long
to call imminent.
- **Live-verify MAL progress push.** `scripts/mal_live_write.py`;
  `testLiveHorimiyaCompletionPushesProgress` behind `TEST_RUNNER_MAL_LIVE_WRITE=1`.
- **Manual VoiceOver pass, #90.** `./scripts/voiceover-pass.sh`; real iPhone; rows 4.3, 6.5, 7.2,
  7.5, 7.6 most need eyes. Close when every row has a verdict.

### 6. Small debts

- `-uitest-updates-state` seeds `two-listings`. Rename if a third unrelated state appears.
- Worktrees to remove (all merged): `phase4-s2-package-parsing`, `phase4-s3-installer`, and
  `phase4-s3-followups` once #183 shows `mergedAt`. Keep `phase4-s4-extension-source` until #184
  merges.

## Dispatch mechanics learned this pass

Everything in the archived 2026-09-16 handoffs still holds. Added:
- **A Claude worker that hits its session limit sits idle with the limit banner and a reset time**
  ("resets 8:30pm"). Commits survive; an *applied mutation may be left in the working tree* — S4's
  was `.reversed()` in `pageURLs`. Recovery that worked: `orca terminal send --text $'\x15'` to clear
  stray input, then `--text "<resume prompt>" --enter`, telling it to `git checkout --` the file
  first and to run mutations one at a time — its background mutation queue had been **killed for
  low memory**. It finished in ~70 minutes after resume.
- **Codex model names:** `gpt-5.6-luna` / `-sol` / `-terra` work; `gpt-5.4` does not (see top).
  A retry is `worker-stop --dispatch <old>` then `worker-start --task <task> --retry-of <old> …`
  with placement repeated; `worker-start` refuses the retry while the old dispatch is still
  `dispatched`.
- **GitHub auto-merge (`gh pr merge --auto --squash`) does fire** — #181 landed that way. It is
  a fine default when CI is still running; still confirm `mergedAt`.
- **The Codex stop hook still dies** ("hook returned invalid stop hook JSON output") — cosmetic;
  `worker_done` had already been sent.

## Supervision protocol

Unchanged. Used on #183 this pass; mutation claims held exactly.

1. `git -C <worktree> status` and the terminal preview — the dispatch status lies.
2. Rebase onto `main`; a `project.pbxproj` conflict is keep-both.
3. Full `MangaCartaTests` after the rebase; totals from the result bundle.
4. Review by mutation, not by reading — count clauses, not tests.
5. Merge with the user's say-so, and check the PR body names a test *and a mutation* per criterion.

## Repository state

- `main` at **`9a1b7bf`**. Merged since the last handoff: #180 (handoff), #181 (#149 manifest),
  #182 (icon brief).
- **Open PRs:** #183 (auto-merge armed), #184 (review half done), this handoff.
- Open issues: #168 (tracking), #176 / #177 (close with #183), #150, #90.
- Orca run **`run_9df2075071af`**, coordinator `term_a8a4b76b-d9ad-4513-9e10-0531230af89e`. Both
  dispatches settled (`ctx_2c0c2e83031f` S4, `ctx_8aef3c477b61` #183); release their terminals when
  the PRs merge.
- `docs/superpowers/handoff/` holds this file and `archive/` (83 archived handoffs plus README).
