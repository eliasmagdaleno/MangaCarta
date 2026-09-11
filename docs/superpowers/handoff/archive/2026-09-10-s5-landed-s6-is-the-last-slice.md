# Handoff — S5 landed; S6 is the last slice of Phase 3

Date: 2026-09-10
Repository: `/Users/eliasmagdaleno/Manga-Reader` (directory unchanged; GitHub is
`eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-10`, off `main` at `add18b3`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## The roadmap

Six phases, ~8–9 weeks. The reasoning and the Paperback catalog research are in
`archive/2026-08-31-launch-roadmap-handoff.md`. **Read it once** rather than re-deriving it.

1. **Finish what is nearly done** — *two device tasks remain; no code is owed.*
2. **Host API design** — ✅ done (#130), its four contract gaps closed (#145).
3. **JavaScriptCore runtime + WeebCentral port** (~2w) — **six of seven slices merged. S6 is all
   that is left.**
4. **Repo format + installer** (~1–1.5w).
5. **Theme engines** (~1w for Madara, then days each) — Madara alone is 29 sites.
6. **Launch prep** (~1w).

## Where Phase 3 stands — eleven of twelve criteria closed

The plan is `docs/superpowers/plans/2026-09-03-phase-3-jsc-runtime.md`. **Spec Section 15's twelve
acceptance criteria are the definition of done**, each owned by exactly one slice. Briefs for all
seven exist there.

| Slice | Criteria | PR | State |
|---|---|---|---|
| S2 — domain wire schemas + adapters | 3, 4 | #137 | merged |
| S1 — manifest & declaration validation | 2, 9 | #139 | merged |
| S3 — WebKit isolation spike | 6 (cookies), 8 | #140 | merged |
| S4 — JSC runtime core + bridge | 7 | #144 | merged |
| S7 — identity lifecycle | 10 | #156 | merged |
| S5 — host capabilities | 5, 6 (storage), 11 | #159 | **merged `add18b3`** |
| S6 — WeebCentral port + engine proof | 1, 12 | — | **unblocked, not started** |

**Criteria still unowned by merged code: 1 and 12** — S6, and nothing else.

Unit suite on `main`: **977 tests, 972 passed, 0 failed, 5 skipped.** SwiftLint clean.

## What is owed

### 1. S6 — the last slice, and the one that proves the whole design

Its brief is in the plan (written and reviewed in #153). It ports the compiled WeebCentral Source
to a configuration-backed Extension and must show equivalent browse/detail/chapter/page behaviour,
*modulo intentional validation improvements* — criterion 12 — while criterion 1 wants one theme
engine serving at least three differently configured Sources without code duplication.

**It was blocked on S5 and is not blocked any more.** Everything it needs is on `main`.

Two things to know before dispatching it:

- **`Models/WeebCentralSource.swift`'s co-located JS extraction strings are the volatile part.**
  They are what a site redesign breaks, and this slice is where they stop being Swift string
  literals.
- **`curl` cannot reproduce the browse or search paths** — see Gotchas. Get real ids from the
  simulator's `works.json`.

### 2. The reinstall-validation gap S7 left open deliberately

Recorded here because it is a decision nobody has made yet, not a defect.

S7's brief said reconnection must revalidate rather than trust a cached declaration. That is half
met. `SourceDeclaration.adult` is non-optional, so an adult-less declaration cannot exist as a typed
value — but nothing enforces that a caller validated **at all**, because `SourceDeclaration` has
only the internal memberwise initialiser and a hand-built one bypasses the validator. Closing it
means `reinstall` taking raw JSON.

Out of scope for S7. **Someone must decide whether it is in scope for Phase 4's installer**, which
is the only thing that will ever construct these. **Worth filing as an issue** rather than riding
along in handoffs — this is its third.

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

### 5. Watch #155's docs-only CI path the first time it matters

#155 makes a documentation change cost about fifteen seconds instead of twenty minutes. It is **not**
`paths-ignore` — every job still runs and reports, because a required check that never reports
leaves a PR blocked forever; a `changes` job diffs against the merge base and guards each expensive
step.

**The PR carrying this handoff is a docs-only change**, so its `Detect code changes` job is the
observation. The failure mode to watch for is **a green check that skipped something it should have
run**.

### 6. Naming debt, small and deliberate

`-uitest-updates-state` seeds a fixture that has nothing to do with updates (`two-listings`). One
seeding path with isolated storage was judged worth more than a tidier spelling; rename it if a
third unrelated state appears.

## Launch blockers that are not features

- **No app icon.** `AppIcon.appiconset/` holds only `Contents.json`. Being outsourced — **order it
  early so it is not the long pole.** Unchanged across **nine** handoffs now. This is the one
  blocker that cannot be compressed by working harder later. It needs the *MangaCarta* name on it.
- **The MAL privacy-label recheck — #149.**
- **The name — #150.** First pass done: no App Store app is named MangaCarta and no trademark
  surfaced, but *Magna Carta* is live in software (Magna Carta Technologies LLC, AR software) one
  letter away, and examiners weigh sound and appearance. Not a clearance search.
- **Adult-source gating** — settled by ADR-0022. Not a blocker, just a thing not to undo.
- No listing screenshots, privacy-policy URL, App Store description, or TestFlight run.

## How S5 was recovered, and what it cost

Kept because it changed what this repository knows about stalled workers and about its own tests.

**The worker never came back.** It parked on a Codex usage limit mid-write on 2026-09-04 and was
still parked on 2026-09-10. Three resume attempts in six days wrote nothing; the last ran sixteen
minutes reading design docs and died at the wall. The previous handoff said the block was the
answerable *"switch to gpt-5.6-luna?"* prompt; by then it was a hard limit with no key to press.
**Both descriptions were true at different times — re-read the terminal rather than the handoff.**

**The parked work was not broken.** Committed as-is and rebased onto `main`, it built clean against
S4 and passed the whole suite on the first try. "Parked mid-write" meant *unreviewed*, not
*unfinished*, and those need opposite responses. **Commit orphaned work before anything else** — it
converts "nothing may touch this worktree" into an ordinary branch.

**Mutation review found four things reading would not have.** Five mutations killed exactly the test
carrying the invariant. Four survived a fully green suite:

- the converter's depth cap, safe-integer range and non-finite checks were **entirely untested**;
- criterion 5's **HTTPS** clause was untested — `HostURLPolicy` checks it twice, in `validate` and
  again in `canonicalOrigin`, so it is defence in depth with neither layer covered;
- **URL credentials** were untested; and
- **cookie isolation** was untested: pooling every Source into one jar passed all twelve tests.

The cookie one needed code, not just a test. Isolation was real but **purely structural** — it held
because each Source was handed its own jar, and `HostHTTPCookieJar` could not enforce it: it took a
`sourceID`, stored it, and discarded it with `_ = sourceID` to silence the unused warning. The jar
now checks the identity each call names against its own.

**`JSONValue` conversion has one set of rules now.** S4 and S5 each converted between Foundation and
`JSONValue` and disagreed about what was valid, so an integer past 2^53 entered a JS context
silently widened to a double while the same value through a host capability was refused.
`JSONValue.foundationValue` and `init?(converting:)` defer to `HostJSONValueConverter`. The
`nil`-returning shape of `init?(converting:)` is kept deliberately: its one caller formats error
details, where throwing would be perverse. **Only the rules are shared; the failure style stays at
the call site.**

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

- **Do not dispatch to `gpt-5.6-sol high` again without a specific reason.** Three exhaustions on
  one slice, each needing a human at the keyboard to clear, the last two producing nothing at all.
  That is the model choice failing, not luck. Treat it the way Opus high is treated.
- **A Claude subagent in an isolated worktree is a proven alternative to an Orca worker** for a
  self-contained slice. S7 was dispatched that way and delivered a complete, reviewable PR. It
  cannot stall on a provider prompt. **Use a worktree, not the main checkout.**
- **On a usage limit an Orca Codex worker parks at a prompt the CLI cannot answer.**
  `orca terminal send` refuses it with `agent_prompt_blocked` and there is no `worker-resume`, so it
  stays stalled however long ago the limit reset. Answer `2` (keep current model), or `3` to stop
  the reminder appearing — that third option is worth considering, since the reminder is what
  strands the worker, not the limit.
- Selectors need an `id:` prefix — `--repo id:<uuid>`, `--worktree id:<repo-id>::<path>`. The error
  names neither the flag nor the fix. `orca worktree rm` also accepts `path:<abs path>`.
- **`--from <coordinator handle>` is needed from the very first command.** Outside a live Orca
  terminal, `run-create` fails `no_active_sender_terminal`; later `worker-start`s fail
  `consumer_fenced`. Get the handle from `orca terminal list --json`.
- **Flag spellings differ per subcommand.** `worker-stop`/`worker-read`/`worker-abandon` take
  `--dispatch` and **reject** `--from`; `task-update` takes `--id`, not `--task`; `check` takes
  `--terminal`, not `--from`; **`run-show` takes `--id` and rejects `--terminal`.**
- **Split every parallel wave across providers.** Wave 1 lost both Claude workers to a session
  limit; Wave 2 lost its Codex worker three times. **Both providers have stalled a wave**, and every
  stall was silent.
- **Default `--model` to something cheap; make Opus high earn its place.** **Fable is not available
  on this account.**
- **A launched worker may sit at a confirmation prompt without ever starting**, reporting `ready`
  and `live` with only the seed message in its transcript.
- **`--setup skip` is rejected when the worktree already exists.**
- **Changing a worker's model means abandon, not stop.** `worker-abandon --dispatch <id>` →
  `task-update --from <coordinator> --id <task> --status ready` → a fresh `worker-start`.
- `check --wait` ending in `runtime_unavailable` is the app restarting, not a worker failure.
- **Start every independent worker before the first wait**, or the work serializes.
- **A `worker_done` is not a merge**, and it is not a green suite either.

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

## Gotchas

Re-verify any that becomes load-bearing rather than trusting this list.

- **A passing test is not evidence until you have seen it fail — and "it stopped compiling" is not
  seeing it fail.** Mutate the implementation and re-run. This has now found real gaps in three
  consecutive slices.
- **Count clauses, not tests.** A criterion is a sentence with several claims in it; a suite can
  cover the memorable ones and miss the rest. Criterion 5 names *HTTPS* origins and S5 tested origin
  membership thoroughly while testing the scheme not at all. **Mutate each clause separately.**
- **Identity stored and then discarded is a warning sign.** `_ = sourceID` meant a value was kept
  for a rule nothing enforced. Grep for `_ = ` before trusting that a type protects an invariant.
- **A test can pass for a reason other than the one its name claims.** Two Settings tests were green
  only because `SettingsView` reached past its injected registry to `SourceRegistry.shared`; two S7
  tests described behaviour the code did not have.
- **Grep the symbol, not the file you expect it in.** A Swift extension can put a type's API
  anywhere in the module; this cost two wrong analyses of `JSONValue.init?(converting:)`. It also
  hides from a *partial* grep: `JSONValue(converting:` misses the `JSONValue.init(converting:)`
  method-reference spelling, which was the only real caller.
- **Squash merges make the commit graph lie about what is merged**, and the lie reaches worktree
  cleanup: `git log origin/main..HEAD` in a merged branch's worktree shows its commit as unmerged.
  **Check the PR state before deleting anything** — `gh pr list --state all --head <branch>`.
- **Never run two `xcodebuild` invocations against the simulator at once.** A second produces
  `Executed 0 tests` plus a named failing test and a `DebuggerLLDB.DebuggerVersionStore.StoreError`
  — which looks exactly like a real failure and is not.
- **Do not pipe an `xcodebuild` run through `tail`.** Redirect the whole log to a file.
- **`app.debugDescription` in an assertion message is how UI-test failures become diagnosable.**
- **File:line citations rot within one session.** Cite living documents by *term or section*.
- **Changing an accessibility label silently breaks XCUITests.** CI now runs the two hermetic
  suites, so this class of break turns something red at last — but only for what those two cover.
- **The UI target is split, and only half is a merge condition.** `UpdatesUITests` and
  `SourcePreferenceUITests` are hermetic (fixture registry, isolated storage, no network) and run on
  every PR. Everything in `MangaCartaUITests.swift` is live and run by name. **Do not name live data
  in a test that does not measure it** — that was two of #134's three causes.
- **A bare accessibility query can match the wrong list.** Settings has two lists of source names;
  rows are namespaced `browseSource.` and `preferredSource.`.
- **CI is a major version behind local** — `macos-15` → Xcode 16.4 / Swift 6.0 vs local 26.x / 6.2.
  Treat isolated conformances, `nonisolated(nonsending)`, `@concurrent` and `Task.immediate` as
  unavailable. A `get throws` property and Swift Testing's `#expect(throws:)` returning the error
  both **do** compile there — verified by #159.
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
  fetchable directly.
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
- **A full CI run takes ~12 minutes.** `gh pr merge --auto` beats waiting.
- **Target the iPhone 17 Pro simulator** on every `xcodebuild` — it holds the seeded fixture.
- **Test totals come from the result bundle, not the log tail.**
  `xcrun xcresulttool get test-results summary --path <bundle>`.

## Repository state

- `main` at `add18b3`. Merged since the last handoff: #155, #156, #157, #158, **#159**.
- **No open PRs** other than the one carrying this handoff.
- `gh issue list`: **#90** (VoiceOver, ready-for-human), **#149** (MAL privacy label), **#150** (name
  clearance).
- **Branch protection requires three checks:** `Build & unit tests`, `SwiftLint`, and
  `Hermetic UI tests`.
- Unit suite: **977 tests, 972 passed, 0 failed, 5 skipped**, verified on merged `main`. SwiftLint
  clean.
- **Worktrees are clean for the first time in weeks — three, all wanted:** the main checkout;
  `~/orca/workspaces/Manga-Reader/phase3-s5-host-capabilities`, which can go now that #159 is
  merged; and `Manga-Reader-worktree-helper` at the repo root, unrelated, from 2026-08-21.
  `phase3-s4-jsc-runtime` and `.claude/worktrees/agent-af5301ec41c376ee6` were removed today, and
  `git worktree prune --dry-run` is empty.
- **Orca terminals: two.** The coordinator `term_15c0eb64-b03c-4606-add4-e337286e7ea7` — **record
  it**, every orchestration command needs it after a runtime restart — and one on the unrelated
  worktree helper. The four dead S4/S5 terminals were closed today.
- `docs/superpowers/handoff/` holds this file and `archive/` (79 archived handoffs plus its README).
  Two `.md` files at this level means someone skipped the rule.
