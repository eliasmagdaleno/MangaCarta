# Handoff — Phase 4 is complete; what remains is findings, launch decisions and device checks

Date: 2026-09-22, 14:30 PDT
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
`main` at **`76276fe`** — the WeebCentral cutover (#201), merged 13:56 PDT with CI green.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Standing instructions from the user

- **Codex `gpt-5.6-luna` medium for implementation; Claude for review and decisions** (2026-09-19).
  `gpt-5.4` is refused on this account.
- **Astra**: hard tasks only, plan-then-fan-out. Nothing queued needs it.

## Where things stand

Phase 4 D0–S6 and the cutover are merged; `CLAUDE.md` "Current state" describes the result. The
decision record is ADR-0003 Amendment 5 and format design §12 (amended for `bundled.invalid`).
#168 is closed.

## What is owed

### 1. Cleanup the coordinator could not do

The two finished Orca worktrees still exist — both clean, both branches merged (#193, #201). The
agent's `orca worktree rm` was refused by the permission classifier; the user runs it:

```sh
orca worktree rm --worktree path:$HOME/orca/workspaces/Manga-Reader/phase4-s5-settings-ui
orca worktree rm --worktree path:$HOME/orca/workspaces/Manga-Reader/phase4-s6-weebcentral-installed
```

Orca run `run_e932a373e558` and its retained S5/S6 worker terminals go with them.

### 2. Open findings

- **#196** — the repository transport has no private-destination/DNS check and no per-hop redirect
  check.
- **#197** — overlapping adult installs strand a `CheckedContinuation`.
- **#203** — `ChapterOrdinal` Double precision (the migration ULP part was fixed in #201; check what
  is left before working it).
- From S4: **#186** (needs a human decision), **#188**, **#189**, **#190**.

### 3. Launch decisions — the user's

- **#150** — the name; gates the hosted privacy-policy URL (text still owed).
- **App icon** — `docs/design/app-icon-brief.md` to a designer; placeholder ships until then.

### 4. Device-in-hand — before launch, date unset

MAL live-write verify (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); VoiceOver pass #90.

## Mechanics worth carrying

- **Never run two `xcodebuild test` invocations against the same simulator.** The loser dies with
  "Early unexpected exit … signal kill", which reads like a code failure and is not.
- **`orca orchestration check` takes `--terminal`, not `--from`**; a loop using `--from` silently
  returns nothing. Ack every delivery (`check --ack <deliveryId>`) or the batch replays.
- **Mutate fixture JSON as JSON, never by string replacement** — re-serialization changes spacing
  and a `replacingOccurrences` silently misses.
- **SwiftLint is a CI gate no worker runs.** `force_try`/`force_cast`/line-length are errors here.
- **The bundled package must stay a folder reference** in the pbxproj (see `CLAUDE.md`).
