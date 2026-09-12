# Handoff — Phase 3 is done; Phase 4 (repo format + installer) is the critical path

Date: 2026-09-11
Repository: `/Users/eliasmagdaleno/Manga-Reader` (directory unchanged; GitHub is
`eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-10` (PR #160, reused rather than stacked), off `main`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## The roadmap

Six phases. The reasoning and the Paperback catalog research are in
`archive/2026-08-31-launch-roadmap-handoff.md`. **Read it once** rather than re-deriving it.

1. **Finish what is nearly done** — *two device tasks remain; no code is owed.*
2. **Host API design** — ✅ done (#130), its four contract gaps closed (#145).
3. **JavaScriptCore runtime + WeebCentral port** — ✅ **done 2026-09-11.** All seven slices merged;
   **all twelve acceptance criteria closed by merged code.**
4. **Repo format + installer** (~1–1.5w) — **the critical path now. Not started.**
5. **Theme engines** (~1w for Madara, then days each) — Madara alone is 29 sites.
6. **Launch prep** (~1w).

## Phase 3 closed — what shipped, and the one gap it left

| Slice | Criteria | PR | State |
|---|---|---|---|
| S2 — domain wire schemas + adapters | 3, 4 | #137 | merged |
| S1 — manifest & declaration validation | 2, 9 | #139 | merged |
| S3 — WebKit isolation spike | 6 (cookies), 8 | #140 | merged |
| S4 — JSC runtime core + bridge | 7 | #144 | merged |
| S7 — identity lifecycle | 10 | #156 | merged |
| S5 — host capabilities | 5, 6 (storage), 11 | #159 | merged |
| S6 — WeebCentral port + engine proof | 1, 12 | #162 | **merged `4dd7d95`** |

Unit suite: **990 total, 985 passed, 0 failed, 5 skipped** (CI on #162). SwiftLint clean.

**What S6 built:** `HTMLSelectorThemeEngine.swift` — one `htmlSelectorTheme` engine bundle with no
site baked into it, plus WeebCentral as a *declaration*. Base URL, path/query templates, pagination
style, client-limit behaviour, every CSS selector, id path segments, chapter-number pattern and
adult→rating mapping all live in `configuration`. Three differently configured Sources (WeebCentral
live, two synthetic) prove criterion 1.

**The compiled `WeebCentralSource` and `WebViewService` are untouched and the app is not switched
over** — that was the scope boundary, and cutting the app over is a follow-up decision for whoever
owns the registry.

### The gap Phase 3 closed every criterion without noticing — #164

`host.browser` is bridged into the runtime. **`host.http`, `host.storage` and `host.log` are not**
— the S5 capabilities exist and are tested, but `HostBrowserJSCapability` is the only
`ExtensionHostCapability` conformer, so an engine cannot call them.

WeebCentral does not notice: its `network.httpOrigins` is empty and everything goes through
`browserOrigins`. **Any HTTP-based Source notices immediately**, and most Sources are HTTP-based.
**Phase 4 should expect to need this**, and it is worth doing before theme engines in Phase 5.

## What is owed

### 1. Phase 4 — repo format + installer

Not started, no brief written yet. What S6 learned that it needs:

- **The format must carry one validator-accepted declaration record plus one bundle script.**
  Nothing else was required to run a Source. Include `presentation.feeds` eyebrows — they match the
  compiled source's `homeRailEyebrows`.
- **#161 is a Phase 4 decision**, waiting on whoever designs the installer: does `reinstall` take
  raw JSON and validate it, or is the typed `SourceDeclaration` precondition accepted and recorded?
  The installer is the only thing that will ever construct these.
- **#164 above** — the installer wires capabilities, so this is adjacent.

### 2. The two decisions the research slices could not make — #149 and #150

PR #163 did the research; both issues carry the findings and stay open on purpose, because both
"Done when"s end in a judgement.

- **#149 — MAL privacy label. This reverses #128, and the manifest is wrong today.** Apple's
  optional-disclosure exception requires the user to "affirmatively choose to provide the data for
  collection **each time**" (verbatim on Apple's App Privacy Details page, read 2026-09-11). MAL
  sync delivers progress automatically on chapter completion, so it does not qualify. The shipped
  `PrivacyInfo.xcprivacy` has an empty `NSPrivacyCollectedDataTypes`; the recommendation is **Name,
  User ID, Product Interaction** — linked yes, tracking no, App Functionality. **Owed: decide, then
  change the manifest and the App Store answers together.**
- **#150 — the name.** Still not a clearance search: TSDR needs an API key and Trademark Search is
  WAF-backed with no unattended endpoint. Nearest hit is serial **88319949**, Magna Carta AR — now
  reported archived, which *weakens* the concern. Options and figures are in the issue. **Owed:
  decide whether to commission a ~$1,000–$2,000 clearance search before launch.**

### 3. Live-verify MAL progress push — the user's to run

Built, wired, tested (`MALProgressCoordinator`, `MALProgressOutbox`, the Settings toggle and queue
status). What no unit test can show: **sign in on a device, read a chapter to the end, and confirm
the number moves on myanimelist.net.** `scripts/mal_live_write.py` pokes the API directly if the
in-app path needs isolating.

`testLiveHorimiyaCompletionPushesProgress` is gated behind `TEST_RUNNER_MAL_LIVE_WRITE=1` and skips
by default.

### 4. The manual VoiceOver pass — #90, the user's to run

Open, `ready-for-human`, **no row has a verdict yet**, and no results file in
`docs/accessibility/` — which is how you can tell at a glance it has not started.

`./scripts/voiceover-pass.sh` from the repo root parses the checklist at runtime, takes
pass/fail/skip per row, writes `docs/accessibility/voiceover-results-<date>.md`, and resumes where
it stopped. It needs a **real iPhone** — simulator VoiceOver differs on the rotor and on focus
restoration, which is most of what these rows test.

Rows most needing eyes: **4.3**, **6.5**, **7.2**, **7.5**, **7.6**.

**Section 8** (11 rows) covers the source picker. Two of its rows are expected to *pass* — 8.8 was a
real defect, now fixed; 8.5 was not a defect at all. **Neither is closed:** a trait being present is
not VoiceOver speaking it.

Close #90 when every row has a verdict, **not** when every defect is fixed.

Items 3 and 4 both want a device in hand; doing them in one sitting is worth more than doing them
well apart.

### 5. Evidence gate 1 — budgets — is still open

Spec §16. S6 is the first item in its profiling corpus but **measured nothing**. Nobody has taken
this; it wants a decision about when it gets settled, since every additional engine makes the
corpus more representative and the gate no cheaper to close.

### 6. Naming debt, small and deliberate

`-uitest-updates-state` seeds a fixture that has nothing to do with updates (`two-listings`). One
seeding path with isolated storage was judged worth more than a tidier spelling; rename it if a
third unrelated state appears.

## Launch blockers that are not features

- **No real app icon.** Still outsourced, still **order it early so it is not the long pole**, and
  it needs the *MangaCarta* name on it. This is the one blocker that cannot be compressed by working
  harder later, and it has been open across **ten** handoffs.
  **A placeholder shipped 2026-09-11 (#165) and changes nothing about that.** It exists so builds
  are identifiable rather than blank squares. `scripts/make-app-icon.swift` draws it — Ink & Seal:
  paper, screentone, a serif mark on a hairline plate, one vermilion seal carrying 漫 — and
  optionally renders a preview with iOS's rounded-rect mask applied, which is the only cheap way to
  see whether something near a corner gets bitten off. **Replace that file; do not refine it**, and
  do not read its existence as progress against this blocker.
- **#149 and #150** — now researched, both awaiting a decision (above).
- **Adult-source gating** — settled by ADR-0022. Not a blocker, just a thing not to undo.
- No listing screenshots, privacy-policy URL, App Store description, or TestFlight run. Note #149
  says the privacy policy must name MAL, describe the fields and the retention/deletion path, and
  explain how to disable or revoke sync.

## Dispatch mechanics

```sh
orca orchestration run-create --from <coordinator handle> --objective "<objective>" --json
orca orchestration task-create --from <coordinator handle> --spec "<full brief>" --json
orca orchestration worker-start --from <coordinator handle> --task <id> \
  --worktree id:<repo-id>::<path> --agent <codex|claude> --model <id> --effort high --json
orca orchestration check --terminal <coordinator handle> --types worker_done,escalation,question --json
orca orchestration reply --id <msg_id> --from <coordinator handle> --run <run_id> --body "<answer>"
orca terminal close --terminal <handle> --tab --json
orca terminal close --worktree path:<abs path> --all --json
orca worktree rm --worktree path:<abs path> --json
```

Each of these cost real time when it was learned.

- **Codex's "Hooks need review" prompt strands every worker until a human answers it once, and
  `orca terminal send` cannot.** New on 2026-09-11: *two* dispatches failed at `agent_readiness`
  with `Agent startup blocked: codex-hooks-review-prompt`, and `send` refused with
  `agent_prompt_blocked`. **The user pressed `3` (continue without trusting) once and every
  subsequent Codex launch was clean.** `orca terminal switch --terminal <handle>` brings the stuck
  tab to the front, which is the fastest way to hand it over. Answering it once in a plain
  `cd <worktree> && codex` session works too, and is easier to explain than hunting an Orca tab.
- **This is almost certainly what stranded the S5 worker for six days.** Treat any
  `agent_readiness` failure as *a prompt needing a keyboard*, not a dead worker.
- **A worker that fails at launch needs `worker-abandon` → `task-update --status ready` → a fresh
  `worker-start`.** The stale dispatch answers `worker_identity_changed` to `worker-read`, and
  `worker-abandon` warns "no longer current" — both are noise, not errors.
- **A Claude subagent in an isolated worktree delivered S6**, the hardest slice of the phase: a
  complete PR, CI green, mutation evidence per clause. It cannot stall on a provider prompt. **Use a
  prepared worktree, not the main checkout.** This is now proven twice (S7, S6).
- **`gpt-5.6-sol` high is the thing to avoid, not Codex.** Clarified by the user 2026-09-10: GPT
  workers are wanted for the provider split. `gpt-5.6-luna` at medium effort did the #149/#150
  research well and cheaply. Keep sol-high for a slice that earns it.
- **Prepare the worktree before dispatching:** `orca worktree create --name <n> --repo id:<uuid>
  --base-branch main --setup skip --no-parent`, then **copy `Secrets.xcconfig` in** — it is
  gitignored and the build fails without it. The repo's setup hook is `pnpm install`, which is
  meaningless here; `--setup skip` is right.
- Selectors need an `id:` prefix — `--repo id:<uuid>`, `--worktree id:<repo-id>::<path>`. The error
  names neither the flag nor the fix. `orca worktree rm` also accepts `path:<abs path>`.
- **`--from <coordinator handle>` is needed from the very first command.** Outside a live Orca
  terminal, `run-create` fails `no_active_sender_terminal`; later `worker-start`s fail
  `consumer_fenced`. Get the handle from `orca terminal list --json`.
- **Flag spellings differ per subcommand.** `worker-stop`/`worker-read`/`worker-abandon` take
  `--dispatch` and **reject** `--from`; `task-update` takes `--id`, not `--task`, and **has no
  `--title`** — a task's display name is its spec's first heading, so lead the spec with a real
  title; `check` takes `--terminal`, not `--from`; **`run-show` takes `--id` and rejects
  `--terminal`.**
- **Split every parallel wave across providers.** Both providers have stalled a wave, and every
  stall was silent.
- **Default `--model` to something cheap; make Opus high earn its place.** **Fable is not available
  on this account.**
- **`--setup skip` is rejected when the worktree already exists.**
- **Changing a worker's model means abandon, not stop.**
- `check --wait` ending in `runtime_unavailable` is the app restarting, not a worker failure.
- **Start every independent worker before the first wait**, or the work serializes.
- **A `worker_done` is not a merge**, and it is not a green suite either.
- **Two workers cannot both build.** The simulator is a single shared resource — give a parallel
  worker docs/research/spec work and say so in the brief, in as many words.

## Supervision protocol

When a slice reports done, in this order:

1. `git -C <worktree> status` and the terminal preview — **the dispatch status lies.**
2. Rebase onto `main` and expect a `project.pbxproj` conflict if a peer landed first; the resolution
   is **keep-both**.
3. Re-run the **full** `MangaCartaTests` bundle after that rebase and read the totals from the
   result bundle.
4. **Review by mutation** (see Gotchas), not by reading.
5. Only then merge, and check the PR body names a test per acceptance criterion it claims.

**Add `orca orchestration check --terminal <handle> --types question` to every supervision pass** —
a worker can block on its own question while heartbeating `live`. `check` does not reliably mark a
question read; an `answer_conflict` from `reply` is the reliable signal that one was already
handled.

**Keep supervision cheap.** The default pass is `check` plus `git -C <worktree> status -sb`.

**Verify the worker's own claims against the repository, not against its report.** S6's report was
accurate on every point checked — but checking is what established that, and two claims looked like
defects until the code said otherwise (see "A layering difference is not a divergence" below).

## Gotchas

Re-verify any that becomes load-bearing rather than trusting this list.

- **A passing test is not evidence until you have seen it fail — and "it stopped compiling" is not
  seeing it fail.** Mutate the implementation and re-run. This has found real gaps in three
  consecutive slices.
- **Count clauses, not tests.** A criterion is a sentence with several claims in it; a suite can
  cover the memorable ones and miss the rest. **Mutate each clause separately.** S6 was dispatched
  with this rule in its brief and came back with a mutation per clause — eleven of them — which is
  the cheapest this review has ever been.
- **A layering difference is not a divergence.** S6's engine returns *absent* for a chapter with no
  numeric token while the compiled source returns `"?"`; that looked like an undocumented behaviour
  change and is not — S2's merged `ExtensionChapter.toChapter()` does `number ?? "?"`, so the engine
  reports absence and the adapter supplies the display value. **Check where a fallback lives before
  calling it a regression.**
- **Do not trim WeebCentral's `assetOrigins` in review.** `httpOrigins` is empty, and covers
  (`temp.compsci88.com`) and pages (`scans.lastation.us`) come from those origins. Trimming them
  silently costs every cover.
- **A page fixture can measure the harness.** With subresources blocked, WeebCentral's reader
  `<img onerror>` handlers rewrite their own `src` to a local placeholder. `validatePages` caught it
  by rejecting the rewritten URLs against the asset policy — a criterion-3 rule catching a
  criterion-12 mistake. The fix is disabling the page's own JavaScript, which both the compiled and
  the ported extraction paths share.
- **Identity stored and then discarded is a warning sign.** `_ = sourceID` meant a value was kept
  for a rule nothing enforced. Grep for `_ = ` before trusting that a type protects an invariant.
- **A test can pass for a reason other than the one its name claims.**
- **Grep the symbol, not the file you expect it in.** A Swift extension can put a type's API
  anywhere in the module. It also hides from a *partial* grep.
- **Squash merges make the commit graph lie about what is merged**, and the lie reaches worktree
  cleanup. **Check the PR state before deleting anything** — `gh pr list --state all --head <branch>`.
- **`gh pr merge --delete-branch` fails to delete a local branch that a worktree still holds.** The
  merge itself succeeds; only the local cleanup errors. Remove the worktree first, or ignore it and
  clean up after.
- **Never run two `xcodebuild` invocations against the simulator at once.** A second produces
  `Executed 0 tests` plus a named failing test and a `DebuggerLLDB.DebuggerVersionStore.StoreError`
  — which looks exactly like a real failure and is not.
- **Do not pipe an `xcodebuild` run through `tail`.** Redirect the whole log to a file.
- **`app.debugDescription` in an assertion message is how UI-test failures become diagnosable.**
- **File:line citations rot within one session.** Cite living documents by *term or section*.
- **A URL in an issue comment must outlive the branch.** Two comments posted by a worker linked
  `/blob/<branch>/...` paths that die at merge. Link `/blob/main/...` or a commit permalink.
- **`$` in a `gh issue comment --body "..."` gets eaten by the shell.** Dollar figures came out as
  `~,000–,000`. Use `--body-file -` with a quoted heredoc.
- **Changing an accessibility label silently breaks XCUITests.** CI runs the two hermetic suites, so
  this class of break turns something red — but only for what those two cover.
- **The UI target is split, and only half is a merge condition.** `UpdatesUITests` and
  `SourcePreferenceUITests` are hermetic and run on every PR. Everything in `MangaCartaUITests.swift`
  is live and run by name. **Do not name live data in a test that does not measure it.**
- **A bare accessibility query can match the wrong list.** Settings has two lists of source names;
  rows are namespaced `browseSource.` and `preferredSource.`.
- **CI is a major version behind local** — `macos-15` → Xcode 16.4 / Swift 6.0 vs local 26.x / 6.2.
  Treat isolated conformances, `nonisolated(nonsending)`, `@concurrent` and `Task.immediate` as
  unavailable. A `get throws` property and Swift Testing's `#expect(throws:)` returning the error
  both **do** compile there.
- **CI's SwiftLint is not this machine's either.**
- **`AppComposition.init` sits right at SwiftLint's body-length limit.** Extract rather than inline.
- **A wedged simulator looks exactly like a failing suite.** `** TEST FAILED **` with no failing
  test named is `Application failed preflight checks` / `Busy`. `xcrun simctl boot "iPhone 17 Pro"`
  and re-run. **Do not erase the device** — it holds the seeded fixture, and erasing has already
  destroyed `works.json` once.
- **The simulator's `works.json` is a usable source of truth for real source ids.** It lives under
  `.../Devices/<UDID>/data/Containers/Data/Application/<app>/Library/Application Support/`, **not**
  `Documents/`. Bundle id is `Elias-Magdaleno.Manga-Reader` — deliberately not renamed with the app.
- **`curl` cannot reproduce the app's WeebCentral browse or search paths.** HTMX-rendered, behind
  Cloudflare; a search URL returns only the page shell. `/series/{id}/full-chapter-list` *is*
  fetchable directly. S6's captured fixtures (`MangaCartaTests/__Fixtures__/weebcentral/`) are now
  the cheaper way to get real markup.
- **`project.pbxproj` churns under you** whenever Xcode has the project open. Check
  `git diff --stat` immediately before `git add`.
- **`Secrets.xcconfig` is gitignored**, so a fresh worktree fails to build with "Unable to open base
  configuration reference file" until you copy it in. This is not a broken branch.
- **`TEST_RUNNER_`-prefixed shell variables reach the hosted unit bundle**, not just UI tests.
- **Recorded so nobody retries them** (from the S3 spike): a `WKURLSchemeHandler` response reaches
  the navigation-response delegate downgraded to a bare `NSURLResponse` with **every header
  stripped**, and `loadSimulatedRequest` does not run the response-policy step at all.
- **You cannot approve your own PR** — `gh pr review --approve` fails on your own account. Review
  findings go in a comment.
- **Branch protection does not stop this account** — `enforce_admins: false`. Ask first.
- **Do not stack PRs** — a child closes unrecoverably when its base is deleted.
- **A full CI run takes ~12 minutes** for a code change. **#155's docs-only path is confirmed
  working**: #163 reported all four checks in 2–6 seconds. Every job still runs and reports, so a
  required check is never left unreported; the `changes` job guards the expensive steps. The failure
  mode to keep watching for is a green check that skipped something it should have run.
- **Target the iPhone 17 Pro simulator** on every `xcodebuild` — it holds the seeded fixture.
- **Test totals come from the result bundle, not the log tail.**
  `xcrun xcresulttool get test-results summary --path <bundle>`.

## Repository state

- `main` at `52ed0d0`. Merged since the last handoff: **#162** (S6), **#163** (launch-blocker
  research), **#160** (this handoff), **#165** (placeholder app icon).
- **No open PRs.**
- `gh issue list`: **#90** (VoiceOver, ready-for-human), **#149** (MAL privacy label — researched,
  decision owed), **#150** (name clearance — researched, decision owed), **#161** (reinstall
  validation — a Phase 4 decision), **#164** (host capability bridge — new, real).
- **Branch protection requires three checks:** `Build & unit tests`, `SwiftLint`, and
  `Hermetic UI tests`.
- Unit suite: **990 total, 985 passed, 0 failed, 5 skipped** (CI on #162). SwiftLint clean.
- **Worktrees are clean: two, both wanted** — the main checkout, and
  `Manga-Reader-worktree-helper` at the repo root, unrelated, from 2026-08-21. The S5, S6 and
  launch-blocker worktrees were removed today; `git worktree prune --dry-run` is empty.
- **Orca terminals: two.** The coordinator `term_15c0eb64-b03c-4606-add4-e337286e7ea7` — **record
  it**, every orchestration command needs it after a runtime restart — and one on the unrelated
  worktree helper.
- `docs/superpowers/handoff/` holds this file and `archive/` (79 archived handoffs plus its README).
  Two `.md` files at this level means someone skipped the rule.
