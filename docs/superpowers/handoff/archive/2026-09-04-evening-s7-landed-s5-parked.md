# Handoff — S7 landed, S5 still parked behind a prompt only a human can answer

Date: 2026-09-04 (evening)
Repository: `/Users/eliasmagdaleno/Manga-Reader` (directory unchanged; GitHub is
`eliasmagdaleno/MangaCarta`)
Branch: `docs/handoff-2026-09-04-evening`, off `main` at `7ba7c7b`.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## The roadmap

Six phases, ~8–9 weeks. The reasoning and the Paperback catalog research are in
`archive/2026-08-31-launch-roadmap-handoff.md`. **Read it once** rather than re-deriving it.

1. **Finish what is nearly done** — *two device tasks remain; no code is owed.*
2. **Host API design** — ✅ done (#130), its four contract gaps closed (#145).
3. **JavaScriptCore runtime + WeebCentral port** (~2w) — **Wave 1 done. Wave 2: S4 merged, S5
   parked. Wave 3: S7 open in #156, S6 blocked on S5.**
4. **Repo format + installer** (~1–1.5w).
5. **Theme engines** (~1w for Madara, then days each) — Madara alone is 29 sites.
6. **Launch prep** (~1w).

## Where Phase 3 stands — eight of twelve criteria closed once #156 merges

The plan is `docs/superpowers/plans/2026-09-03-phase-3-jsc-runtime.md`. **Spec Section 15's twelve
acceptance criteria are the definition of done**, each owned by exactly one slice. Briefs for all
seven slices now exist in that file — S6 and S7's were written and reviewed today (#153).

| Slice | Criteria | PR | State |
|---|---|---|---|
| S2 — domain wire schemas + adapters | 3, 4 | #137 | merged |
| S1 — manifest & declaration validation | 2, 9 | #139 | merged |
| S3 — WebKit isolation spike | 6 (cookies), 8 | #140 | merged |
| S4 — JSC runtime core + bridge | 7 | #144 | merged |
| S5 — host capabilities | 5, 6 (storage), 11 | — | **parked, uncommitted** |
| S7 — identity lifecycle | 10 | #156 | **open, auto-merge armed** |
| S6 — WeebCentral port + engine proof | 1, 12 | — | **blocked on S5** |

**Criteria still unowned by merged code: 1, 5, 11, 12** (plus 6-storage) — S5 and S6.

Unit suite: **959 tests, 954 passed, 0 failed, 5 skipped** on #156's branch. SwiftLint clean.

## What is owed

### 1. S5 is parked, and only a human can restart it

**Parked twice on 2026-09-04**, both times mid-write, on `gpt-5.6-sol high`. The second stall came
about **30 minutes after the first limit reset**. Next reset was 20:54 PDT. **The work is on disk
and uncommitted** in `~/orca/workspaces/Manga-Reader/phase3-s5-host-capabilities`:

```
 M MangaCarta.xcodeproj/project.pbxproj
 M MangaCarta/ContentView.swift
?? MangaCarta/Services/HostBrowser.swift
?? MangaCarta/Services/HostCapabilityTypes.swift
?? MangaCarta/Services/HostHTTPClient.swift
?? MangaCarta/Services/HostJSONValueConverter.swift
?? MangaCarta/Services/HostLogger.swift
?? MangaCarta/Services/HostStorage.swift
?? MangaCarta/Services/HostURLPolicy.swift
?? MangaCarta/Views/Components/ExtensionBrowserChallengeView.swift
?? MangaCartaTests/HostCapabilityTests.swift
```

Roughly 1,900 lines. **Nothing may rebase, checkout, or clean that worktree until it resumes.**

**Unsticking it needs a human at the keyboard.** On a usage limit the Codex worker parks at an
interactive prompt — *"Approaching rate limits. Switch to gpt-5.6-luna for lower credit usage?"* —
and **that prompt cannot be answered from the CLI**. `orca terminal send` refuses it with
`agent_prompt_blocked`, and there is no `worker-resume`. So a stalled worker stays stalled however
long ago the limit reset. **Answer `2` (keep current model)**, or `3` to stop the reminder
appearing at all — that third option is worth considering, since the reminder is what strands the
worker, not the limit itself.

Run `run_f1c064acb57c`, coordinator handle `term_15c0eb64-b03c-4606-add4-e337286e7ea7`, S5 dispatch
`ctx_296bc5d9671d`, worker terminal `term_6f0abcc8-1a88-4597-9cfe-9260023b9b61`. **Record those
handles** — after a runtime restart every orchestration command needs them.

**S5's design question was answered** (it asked, then acted on the answer; a later `reply` attempt
returned `answer_conflict`, which is how you can tell). The `JSONValue` guidance stands: it lives
on `main` at `MangaCarta/Models/JSONValue.swift`, landed by S1/S2, and S5 declares no second copy.

### 2. The one thing S5 must settle before it merges

**`HostJSONValueConverter.convert` and S4's `JSONValue.init?(converting:)` accept different
values.** This was mis-analysed twice today before being got right; do not re-litigate it from
memory, the table below is the checked version.

| | direction | on failure | owner |
|---|---|---|---|
| `JSONValue.init?(converting:)` | Foundation `Any` → `JSONValue` | returns `nil` | S4, **in `ExtensionRuntime.swift`** |
| `HostJSONValueConverter.convert(_:)` | Foundation `Any` → `JSONValue` | throws, with a message | S5 |
| `HostJSONValueConverter.validate(_:)` | checks a `JSONValue` | throws | S5, no S4 equivalent |
| `HostJSONValueConverter.foundationValue(_:)` | `JSONValue` → Foundation `Any` | throws | S5, **reverse direction** |

Two thirds of that file is new work with nothing to duplicate. **The collision is `convert`, and
the problem is not that two functions exist — it is that they disagree about what is valid.** S5's
caps nesting at depth 128, rejects integers outside ±2^53−1, and rejects non-finite numbers. S4's
does none of that: no depth limit, and an out-of-range integer silently becomes a `.double`.

`init?(converting:)` has exactly one caller — `ExtensionInvocationError.details` — so consolidating
is cheap. Left alone, the runtime and the host capabilities disagree about which values may cross
the extension boundary, and a Source finds out at runtime.

**How this was got wrong twice, because the same trap is still there:** #151 claimed the initialiser
did not exist, having grepped only `JSONValue.swift`. S4 declares it in an `extension JSONValue`
inside `ExtensionRuntime.swift`. #154 retracted that. **Grep the symbol, not the file you expect it
in** — a Swift extension can put a type's API anywhere in the module.

### 3. Supervision protocol, unchanged and still load-bearing

When a slice reports done, in this order:

1. `git -C <worktree> status` and the terminal preview — **the dispatch status lies.**
2. Rebase onto `main` and expect a `project.pbxproj` conflict if a peer landed first; the
   resolution is **keep-both**.
3. Re-run the **full** `MangaCartaTests` bundle after that rebase and read the totals from the
   result bundle.
4. Only then merge, and check the PR body names a test per acceptance criterion it claims.

**Add `orca orchestration check --terminal <handle> --types question` to every supervision pass**,
not just the pass after a `worker_done` — a worker can block on its own question while heartbeating
`live`. Note that `check` does not reliably mark a question read: S5's answered question kept
re-surfacing all day. An `answer_conflict` from `reply` is the reliable signal that one was already
handled.

**Keep supervision cheap.** The default pass is `check` plus `git -C <worktree> status -sb`. A full
`worker-read` returns whole transcripts; read one only to diagnose a stall.

**Review by mutation, not by reading.** Established twice today, both times finding something:

- A worker's claim that it "watched the test fail" may mean *the target stopped compiling with the
  implementation stashed*. **That is not evidence.** A compile error says nothing about whether an
  assertion discriminates. Delete or invert a line of the implementation and re-run instead.
- Doing that to #156 failed exactly one test — the right one — and revealed **two tests whose names
  claimed properties the code did not have.** See item 4.

### 4. #156 — S7, open with auto-merge armed

`SourceLifecycleRegistry`: the disable/uninstall/reinstall state machine for installed Sources,
keyed exclusively by `QualifiedSourceID`, reusing `SourceDeclarationValidator.validateUpdate`
rather than reimplementing the identity rule. Owns criterion 10. 15 tests; full suite 959/954/0/5.

Reviewed by mutation. Deleting the `validateUpdate` call from `reinstall` failed exactly one test —
`testReinstallWithChangedLocalIdUnderSameQualifiedIdIsRejected`, the one carrying the identity
invariant. Two tests survived, and each survived because it was misnamed; both renamed in `bc7a912`:

- One **asserted the opposite of its name.** A declaration with a different `qualifiedId` lands
  under a different dictionary key, so it is accepted as a fresh registration and `validateUpdate`
  is never consulted. Nothing is rejected.
- One **never called `reinstall` at all**, despite a name claiming reinstall goes through the
  validator. `reinstall` does not call `validate`.

**A gap left open deliberately, and recorded rather than assumed:** the brief says reconnection must
revalidate rather than trust a cached declaration. That is half met. The missing half is narrow —
`SourceDeclaration.adult` is non-optional, so an adult-less declaration cannot exist as a typed
value. What is genuinely unenforced is that a caller validated **at all**: `SourceDeclaration` has
only the internal memberwise initialiser, so a hand-built one bypasses the validator. Closing it
means `reinstall` taking raw JSON. Out of scope for S7; **someone should decide whether it is in
scope for Phase 4's installer**, which is the only thing that will ever construct these.

### 5. #155 — CI skips the heavy work for documentation changes

Open, auto-merge armed. Three docs-only PRs today each ran the full build, unit suite and hermetic
UI suite; this makes a docs change cost about fifteen seconds.

**It is not `paths-ignore`, and that is the whole point.** `Build & unit tests`, `SwiftLint` and now
`Hermetic UI tests` are **required status checks**. A workflow filtered with `paths-ignore` does not
run on a docs-only PR, so those checks never report — and a required check that never reports leaves
the PR blocked forever, with `gh pr merge --auto` waiting indefinitely. So every job still **runs**
and still **reports**; a `changes` job diffs against the merge base and each expensive step is
guarded on its output. The jobs also drop to `ubuntu-latest` when there is no code to build.

Conservative on purpose: a new branch, a force-push whose old head is gone, and an empty diff all
count as a code change.

**Its docs-only path has never actually run.** #155 edits `ci.yml`, which is not documentation, so
it takes the code path. **The first docs PR after it merges is worth a glance at the `changes` job
log** — the failure mode to watch for is a green check that skipped something it should have run.

### 6. Live-verify MAL progress push — the user's to run

Built, wired, tested (`MALProgressCoordinator`, `MALProgressOutbox`, the Settings toggle and queue
status). What no unit test can show: **sign in on a device, read a chapter to the end, and confirm
the number moves on myanimelist.net.** `scripts/mal_live_write.py` pokes the API directly if the
in-app path needs isolating.

`testLiveHorimiyaCompletionPushesProgress` is gated behind `TEST_RUNNER_MAL_LIVE_WRITE=1` and skips
by default.

### 7. The manual VoiceOver pass — #90, the user's to run

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

Items 6 and 7 both want a device in hand; doing them in one sitting is worth more than doing them
well apart.

### 8. Naming debt, small and deliberate

`-uitest-updates-state` seeds a fixture that has nothing to do with updates (`two-listings`). One
seeding path with isolated storage was judged worth more than a tidier spelling; rename it if a
third unrelated state appears.

## Launch blockers that are not features

- **No app icon.** `AppIcon.appiconset/` holds only `Contents.json`. Being outsourced — **order it
  early so it is not the long pole.** Unchanged across **eight** handoffs now. This is the one
  blocker that cannot be compressed by working harder later. It needs the *MangaCarta* name on it.
- **The MAL privacy-label recheck — #149.**
- **The name — #150.** First pass done: no App Store app is named MangaCarta and no trademark
  surfaced, but *Magna Carta* is live in software (Magna Carta Technologies LLC, AR software) one
  letter away, and examiners weigh sound and appearance. Not a clearance search.
- **Adult-source gating** — settled by ADR-0022. Not a blocker, just a thing not to undo.
- No listing screenshots, privacy-policy URL, App Store description, or TestFlight run.

## Dispatch mechanics

```sh
orca orchestration run-create --from <coordinator handle> --objective "<objective>" --json
orca orchestration task-create --from <coordinator handle> --spec "<full brief>" --json
orca orchestration worker-start --from <coordinator handle> --task <id> \
  --worktree id:<repo-id>::<path> --agent <codex|claude> --model <id> --effort high --json
orca orchestration check --terminal <coordinator handle> --types worker_done,escalation,question --json
orca orchestration reply --id <msg_id> --from <coordinator handle> --run <run_id> --body "<answer>"
orca worktree rm --worktree path:<abs path> --json
```

Each of these cost real time when it was learned.

- **A Claude subagent in an isolated worktree is now a proven alternative to an Orca worker** for a
  self-contained slice. S7 was dispatched that way and delivered a complete, reviewable PR. It
  cannot stall on a provider prompt the way an Orca Codex worker can, and it reports back directly.
  **Use a worktree, not the main checkout** — the briefs agent ran in-place and left the main
  checkout sitting on its branch, which is harmless for docs and would not be for code.
- Selectors need an `id:` prefix — `--repo id:<uuid>`, `--worktree id:<repo-id>::<path>`. The error
  names neither the flag nor the fix. `orca worktree rm` also accepts `path:<abs path>`.
- **`--from <coordinator handle>` is needed from the very first command.** Outside a live Orca
  terminal, `run-create` itself fails `no_active_sender_terminal`; later `worker-start`s fail
  `consumer_fenced`. Get the handle from `orca terminal list --json`.
- **Flag spellings differ per subcommand.** `worker-stop`/`worker-read`/`worker-abandon` take
  `--dispatch` and **reject** `--from`; `task-update` takes `--id`, not `--task`; `check` takes
  `--terminal`, not `--from`; **`run-show` takes `--id` and rejects `--terminal`.**
- **Split every parallel wave across providers.** Wave 1 lost both Claude workers to a session
  limit; Wave 2 lost its Codex worker to a usage limit, twice. **Both providers have now stalled a
  wave**, and every stall was silent.
- **Default `--model` to something cheap; make Opus high earn its place.** **Fable is not available
  on this account.**
- **`gpt-5.6-sol high` burns the Codex quota very fast — use it sparingly.** It exhausted the limit
  twice in one day on S5 alone. Treat it the way Opus high is treated. Each exhaustion costs hours,
  because the resulting prompt needs a human (item 1).
- **A launched worker may sit at a confirmation prompt without ever starting**, reporting `ready`
  and `live` with only the seed message in its transcript.
- **`--setup skip` is rejected when the worktree already exists.**
- **Changing a worker's model means abandon, not stop.** `worker-abandon --dispatch <id>` →
  `task-update --from <coordinator> --id <task> --status ready` → a fresh `worker-start`.
- `check --wait` ending in `runtime_unavailable` is the app restarting, not a worker failure.
- **Start every independent worker before the first wait**, or the work serializes.
- **A `worker_done` is not a merge**, and it is not a green suite either.

## Gotchas

Re-verify any that becomes load-bearing rather than trusting this list.

- **A passing test is not evidence until you have seen it fail — and "it stopped compiling" is not
  seeing it fail.** Mutate the implementation and re-run. This found real defects twice today.
- **A test can pass for a reason other than the one its name claims.** Three instances today: two
  Settings tests green only because `SettingsView` reached past its injected registry to
  `SourceRegistry.shared`, and two S7 tests whose names described behaviour the code did not have.
- **Grep the symbol, not the file you expect it in.** A Swift extension can put a type's API
  anywhere in the module; this cost two wrong analyses of `JSONValue.init?(converting:)`.
- **Never run two `xcodebuild` invocations against the simulator at once.** A second produces
  `Executed 0 tests` plus a named failing test and a `DebuggerLLDB.DebuggerVersionStore.StoreError`
  — which looks exactly like a real failure and is not.
- **Do not pipe an `xcodebuild` run through `tail`.** Redirect the whole log to a file.
- **`app.debugDescription` in an assertion message is how UI-test failures become diagnosable.**
- **Squash merges make the commit graph lie about what is merged.** The PR state is the only
  reliable check.
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
  unavailable.
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

- `main` at `7ba7c7b`. Merged today: #144, #145, #146, #147, #148, #151, #152, #153, #154.
- **Open PRs: #155** (CI docs skip) and **#156** (S7), both with auto-merge armed.
- `gh issue list`: **#90** (VoiceOver, ready-for-human), **#149** (MAL privacy label), **#150** (name
  clearance). **#134 is closed.**
- **Branch protection now requires three checks:** `Build & unit tests`, `SwiftLint`, and
  `Hermetic UI tests`. The third was added today — #148 shipped the job, but nothing made it gate
  anything until it was added to protection.
- Unit suite: **959 tests, 954 passed, 0 failed, 5 skipped** (on #156). SwiftLint clean.
- Worktrees: `~/orca/workspaces/Manga-Reader/phase3-s5-host-capabilities` **holds live uncommitted
  work — do not touch it.** `phase3-s4-jsc-runtime` is merged and removable.
  `.claude/worktrees/agent-af5301ec41c376ee6` holds S7's branch and can go once #156 merges.
  `Manga-Reader-worktree-helper` at the repo root is unrelated, from 2026-08-21.
- `docs/superpowers/handoff/` holds this file and `archive/` (78 archived handoffs plus its README).
  Two `.md` files at this level means someone skipped the rule.
