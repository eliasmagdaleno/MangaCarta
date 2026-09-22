# Handoff — the WeebCentral cutover is on PR #201 (draft), most clauses proved; one real UI regression blocks it

Date: 2026-09-22, 11:20 PDT
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-cutover-in-progress`, off `main` at `3bca188`.
**Work branch: `eliasmagdaleno/phase4-cutover-bundled-weebcentral` at `d060634`, pushed, draft PR #201.**
Worktree: `~/orca/workspaces/Manga-Reader/phase4-s6-weebcentral-installed` (clean).

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Standing instructions from the user

- **Codex `gpt-5.6-luna` medium for implementation; Claude for review and decisions** (2026-09-19).
  `gpt-5.4` is refused on this account.
- **Astra**: hard tasks only, plan-then-fan-out. Nothing queued needs it.
- **On this slice the user approved taking the work back in-house** after Luna stopped three times
  with `worker_done --outcome failed`, each time having done roughly one item. The remaining work
  below is the coordinator's own unless the user says otherwise.

## Where the phase stands

Phase 4 D0–S6 are merged (`main` = `3bca188`). The cutover is the last piece; #168 stays open until
it lands. Decision record: **ADR-0003 Amendment 5** (bundled package), ADR-0022 Amendment 3, format
design **§12**, glossary "Bundled package" — all merged in #199. Brief:
`docs/superpowers/plans/2026-09-21-phase-4-cutover-brief.md` (nine clauses); continuation items are
in this session's specs, summarized below.

### What is done and proved on `d060634`

- **Bundled package ships and installs.** `MangaCarta/Resources/BundledRepositories/weebcentral/`
  (`index.json` + `engine.js`) is a **folder reference** in the pbxproj — it must stay one, or Xcode
  flattens it into the app root and `url(forResource:subdirectory:)` returns nil (that was a real
  defect, fixed in `d629dc5`).
- **One URL convention.** Everything bundled lives under host **`bundled.invalid`** (RFC 2606, never
  resolvable) as an `https://` URL, so the index, its `script` reference and the repository record
  all satisfy the validator's absolute-HTTPS rule, and `AppRepositoryTransport` routes on the host
  for *both* index and script. An earlier draft used a `bundled://` scheme for the index only and the
  script fetch escaped to the network.
- **`ExtensionComposition.installBundledSources()`** is the one first-launch path, awaited by
  `MangaCartaApp` after composition (an earlier draft fired it from `AppComposition.init` as an
  unstructured `Task`, leaving `registry.sources` racing). It returns the failure sentence.
- **`WeebCentralIdentityMigration`** rewrites bare-id *values* and **`"weebcentral:<id>"`-prefixed
  dictionary keys** (`EntityResolutionStore` keys its cache that way — the original missed them).
  `listing-counts.json` is deliberately excluded: `Caches/`, 24h TTL, a stale entry is a miss.
- **Compiled Source deleted** — `WeebCentralSource.swift`, `HTMLSelectorThemeEngine.swift`, the
  compiled half of the port harness; `builtInSources()` is MangaDex alone.
- **Tests added** (`MangaCartaTests/BundledWeebCentralCutoverTests.swift`, three classes): first
  launch installs after MangaDex under the fixed UUID; second launch does not duplicate; an
  uninstalled Source stays uninstalled and is still offered; an app update's new `version` is
  *offered* by refresh and applied only by `updateBundle`; a `mixed` declaration in a bundled index
  is refused; a tampered script fails the digest; the migration keeps the Work id, rewrites prefixed
  keys, is byte-for-byte idempotent, and leaves a legacy-free file untouched; exactly one copy of the
  engine script exists in the repo; the Settings bundled-predicate.
- **Unit suite: 1069 / 1064 passed / 0 failed / 5 skipped** (result bundle, iPhone 17 Pro). The five
  skips are the pre-existing device/seed-gated ones. `swiftlint` on every touched file: **0 errors**.
- `SimulatorSeed` now stamps the **qualified** id, so the fixture never depends on the migration.

## What is owed

### 1. The blocking regression — `RepositorySettingsUITests` (real, reproduced twice)

`testRepositoryCanBeAddedAndItsSourceInstalledWithFixtureTransport` fails at
`MangaCartaUITests/RepositorySettingsUITests.swift:42`:

```swift
adultToggle.tap()      // on
adultToggle.tap()      // off  → clears the declared-age confirmation
XCTAssertTrue(adultToggle.waitForNonExistence(timeout: 5))   // ← fails: the toggle stays
```

Ran twice on the Pro, failed both times, so it is **not** the known UI flake. It passed on `main`
(#193's CI was green), so the cutover caused it. **Not yet diagnosed — do not guess.** The obvious
suspect is that with a bundled Source now registered, `registry.hasAdultSource` or the
`shouldShowAdultSourcesToggle(isConfirmed:hasRegisteredAdultSource:)` inputs differ from what the
test assumed when only the fixture Source existed — but the UI-test launch passes a fixture
transport, which sets `usesBundledTransport == false`, so the bundled Source should *not* be
installed in that launch. That contradiction is the thing to resolve first: instrument what the
registry actually holds in the `-uitest-repository-settings` launch before changing any code.
Other two classes (`UpdatesUITests`, `SourcePreferenceUITests`) passed.

### 2. Remaining acceptance items for PR #201

- **Clause 9 — seeded-fixture proof.** Not run. Copy the app container aside **first** (works.json
  was destroyed this way once), run `scripts/seed-simulator.sh` on the Pro, launch once, and show via
  `plutil -p`/`jq` that the container's `works.json` carries the qualified id and no bare
  `"weebcentral"`. `scripts/adr0019_seed.py` also writes bare ids by hand — decide whether it is
  still used and update or delete it.
- **Migration accounting table** for the PR: all 14 files/keys were verified to exist in their
  stores (`works.json`, `updates.json`, `library.items`, `library.collections`, `history.entries`,
  `history.readMarks`, `entityResolution.cache`, `entityResolution.reverseCache`, `taste.tagCache`,
  `taste.notInterested`, `taste.moreLikeThis`, `source.primaryID`, `source.workChoices`, and the
  excluded `listing-counts.json`). Write it into the PR body with the grep evidence.
- **Grep account.** After this branch: the only `WeebCentralSource` hit is a docstring in
  `scripts/reverse_reach.py`; the bare `"weebcentral"` hits in `MangaCarta/` are the package's
  `localId`, the installer call, and the migration's `legacyID` — all correct. Test-side hits are
  `localId`s and fixture source ids; list them in the PR.
- **"Design deviations" section** in the PR body: `bundled.invalid` as the index/script host (§12
  says bundle-relative; the validator's absolute-HTTPS rule is why). Decide whether to amend §12 or
  keep the deviation documented — **amend if kept**, since the design is the owner.
- **Mutation table** for all nine clauses. Mutations run so far: the three original S6 ones, plus
  each new clause was written test-first against a failing state. The per-clause mutation runs for
  the *new* tests still need doing and recording.
- Full suite + the three hermetic UI classes green, then mark #201 **ready** and merge with the
  user's say-so. Then: close #168, update `CLAUDE.md` "Current state", release both Orca workers,
  remove both worktrees.

### 3. Findings filed this pass

#196 (transport has no private-destination/DNS or per-hop redirect check), #197 (overlapping adult
installs strand a `CheckedContinuation`). Still open from S4: #186 (human decision), #188, #189, #190.

### 4. Launch decisions — the user's

- **#150** — the name; gates the hosted privacy-policy URL (text still owed).
- **App icon** — `docs/design/app-icon-brief.md` to a designer; placeholder ships until then.

### 5. Device-in-hand — before launch, date unset

MAL live-write verify (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); VoiceOver pass #90.

## Mechanics learned this pass

- **Never run two `xcodebuild test` invocations against the same simulator.** Doing so killed a unit
  run with "Early unexpected exit … Test crashed with signal kill", which reads like a code failure
  and is not.
- **`orca orchestration check` takes `--terminal`, not `--from`** (`--from` is for `worker-start` /
  `run-current`). A loop using `--from` silently returns nothing forever.
- **Ack every delivery** (`check --ack <deliveryId>`); the same batch replays until you do. Two
  `worker_done`s from the previous session were still queued at the start of this one.
- **Fixture JSON must be mutated as JSON, never by string replacement.** The bundled index is
  re-serialized by `JSONSerialization`, so `"adult": "none"` became `"adult":"none"` and a test
  helper's `replacingOccurrences` silently missed — which presented as "adult gating is broken" and
  cost a dispatch. The root cause was the fixture.
- **SwiftLint is a CI gate no worker runs.** `force_try`/`force_cast`/line-length are errors here.

## Supervision protocol

Unchanged: 1) worktree `status` + terminal preview; 2) rebase, pbxproj keep-both; 3) full suite,
result-bundle totals; 4) review by mutation, every class; 5) merge with the user's say-so.

## Repository state

- `main` at **`3bca188`**. Merged this pass: #192, #193, #194, #198, #199, #200.
- **Open PRs:** #201 (cutover, draft), this handoff.
- Open issues: #168, #186, #188, #189, #190, #196, #197, #150, #90.
- Orca run `run_e932a373e558`; coordinator `term_59f4a37e-7786-4eed-ad98-199acd1a7284`; the S5 and S6
  worker terminals are still retained and both worktrees still exist.
