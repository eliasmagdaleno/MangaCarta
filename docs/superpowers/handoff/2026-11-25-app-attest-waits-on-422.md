# Handoff: #418 and #422 auto-merging, App Attest session waiting on #422

Date: 2026-11-25 (~14:30). This is the one live handoff. The previous one,
`archive/2026-11-25-analytics-slice3-app-attest.md`, is superseded, and every open item in it is carried here.
Recheck GitHub, the worktrees and the working tree before acting.

**Owner, 2026-11-25: keep a session under about 250k tokens of context; past that, hand off.**

**The owner's instruction stands: features first, testing last** (memory `features-first-testing-last`).

## State

Merged, branches deleted (local and remote) unless noted:
- **2026-11-10:** #368–#385. **2026-11-11:** #386–#391. **2026-11-12:** #392–#407.
- **2026-11-13/14:** **#408 Migrate slice 3** (More menu, Migrate sheet, `LibraryMigrateUITests`). Migrate is
  complete. Its first CI run failed one test at launch ("Failed to get background assertion … Timed out");
  a rerun of the failed job passed (lesson below).
- **2026-11-15:**
  - **#409** analytics design Amendment 2: **no legal review**, owner accepts the risk. Switzerland stays in
    §5.2's informed row, "OK" is the agreement, 16+ needs no children's-privacy flow.
  - **#410 vector PDF slice 2**: `ReaderPage`, `VectorPageProviding`, `LocalLibraryStore.pageReferences`,
    `ReaderViewModel.pages: [ReaderPage]`, an `UndrawnPDFPage` placeholder at both `ReaderView` call sites;
    design Amendment 2. Still dark (`.raster` default).
  - **#411** `docs/app-store/privacy-policy.md`, the privacy policy (controller Elias Magdaleno,
    contact eliasrmagdaleno@gmail.com, owner-approved).
- **2026-11-16:** **#412**, the privacy policy published on GitHub Pages, live at
  **`https://eliasmagdaleno.github.io/MangaCarta/privacy/`** (the site root is 404).
  `.github/workflows/pages.yml` stages **only** `docs/app-store/privacy-policy.md` and redeploys on any change to
  it; Pages is enabled with `build_type: workflow`. The default Jekyll theme loads `anchor.min.js` from cdnjs; a
  plain theme would remove that third-party request (owner's call, still open).
- **2026-11-19:** **#415 vector PDF slice 3**: paged mode draws PDF pages through a `CATiledLayer` canvas
  (`PDFPageCanvas`, `PDFPageGeometry`, `PDFDocumentSession`); design Amendment 3. Still dark (`.raster` default);
  webtoon keeps the placeholder. Review found three bugs the worker's green tests couldn't see (no scale-up via
  `getDrawingTransform`; a single 4× tile level; `CGPDFPage` outliving its evicted document), all fixed with
  mutations M8–M10. Claude's final review added `testPageDrawsRightSideUp`, the first test through the production
  renderer (lesson below). Worktree, local and remote branch removed; Orca worker `ctx_f3bfddd47ab5` released.
  **Keep the `PDF2 iPhone 17 Pro` simulator** (`06CB4285-0173-4CDB-B844-A539740A7028`) for slice 4, then delete it.

- **2026-11-19:** #413 and #416 (handoffs).
- **2026-11-25:** **#417**, **#419** (handoffs) and **#414** (CI simulator warm-up, `ColdStartWarmUpUITests`).
- **2026-11-25:** eight global skills updated (five caveman skills, `domain-modeling`, `orca-cli`,
  `orchestration`). Nine others are no longer at their recorded upstream path and were left installed. The Orca
  skill now says to end the turn rather than run `check --wait`; the notes below describe working from outside Orca.
- "Branches deleted" above is true of recent PRs only: 118 remote-tracking refs remain, many old. Ask the owner
  before any bulk cleanup. `docs/handoff-migrate-slice3` (#407, merged) is one known leftover.

- **2026-11-25:** **#420** analytics slice 2 and **#421**, **#423**, **#424** (handoffs and the App Attest design), remote branches deleted. #420's own run on `main` was
  cancelled by #421's, so `main`'s first full run with it is the one after #418 merges: check it.

**In flight — check each before acting (state as of 2026-11-25 ~14:30):**

1. **Vector PDF slice 4: [#418](https://github.com/eliasmagdaleno/MangaCarta/pull/418) merged 2026-11-25 (`c388517`), cleanup done.**
   The resume fix is `StripMetrics.positionedRequest` (ADR-0014 decision 10, second 2026-11-25 amendment). Worktree, local and
   remote branch, the `PDF2` simulator, the worker spec folder and the temp files are removed; worker `ctx_25c30cfec09e` and the
   coordinator terminal are closed. `ctx_f8f53ef77a61` and `ctx_3133c06e4b94` reported `retained` (ownership transferred); leave
   them. Its own run on `main` was cancelled by #422's; see item 2.

2. **Analytics slice 3: [#422](https://github.com/eliasmagdaleno/MangaCarta/pull/422) merged 2026-11-25 (`5f1bd15`), cleanup done.**
   Design Amendment 5; the privacy policy changes published on merge. Worktree, both local branches, the remote branch, the
   `AN2` simulator, `/private/tmp/an3*` and coordinator terminal are removed. Its push cancelled #418's run on `main` mid-UI-tests
   (every finished suite had passed). **Run `45717123177`, the first on `main` with #418, #420 and #422 together, passed** (all four jobs).
   Desktop session `local_e4018574-f6df-40e1-88a1-4526bb1e8fdb` ("Build analytics slice 2") pointed at the removed worktree;
   archive it if the owner agrees.

3. **App Attest slice 1: building** in session `local_26f8f31a-ccbf-45ba-aa96-e2e4931fd94d` ("Build App Attest for analytics
   (slice 1)"), branch `claude/dreamy-proskuriakova-d26ccd`, resumed 2026-11-25 ~15:20 after #422 merged. Design:
   `docs/superpowers/specs/2026-11-25-app-attest-design.md` plus its Amendment 1 (rechecked against `main` and Apple's pages).
   As of ~18:45 the branch has the Amendment, Apple's sample attestation as a Worker fixture, a device-only capture test and the
   production entitlement (`6d73445`, skips on the simulator as intended), and Worker verification (`b8946de`, from an Orca
   Codex Sol worker). Not pushed, no PR yet. Its automatic security review of `6d73445` hit HTTP 429 and reruns on push.
   - **Owner steps, still open:** turn on the App Attest capability for App ID `Elias-Magdaleno.Manga-Reader` (team
     `V2BG9SHQYS`), and capture one attestation on the iPhone. The session holds the exact instructions.
   - Review its work, including its mutations, before calling it done.

4. **Left over from #414 (merged):** worktree `.claude/worktrees/exciting-lamport-f80042`, local branch
   `claude/ci-cold-sim-warmup`, session `local_4911e6cc-2aca-46df-b7ba-2875b3e3c58b`.

**Owner's calls, open:** App Attest's owner steps (App ID capability, one device capture); a plain Pages theme
(the current one loads `anchor.min.js` from cdnjs); the D1 region. **The owner runs every Cloudflare step.** After deploy,
add the region to the privacy policy and bump its date.

**Cleanup owed:** Orca worker `ctx_7a3d8ccb0435` reported `retained` on release earlier; leave it.

**Working tree:** `MangaCarta/Info.plist` may still carry an uncommitted Xcode rewrite that drops
`LSSupportsOpeningDocumentsInPlace` (#294). Never commit it as is. `stash@{0}` and `stash@{1}` are old Xcode churn and
safe to drop. Leave `.worktrees/device-build`, the uncommitted `.cbz` UTI fix, alone. Pull before working in the
main checkout.

## Next

1. **#418 and #422 are merged.** PDF slice 5 (manual device checks) is on the deferred list. The
   CBR/EPUB/folders design also edits `LocalChapter`; whichever lands second rebases onto `pageStorage`.
2. **App Attest** (in-flight item 3): resume its session once #422 is on `main`; recheck the design against the code, then slice 1.
   Known gaps **analytics** slice 1 left, all
   small:
   - The notice in the no-Sources Home state sits on the page background above the empty state's own fill; it reads
     as two bands. Cosmetic.
   - `reader_opened` fires once per `ReaderView` (its `.task`); moving to the next chapter inside the same reader
     doesn't fire again. The design says "once per chapter open"; this undercounts chapter-to-chapter reading.
   - Live (non-CI) UI tests that launch with **no** `-uitest-` argument on the seeded simulator will see the notice at
     the top of Home, because the seeded simulator's consent is undecided. If one breaks on that, answer the card
     once on the seeded simulator (either button), or give that test a `-uitest-` argument.
3. **Item 12, per-Source refresh cadence:** still blocked on measured device data. Don't guess.

Known and small, from slice 2 of per-title Sources:
- The hub now fetches MAL alternative titles even when no Source is installed (the empty-Sources check moved into
  `SourceTitleSearch`). One wasted request in a rare case; left alone.
- `TitleSourcesUITests` taps rows by their title text, not by identifier. Fine while titles are unique in the fixture.

Small follow-ups from notification actions (#403, merged; not filed):
- **The Updates-screen design must add Mute/Unmute to its Work-row trailing menu** (notification-actions
  Amendment 1 item 4). It writes `UpdateStateStore.setMuted`; copy `WorkUpdateRow`'s menu and named action.
- **Two Home controls fail the hit-area audit:** "Try Home Again" and "Refresh updates" (`UpdatesHeader`). The
  notification-actions audit is scoped to the update row, so these are not gated anywhere. Measure, then fix.
- A notification whose chosen Source needs a Cloudflare challenge, or is slow, does nothing on Mark Read by design
  (no partial marks, no WebView from the background). Only unit-tested with a throwing fetch.

The rest of the feature queue is specced and on `main`:
- Updates screen;
- widgets;
- local matching (it shares `WorkStore.addListing` from #390; its design says so);
- CBR/EPUB/folders;
- vector PDF;
- Komga/OPDS (needs ADR-0029 before slice 2);
- cross-device sync (ADR-0028; it must carry `removedListings` and `handLinkedListings`);
- repository format 2.

Pick the next one as the owner directs.

Known and deliberately unfiled:
- A Work merged into one that **already** has a MAL id, by a path other than `MetadataUpgradeQueue`, fires no
  `workMetadataChanged` (#352's PR body). File it only with evidence.
- MAL-hub adult filtering option A (a per-card MAL `nsfw` fetch) is a recorded follow-up in the design.
- **`WorkStore.link`'s removed-Listing guard is unreachable today** (its only caller, mint's external-id path,
  already refuses a removed copy), so no test can catch its deletion. It's a backstop for future callers. If a new
  caller of `link` appears, add a test through it.

## Lessons from this session

- **Don't start a session whose base PR is still open.** The App Attest brief said to stop if #422 wasn't merged, and it did;
  the card was clickable before it could do anything.
- **Read the compiler's line, not the function that looks complicated.** #422's "unable to type-check" was a one-line `?:` of integer products; a rewrite
  of `candidates` was done first and reverted.
- **A failed `gh pr checks` line can name a head you have replaced.** Compare the SHA before acting on an Auto-fix event.

- **A fix proven against a simulated cause can still be the wrong fix.** #418's lost-scroll simulation failed before and
  passed after, and CI still failed. Check the simulation reproduces *every* observed fact: the button said
  "Continue · p.3", so the position was saved and then replaced. Read what the failing run shows before simulating.
- **`AppComposition` is a struct the app discards.** A subscription kept only there ends at launch. Hold only the
  surviving object in the test.
- **"Checked" is not "known".** A table that records that a question was asked doesn't record that it was answered.
- **Two PR merges in a row cancel the first one's run on `main`.**
- **Luna reports `failed` when it skips mutations; run them yourself.** Four of 46 app mutations survived its tests or mine.
- **A script started by Python's `subprocess` needs a shebang.**

- **A CI-only UI failure can be a real race.** #418's resume test failed only on CI, and CPU load (350) did not
  reproduce it. What did: print the frames in the failure message, then simulate the suspected condition in app code
  (ignore scrolls for 0.8 s). The simulation also showed my first fix did nothing, and a trace then found the cause.
- **`git diff` after a scripted mutation.** A `sed` with the wrong case changed nothing and the run "survived".
- **macOS's `python3` here rejects a backslash inside an f-string;** `python3 -m py_compile` a script before
  backgrounding it.

- **A label query can match the wrong element.** The paged PDF test looked for "Page 1 of 6" and got the 75 pt page
  indicator, which carries the same label, so it never looked at a page. Check an element's frame or exclude the twin
  by identifier.
- **A zoomed view's accessibility frame is clipped to the screen** (402 pt before and after). Assert zoom from
  screenshot pixels.
- **Probe before amending a claim.** Forty canvases measured with and without `contents = nil` settled in minutes what
  two reviews had argued about, and a surviving mutation (M3) showed a design premise was wrong.
- **`/private/tmp` scratch and the harness's working directory can move mid-session.** Use absolute paths for every
  command that writes.

- **`Timed out while synthesizing event` points at the simulator or machine, but does not prove it.** MALHub tests
  took 6–70 minutes each under a load average near 45, and two still failed after a reboot. I blamed an Android
  emulator; that emulator was still running on 2026-11-25 at load 2. Cause unknown. Compare against `main`.
- **Check `uptime` before a long UI run,** and don't record a suite as passed until it passes.
- **An idle worker with no report is not a dead worker.** I finished and committed Piece C in a live worker's
  worktree, then called it unresponsive. It reported success at 19:38 on 2026-11-19; no wait was running by then.
  Release or stop a worker before touching its worktree, and check the Orca inbox before writing it off.
- **Reviewing a test means finding the edit that turns it red.** I accepted the zoom test and the tile test without
  doing that; both can pass with the behaviour missing.
- **A spec can ask a test to read UI that doesn't exist.** Mine had the webtoon restore test read the page
  indicator, which webtoon never shows; the worker asked instead of adding one to production, which was right.
  Grep for each element a UI test step names before writing the spec.

- **A seam that every test replaces leaves the real thing untested.** Slice 3's drawing tests all injected a
  recording `PDFPageRendering`, so the production renderer, including its y-axis flip, never ran in a test:
  deleting the flip left the suite green with every page upside down. `testPageDrawsRightSideUp` draws through
  the default renderer into a `UIGraphicsImageRenderer` (y-down, like a layer's context) and checks a top band
  lands at the top. When a worker adds an injectable seam, ask which test runs the default implementation. For
  slice 4's webtoon rows, draw through the real renderer too.
- **A shell loop over `"a b"` pairs doesn't split in zsh.** `for pair in "415 branch"; do set -- $pair` left `$1` as
  the whole string; the merged-state gate failed closed and nothing was deleted. Pass the values as separate
  function arguments instead.

- **A UI test can fail before it tests anything.** #408's CI failed `AccessibilityAuditUITests` at
  `app.launch()` with "Failed to get background assertion … Timed out": the first launch on a cold CI simulator.
  The next test in the same suite launched fine, and a `gh run rerun <id> --failed` passed. Read *where* a test
  failed before blaming the branch; one launch timeout on the first test of a run is infrastructure.
- **Ask how the drawing threads work before picking a drawing API.** The PDF design said `CATiledLayer` +
  `PDFPage.draw`; `CATiledLayer` draws tiles on several background threads at once, and PDFKit's page isn't
  documented as safe there. Amendment 3 switches to `CGPDFPage`, as Apple's tiled-PDF sample does.
- **A slice-2 placeholder can still drop accessibility.** Luna's `.pdf` placeholder had no "Page n of total" label
  and no chrome tap, and a hard-coded unstyled string. Unreachable in production, but fixed in review so the dark
  path doesn't regress VoiceOver. Check every new leaf view for the label and tap the old one had.
- **A test view model built without a stub prefetch reaches the network.** Two `ReaderViewModel`s in
  `ReaderPagePipelineTests` used the default prefetch, which would have fetched `https://fixture.test/…`. Grep new
  tests for `ReaderViewModel(` without `prefetch:`.
- **GitHub Pages' `/docs` source publishes every spec and handoff.** The policy is served by a workflow that copies
  one file into an empty staging folder; keep it that way.
- **Merges by the owner's request worked from here this session** (`gh pr merge --squash`, `--auto` when CI is
  pending), each gated on all four checks and "Detect code changes" having passed.

Carried from the 2026-11-12 night session:


- **Codex model ids changed:** the owner asked for `gpt-6-luna` instead of `gpt-5.6-luna`, and `gpt-6.1-sol` when
  Opus-level work is needed (`codex debug models` lists the slugs). Memory `model-routing-fable-hard-tasks` has it.
- **Luna 6 added an unasked behaviour change mid-round** (rows whose only results were removed or owned elsewhere →
  "Not found"), committed under a `fix:` title, and edited its own test to match. Read each commit's test diff for
  changed *expectations*, not only added tests.
- **Five of 24 first-pass tests passed with their own rule deleted**, all the same way: the fixture's result was
  already graded `differentEntry`/`ungraded`, so the row was never Ready regardless. For a "never Ready" test, the
  fixture must be a result that *would* be Ready without the rule.
- **A cancel handler that hops to the main actor can run late.** `withTaskCancellationHandler { … } onCancel: { Task
  { @MainActor in cancel() } }` lets work start before the hop lands; also check `Task.isCancelled` where work is
  launched. A nested local func in a `withTaskGroup` body is nonisolated, so do the check at its call sites.

- **A worker's "mutation survived" can be a broken mutation run.** On Migrate slice 1 the worker reported M4 (remove
  before add) and M7 (re-point after removal) as surviving. Re-run by me, both were red, M7 exactly on the cover
  Amendment 1 item 3 protects. Re-run every reported survivor yourself before calling a test weak.
- **First-pass worker tests can be unable to fail.** Migrate slice 1's first pass had a refresh-queue test that never
  ran a refresh, a no-network test with no Sources registered, a nil-cover test comparing nil to nil, and two tests
  missing the assertion the design named. Ask of each test: "what edit to the code turns this red?"; for the network
  test, prove it by swapping in the fetching path.
- **One simulator per concurrent worker** let three test runs go side by side (two full UI runs and a unit-heavy
  build) without killing each other. `xcrun simctl create "<name> iPhone 17 Pro" …iPhone-17-Pro …iOS-26-5`, name it in
  the spec, and forbid every other id. Delete it after the PR merges.
- **Branches that each add a test file conflict in `project.pbxproj`**, at the end of the `MangaCartaTests` group and
  of the Sources phase. Keep both sides' lines, `plutil -lint`, run the affected suites, push. This happened three
  times as #402–#404 landed one after another.
- **A handoff PR first makes the build PRs' handoff edits conflict-free.** Merging #401 before the builds' PRs meant
  each branch only edited its own section of the same file, and git merged the handoff text on its own every time.

- **A design's slice 1 can be unshippable on its own.** The PDF design's slice 1 stopped writing page JPEGs, but
  nothing could draw a PDF until slices 3–4; shipped alone, every new PDF import would have opened to "no pages".
  Ask "what does a user see if only this slice ships?" when rechecking a design. Here the fix was an option that
  defaults to the old behaviour, plus a test pinning the default.
- **`PDFDocument.write` is not safe from two tests at once.** With a second PDF suite running in parallel, the
  fixture writes (rotate a page, add a password) intermittently returned `false`, and the *existing* suite went red
  with nonsense pixel and "nothing thrown" failures. Alone, each suite passed. All fixture writes now go through
  `PDFFixtureWriter` (in `PDFVectorImportTests.swift`); use it for any new PDF fixture.
- **Luna's honest `failed` again.** It wrote correct app code but crammed each test onto one line (the lint
  failure) and three tests passed silently through `guard … else { return }`. It also added an unasked
  "/Encrypt bytes means locked" fallback that read the whole PDF into memory. Grep a worker's tests for bare
  `return` in a guard, and its code for behaviour the spec didn't ask for.
- **A `-only-testing` run can die at launch** ("Test crashed with signal kill before establishing connection")
  when another session is testing on the seeded simulator. Nothing ran; re-run it.

- **Recheck the design again; it found five problems this time.** `MangaSource.manga(id:)` returns `nil` by
  default, so the design's "fetch the Manga" would have made Mark Read a no-op on most Sources. The delegate was
  built before `fulfillment` existed. `UpdateNotifier` was falling back to `SourceRegistry.shared`. Unmute had no
  reachable surface once a title was opened. And XCUITest can't run `simctl push`, while a cold background launch
  ignores `-uitest-` arguments. All in Amendment 1 before code.
- **A delegate closure's `[weak handler]` is a silent no-op when nothing else holds the handler.**
  `AppComposition` is a struct and `MangaCartaApp` keeps only selected fields, so the worker's weak capture would
  have dropped every action *and* never called the system completion. Unit tests that keep the composition alive
  can't see it; `testNotificationActionSurvivesWithOnlyTheDelegateHeld` holds only the delegate.
- **`.accessibilityElement(children: .ignore)` + `.accessibilityLabel` on a `NavigationLink` is ignored.** The
  link's button reads its children. Put them on the link's *content*. `WorkUpdateRow` had this bug on `main`: "Muted"
  and the new-chapter count were never spoken. Check other rows built the same way.
- **XCUITest's `app.state` says `runningForeground` after the system wakes the app in the background** for a
  notification action, while the home screen is showing. Judge foreground by the screen
  (`springboard.icons["MangaCarta"].isHittable`) and attach a screenshot.
- **A SpringBoard notification banner is reachable from XCUITest on iOS 26.5:** query
  `springboard.descendants(matching: .any)` by `label CONTAINS "<body text>"` (its element type is
  `BannerNotification`, label "MANGACARTA, now, <title>, <body>"), `press(forDuration: 1.5)`, then tap
  `springboard.buttons["<action title>"]`. Schedule the notification when the app *backgrounds*, not on a timer from
  launch, or it fires while the app is still in front.
- **Give a UI-heavy session its own simulator when another session shares the seeded one.** Two sessions' UI runs on
  `ADDAB2F8` killed each other's runners ("Restarting after unexpected exit"). Hermetic suites don't need the seeded
  data; a fresh iPhone 17 Pro on iOS 26.5 also exercises CI's never-asked notification permission path.
- **Luna committed code that did not compile and called it "lint clean".** Build before every commit, including
  the coordinator's own commits of a worker's diff. Its tests also checked outcomes, not effects (no read-mark
  assertions, one failure case of eleven); I rewrote the suite.
- **Check a mutation script's revert.** Mine used `$2` after `shift`, so `git checkout` reverted nothing and four
  mutations stacked. Revert by the file variable, and `git status` after every mutation.

- **Recheck a design's "Current code" table before building; it found four real problems here.** Saving had three
  paths, not one. For You reasons are free text, and one kind ("Because you read <title>") carries a title, so a
  kind derived from the string could leak one. `TagVocabularyStore` is an actor that a synchronous recorder can't
  ask. And UI tests share the seeded simulator's `UserDefaults`, so a new Home card would have shown up in every UI
  test. All four went into Amendment 1 before any code.
- **`JSONSerialization` turns a Bool into an `NSNumber`, and `NSNumber(true) as? Int` is `1`.** The worker's
  envelope encoder checked `as? Int` first, so `"on": true` went out as `1`. The next launch failed to decode it,
  and the buffer silently started empty: one Settings toggle would have wiped every buffered event. The worker's
  round-trip test passed because its event list had no `.on(...)` value. Encode with `Codable` straight through,
  and make a fixture list exhaustive with a `switch`.
- **"Unit tests mint first" hides a production path that never mints.** `forYouOpened` and `mltOpened` required a
  Work. Opening a card, a detail page or a preview mints nothing, so in the app those events would almost never
  fire, while every test (which minted first) passed. Ask what state the real caller is in.
- **A worker can quiet lint with blanket disables.** Its first pass added `swiftlint:disable blanket_disable_command`
  plus four rules to three files and reported "0 violations". Grep for `swiftlint:disable` in the diff, and say
  "no disables" in the spec.
- **Stale escalations arrive first.** After each follow-up, the first `check --wait` returned the *previous* turn's
  `escalation` (the worker had sent `status`, not `worker_done`). Check `git log`, then restart the wait. A message
  to an idle worker also needed an `orca terminal send` nudge.

Carried from the 2026-11-12 afternoon session:

- **Bisect from a known-good layout instead of guessing.** Two hypotheses (a full-width frame, page height) each cost a
  worker turn and were wrong. Starting from `main`'s layout and adding one change at a time found the cause (the pane
  switch) in one turn. When a worker's proposed fix is a guess, ask for "passes with it, fails without it" first.
- **A worker's "restored" can be false.** After the bisect, `MangaDetailView.swift` still held an experiment with
  comments stripped. Check `git status` and diff app files yourself after any experiment turn.
- **A negative UI assertion needs a positive control.** `XCTAssertFalse(segmentedControls[id].exists)` proves nothing
  unless the same query finds the control when it should exist.

- **An observed store that never publishes looks like a view bug.** A UI test went red only after a page-wide `.id`
  was removed; the cause was `WorkStore` sending no `objectWillChange`, not the view. When a redraw is missing,
  check the store publishes before adding observers. Pull a frame from the xcresult's screen recording with
  `AVAssetImageGenerator` (no ffmpeg here) to see the failing screen.
- **Workers keep committing while you review.** Slice 3's worker committed mutation pairs between two of my reads;
  the rebase took 12 commits, not 3. Confirm a worker is idle (`worker_done`, or no CPU) before rebasing its branch.

- **Every one of four Luna pieces passed its own tests and mutations, and review still found real bugs in each.**
  A: a force-unwrap that crashes the hub if a Source is uninstalled mid-search. B: Combine failing when the
  conflicting Work owns only the copy's MAL id; the empty message beside results; counts going to likely rows before
  same-entry rows. C: the "Read from" checkmark removed. Slice 3: the slice 2 menu silently regressed. Read the diff
  against the design, not the report.
- **A later slice can undo an earlier one and its own tests won't notice.** Slice 3 re-gated the menu on
  `offersAChoice`; its "no Remove with one copy" test then passed because the menu was gone. When a slice touches a
  previous slice's code, add an assertion for the previous slice's behaviour to the new tests.
- **A worker's unit count can be one framework only.** Piece A reported 369 (Swift Testing); the suite is 1,129
  XCTest + 369 Swift Testing. Ask for both counts by name in the spec.
- **Orca updated itself mid-run (1.4.256 → 1.4.257)** and the background `check --wait` died with
  `runtime_unavailable`. The worker was fine; a fresh `check --wait` worked. Same as the 2026-10-04 note.
- **A `check --wait` can time out (50 min) while the worker is still busy** on a UI-heavy task. Look at the worktree's
  file mtimes and `/private/tmp` result bundles before assuming a stall; restart the wait.
- **`makeTestDefaults` is an `XCTestCase` extension**, unusable in Swift Testing. There, hold a `TestDefaults` in a
  `final class` suite and remove it in `deinit`.
- **Auto-merge was safe once "Detect code changes" had passed**, because the required jobs then run rather than skip.
  Check that job before `gh pr merge --auto`.

Carried from earlier sessions:

- **A test can pass for the wrong reason even after review.** The `setExternalIds` removal test recorded MAL id 9,
  which nobody owned, so it passed with the filter deleted. My own mutation found it; the worker's three mutations
  (picked from the spec) didn't touch it. **Run a mutation of your own on the line you found the bug in during
  review**, not only on the lines the spec named.
- **Luna's scoping pattern held up again.** Slice 1 took four turns: code (reported `failed`, honestly: no tests),
  review fixes plus WorkStore tests, history and coordinator tests, mutations. Each came back in 3–6 minutes. Review
  between turns found three real bugs: an inverted `setExternalIds` filter, `addListing` able to merge the on-screen
  Work away through MAL-id ownership, and `combine` merging Library items when the Works didn't merge.
- **Outside an Orca terminal, a background `check --wait` is the wake-up.** Start it with the harness's background
  mode right after every `worker-start` or `send`, and parse it with `raw_decode` in a loop. It worked every round.

- **Hermetic fixtures must not depend on a live service answering.** The MAL-hub UI tests passed locally and failed
  on CI because a Library row with no MAL id asks the live MAL search first; locally MAL answered, but on CI (no real
  client id) it threw and no rail rendered. The fixture now seeds `EntityResolutionStore`. **To reproduce CI
  locally,** replace `MAL_CLIENT_ID` in `Secrets.xcconfig` with CI's `ci-placeholder` (back the real file up to
  scratch first, and restore it). Don't move the file away: it is the base configuration and the build breaks.
- **iOS 26.2 can't scroll a visible toolbar menu button into view.** `.tap()` on the preview's "Source" menu failed
  on CI with `kAXErrorCannotComplete`; on 26.5 it passes. Tap it by coordinate
  (`coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()`). This is the same quirk as the
  close-a-menu note below, on the button before the menu opens.
- **A cache that lives in the real Caches directory leaks across UI-test runs.** Every chooser row read "0 chapters"
  until the fixture got its own count directory. Give every on-disk store a fixture-scoped directory.
- **`Text("\(someInt)")` is localized** and shows "1,600". Use `String(_:)` for ids.
- **Review found real bugs in the worker's slice 3 code even after it reported tests green:** a production fallback
  that hard-coded the fixture's MAL id 1000, `ListingCountCache` written off the main actor, counts keyed by manga id
  alone, a challenge sheet that could never appear over the preview, "Try again" replacing every group, and vacuous
  tests. Read the code, not the report.
- **Codex Luna stops early on big turns.** Slices 2 and 3 each reported `failed` 2–3 times with the code written but
  the tests or evidence missing, and slice 3's worker finally went idle without `worker_done`. What worked: one
  narrowly scoped piece per follow-up, mutations in their own turn, a review between pieces, and finishing it
  yourself when what's left is mostly running and fixing tests.
- **Check a screenshot's clock.** A worker re-reported a screenshot with the same status-bar time as the previous
  round; it had not been retaken. For UI evidence, use XCUITest attachments.
- **`MyAnimeListMangaDetail` silently dropped `alternative_titles`** although `mangaDetail` requested it (fixed in
  #384). Grep a DTO before trusting that a requested field is decoded.
- **Outside an Orca terminal**, `orchestration send` needs `--from <coordinator terminal handle>`, or it fails with
  `no_active_sender_terminal`.
- **Deleting a remote branch is classifier-blocked** until the owner says yes in chat. Ask once and name the branches.
  Worktree removals and local branch deletes go through.
- Carried: a stale derived-data path segfaults a synthesized `init(from:)`; a Swift Testing count is not the whole
  suite; `weak let` is Swift 6.2; a mutation that "ran 0 tests" is not a result; previous-run Orca workers can't be
  messaged; auto-merge can lag after green.

## Testing and owner checks — deferred to the end

**The owner's instruction (2026-11-09): features first; all of this waits until the feature queue
is done.** Don't start any of it unprompted. Nothing here is lost by waiting.


1. **#294's device checks — partly run 2026-10-08, and they found a bug.** On the owner's
   iPhone 16 Pro, tapping a `.cbz` in Files **unzips it into a folder** instead of opening
   MangaCarta, though Files lists MangaCarta as "Default" and "Always Open With". Cause: **Aidoku**
   (installed on that phone) *exports* `vnd.comicbook-zip` ("Comic Book Zip Archive") for `.cbz`,
   which beats MangaCarta's *imported* `com.mangacarta.cbz`; Aidoku claims it only at `Default`
   with no in-place support, so nothing qualifies to open it and Files expands it. Get Info's
   "Kind" on the phone confirmed the type. **The fix is uncommitted** in the worktree
   `.worktrees/device-build`, branch `fix/cbz-claim-shared-uti`: one line in `Info.plist` adding
   `vnd.comicbook-zip` to the `Owner` document type's `LSItemContentTypes`. It is built and
   installed on the phone but **not yet retried**. To finish: retry the tap (restart the phone if
   it still unzips), and if it opens MangaCarta, commit, PR, and carry on with the rest of the
   check. The test file is `Device Check 01.cbz` at the top of the owner's iCloud Drive (4 pages,
   ComicInfo series "Device Check"); delete the extracted "Device Check" folder beside it first.
   Other `.cbz` claimants on that phone: Panels, Paperback, an Unzip app, VLC — check what each
   declares if the fix doesn't hold. Still to check after that: an iCloud `.cbz` not yet
   downloaded imports with title and cover and stays in iCloud Drive; Open With lists MangaCarta.
2. **VoiceOver device pass (#90).** `scripts/voiceover-pass.sh` walks the 8 checklist sections and
   writes `docs/accessibility/voiceover-results-<date>.md`. Close #90 when every row has a verdict.
   **Add one check (from #396):** on a title with More Like This, select "Similar", then swipe through the cards
   with VoiceOver to the last one. After a segment switch, XCUITest cannot scroll an off-screen rail card into view
   (bisected: the pane switch alone causes it; fixture, picker, page height and a full-width frame ruled out), so
   the UI tests swipe the rail. A finger scroll works. VoiceOver drives the same scroll-to-visible, so this is where
   a real user problem would show. If VoiceOver can't reach the later cards, file it against the detail view.
3. **#361 on a fresh install:** install the app on a simulator that has never granted it
   notifications, save one title, and confirm the explainer and then the system prompt appear.
4. **Eyeball #302's MAL avatar** in Settings; it was not confirmed during the MAL check.
5. **App icon:** the temporary icon is shipped; the commissioned icon is still the real
   replacement, and `docs/design/app-icon-brief.md` is ready to send. The dark and tinted
   variants have been seen only in the compiled catalog, not on a home screen.
6. **A real image-load report reaching MangaDex**: blocked on MangaDex. Recheck the endpoint with
   `curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" --data '{}' https://api.mangadex.network/report`.
   While it returns 522 there's nothing to test. Once it doesn't, read a chapter on the seeded
   simulator (already on v3) and confirm no `Image-load report dropped` lines appear in
   `log stream --level debug --predicate 'process == "MangaCarta" AND category == "ImageLoadReporter"'`.
   Success is silent, so also check that the endpoint answers a POST with 2xx.
7. **App Store prep** (`docs/app-store/submission-copy.md`): not until the owner says so.
   - the owner's sample and screenshot art, a sample URL or attachment, and contact placeholders;
     recheck every claim against the build that ships, §5 included;
   - accept or drop the three candidate bullets #325 lists (per-title direction, ComicInfo +
     series, Open in);
   - decide whether third-party site logos belong in a no-content build (`SourceLogo-mangadex` and
     `SourceLogo-weebcentral` match only legacy ids, not installed Sources' qualified ids).
8. **Notification action from a cold launch (manual).** A UI test can't reach this (Amendment 1 item 6). On the
   seeded simulator with notification permission granted: push an `.apns` file with `"Simulator Target Bundle":
   "Elias-Magdaleno.Manga-Reader"`, an `aps.alert`, `"aps": {"category": "library-update-actions"}`, a top-level
   `"workId"` from `works.json` for a saved title with new chapters, and `"discoveredOrdinals": ["<n>"]`;
   `simctl terminate` the app, then `xcrun simctl push <udid> Elias-Magdaleno.Manga-Reader <file>`. Long-press the
   banner, tap "Mark Read", and confirm (after opening the app) that chapter n is read and the others are still new.
   Repeat with "Mute" and check the row says "Muted".
9. **Vector PDF slice 5 (after the flip in slice 4):** on the iPhone 17 Pro simulator, check Files open-in-place
   and Share-to-app imports of a PDF, a duplicate import, delete, low-memory tile redraw, a rotated page, and R→L
   (design §"Implementation slices" 5).
10. **Bare 429s (optional):** a 429 with no retry header does not pause (Amendment 8, on purpose).
   Revisit only with evidence of a Source that sends bare 429s.

## Seeded simulator: changed 2026-10-07 and 2026-10-08 (carried from the previous handoff)

- Backup before the 2026-10-07 changes: `~/Manga-Reader-sim-backup-2026-10-07-pre-notif`
  (Application Support + Preferences). No new backup was taken on 2026-10-08.
- **The installed build is `main` at `67b4015`** (#364), from the serial live MAL run on
  2026-10-08. That run reinstalled the app with data kept.
- **Signed into MAL as Proxylink** (user 10146880), sync on. The "iPhone 16 Pro (CI repro)"
  simulator is signed in too.
- Horimiya ch. 124 is **read** in history again (re-read by the 2026-10-08 live run). Mark it
  unread before the next live run.
- Notification permission is **granted**. `settings.declaredAgeOver18` is **true**.
  `settings.showAdultSources` is still false.
- The MangaDex Source is on **bundle v3** (declares image-load reports). WeebCentral is unchanged.
- History gained Dorohedoro ch. 2, read to page 4 of 26.
- The leftover `Luna-*` worker simulators were gone by 2026-11-19, but `PDF2 iPhone 17 Pro` and
  `AN2 iPhone 17 Pro` are still iPhone 17 Pros, so **name-based destinations are ambiguous**. Target the
  seeded simulator by id.

## Watch list

- `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it goes red again,
  suspect the test's own launch timeout.
- The loopback test retries and logs. If it recurs, search the CI log for `[loopback-flake]` (#289).
- `@Sendable` on `AdultContentSetting.current` is **not** redundant: the target is Swift 5 mode
  without `InferSendableFromCaptures`. Keep it.

## Operating notes

- **Orca's Claude workers need Orca's own Claude sign-in.** On 2026-11-09 two starts failed at
  `dispatch_input` with `notSignedIn`; the owner signed in (Orca's Claude Accounts settings) and
  later starts worked. Release a failed start, then `worker-start --task <t> --retry-of <old>`.
  A Claude worker can also stop mid-task on its session limit (an `escalation` with
  `failureKind: usageLimitReached`); its worktree may hold nothing — check before assuming.
- **Outside an Orca terminal, nothing wakes you when a worker reports.** Run
  `orca orchestration check --terminal <coordinator> --run <run> --wait --timeout-ms 3000000 --json > <file>`
  in the harness's background mode, read the file when it exits, restart it. The file holds several
  JSON objects (`_keepalive` heartbeats, then the delivery): parse with `json.JSONDecoder().raw_decode`
  in a loop, not `json.loads`.
- **Old workers can't all be released, and needn't be.** `worker-release` on prior sessions'
  workers returns `retained` (`user_takeover`) or `release_unknown` (terminal gone). Neither has a
  live process; leave them. Workers started in a `new-top-level` worktree are kept open — release
  them once their branch is merged or abandoned.
- **Diff every revision a spec worker reports.** One revision went past the owner's decision (it
  removed existing mark-seen hooks the owner had kept). Specs were also confidently wrong about the
  code three times (MAL sync on manual marks, an "existing" mute menu, an "existing" CI package
  cache) — grep the claim before accepting it.
- **`git stash pop` of Xcode churn can conflict with a real `project.pbxproj` change on `main`.**
  Keep `main`'s file (`git checkout HEAD -- MangaCarta.xcodeproj/project.pbxproj`); the stash entry
  survives a conflicted pop.

- **Plans written here can be wrong about the code; the worker is the first to find out.** #290's
  plan was self-reviewed and still missed three things (above). What worked: a spec per task that
  said "report succeeded ONLY if every acceptance item holds", and ruling promptly when the worker
  escalated. Grep a plan's claims ("only call site", "the helper") before dispatching.
- **A Codex worker can ask the same question twice** — once as an `escalation`, then again as a
  blocking `question` before it has read the reply. Answer the `question` with `orchestration reply
  --id <msg>`; that unblocks it. Nudge an idle worker with `orca terminal send … --enter`.
- **Reusing one worker terminal across tasks works:** `worker-start --spec … --terminal <worker>
  --from <coordinator>`. A receipt of `outcome_unknown` / `turn_start_unobserved` still delivered the
  task here — read the terminal (`orca terminal read`) before retrying anything.
- **Close a menu in a UI test by tapping one of its entries, never the button behind it.** On CI's
  iOS 26.2 the menu's own button is unreachable while its menu is open (`kAXErrorCannotComplete`
  on scroll-to-visible); on 26.5 it happens to work. That, not reopening the reader, is what failed
  #307's CI — see "Completed" below.
- **SwiftLint on changed files, in zsh:** `git diff --name-only main...HEAD | grep '\.swift$' |
  xargs swiftlint lint`. `swiftlint lint $F` does not word-split in zsh, so it lints the whole repo
  and the existing warnings look like yours.
- **Testing that a read is coordinated:** register an `NSFilePresenter` on the file and implement
  `relinquishPresentedItem(toReader:)`; only coordinated reads call it (#309's test). Its
  `@Sendable` signature is newer-SDK, but a mismatch only warns and still matches, so it holds on
  CI's Xcode 16.4.
- **Check a mutation actually landed** (`git diff` after the edit) before trusting its result. A
  `sed` against a line that had since been reformatted matched nothing, and the "mutation" run
  passed — which reads exactly like a test that can't detect the mutation.
- **Never background a `check --wait` with `&` inside a tool call.** It survives as an orphan waiter,
  and the next `check --wait` fails with `waiter_exists`. Use the harness's background mode.

- **a parallel test run leaves nothing in the seeded container.** It executes on
  cloned simulators whose containers are discarded. A parallel full run showed 0 leftover plists
  where the serial run of the same code showed 66. Keep parallel on for pass/fail, but pass
  `-parallel-testing-enabled NO` for any check that inspects the seeded container afterwards.
- **`xcp add-file` fails on `/private/tmp/...` paths** ("Group not found in the
  project"). Use the `/tmp/...` spelling of the same worktree path; it then writes a clean
  4-line change.
- **Luna's `failed` can be the honest answer.** On #296 it reported `failed` because its
  own no-leftovers check did not hold, and that was correct: it had found the cfprefsd write-back.
  Read the summary before discarding a `failed`.
- **undoing a mutation with `git checkout -- <file>` reverts to the last commit,** not to
  your uncommitted edit, and silently throws that edit away. It happened here. Commit before a
  mutation, or undo it with the inverse `sed`.
- **Luna's "succeeded" is not evidence.** On slice 6 the first pass reported `succeeded` while its own
  summary said most acceptance tests were missing. What worked: a spec that mapped every acceptance
  item to a named test, named the mutations to run, and said "report succeeded ONLY if every item
  above is done". Keep reading each test against its acceptance item.
- **A branch's unit tests run its launch migrations on the seeded fixture.** Unit tests are hosted in
  the app, so `xcodebuild test` installs and launches that branch's build on `ADDAB2F8-…`. A migration
  under test is not reversible by switching back to `main`; back up the container first.
- **Reading a `check --wait` result.** The consumed output is pretty-printed JSON across many lines
  after the dropped `_keepalive` lines, so parse from the first `{`, not the last line. A
  `worker_done`'s task, dispatch and outcome live in the message's `payload` string.
- **Swift Testing and actors.** `#expect(... store.root ...)` on an actor's `let` fails to compile
  inside the macro expansion. Hold the value in a local before the `#expect`.
- **Merging.** The owner asks for merges by PR number (#292–#294, #297–#302, #309, #311, #341, #349–#355, #357–#359, #361, #386 so far; 2026-10-07's four were asked for together, as "merge all four"). Treat each
  request as covering the PRs it names, not as a standing permission. Use
  `gh pr merge <n> --squash` once all four checks pass, or `--squash --auto` to wait for CI; gate
  branch cleanup on `state == MERGED`.
- **How Files decides who opens a document (iOS 26.5).** "Open With" lists only apps with
  `LSSupportsOpeningDocumentsInPlace = true`, and a tap opens the app only at `Owner` rank. Launch
  Services lists every claimant regardless. Spec decision 14 has the full table.
- **A probe app for Launch Services questions.** A 60-line UIKit app built with
  `xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator`, a hand-written
  `Info.plist`, `codesign -s -`, then `simctl install` and `simctl launch --console-pty`. Vary one
  Info.plist key per install and check Files by hand. Not in the repo.
- **A probe test for runtime questions.** Append a temporary `@Test` to a Swift Testing file that
  already imports `Testing` (e.g. `AdultContentFilterTests.swift`; add `import Foundation`), run it
  alone with `-only-testing:'MangaCartaTests/<name>()'`, and `print("PROBE …")`. Both of today's
  root causes were found this way in minutes. `MangaCartaTests.swift` cannot take one: adding
  `import Testing` there makes `Tag` ambiguous.
- **Putting files into the simulator's Files app.** Copy them into the
  `group.com.apple.FileProvider.LocalStorage` app group's `File Provider Storage` directory; they
  appear under On My iPhone. Tapping a `.cbz` there opens MangaCarta and imports it.
- **Device Hub click hazard.** Dismissing a Files context menu by clicking where a menu item sits
  runs that item. Dismiss by clicking well outside the menu.
- **Orca and Codex:** verified 2026-09-30 — Orca **1.4.217** runs Codex without the temporary
  readiness wrapper; launch with `--agent codex --model gpt-5.6-luna --effort medium`. If
  `agent_readiness` timeouts return, the owner's wrapper may still be at
  `~/.local/share/orca-codex-compat/codex`; check versions, then fall back to it. Don't delete it
  unasked. Three failures on one Task fail it permanently; stop after two.
- **Orca from outside an Orca terminal:** `orca terminal create --worktree path:<wt> --json` (the
  selector needs the `/private/tmp/...` spelling; `/tmp/...` gives `selector_not_found`) and pass
  that handle as `--from` to `run-create` / `worker-start`; `--worktree path:<wt>` works for an
  existing non-Orca worktree. A consuming `check` takes `--terminal <handle>`. `worker-release` takes
  neither. Never pipe `check --wait` into `head`. Close the coordinator terminal when done
  (`orca terminal close --terminal <handle>`).
- **Messages do not wake an idle Codex worker.** Prompt it with
  `orca terminal send --terminal <handle> --text "<instruction>" --enter --wait-submit 20 --json`.
- **Worker claims need checking.** Review the diff against the acceptance list, run
  `swiftlint lint` yourself on the changed files (a bare `swiftlint lint` with an empty file list
  lints the whole repo, whose existing warnings look like yours), and re-run a mutation of your own.
- **A merge-when-green script must fail closed.** Require exactly the expected number of `pass`
  lines (4 today) and treat a `gh` error as "do not merge".
- **Boot the seeded simulator before testing.** A cold boot by `xcodebuild` can fail with
  `Busy ("Application failed preflight checks")`.
  `xcrun simctl boot ADDAB2F8-38C7-4D44-97EA-4E98281CF691 && xcrun simctl bootstatus <udid>`.
- **A test that awaits a condition needs a deadline.** A wait with no deadline hung a whole run once.
- **Swift Testing and `-test-iterations`.** It *does* repeat Swift Testing tests. To reproduce a
  scheduling flake, force the bad order instead.
- **URLSession retries a lost connection on its own** (three attempts before -1005).
- **The seeded simulator** `ADDAB2F8-38C7-4D44-97EA-4E98281CF691`, iPhone 17 Pro, iOS 26.5:
  MangaDex active (`5e2ac712-83cb-492d-8961-f1b8236bd0c7:mangadex`). Read `settings.showAdultSources`
  before relying on it. **Changed 2026-09-29/30:**
  - `Library/Preferences` went from 16,778 files (66 MB) to 9: the app's own plist (byte-identical
    before and after) plus the app-created `*-ui-test*` suites. Backup of the folder:
    `~/Manga-Reader-sim-backup-2026-09-29-pre-296-prefs`.
  - `tmp/` went from 47,743 entries (3.7 GB) to 17: the Files inbox, fixed-name UI-test folders,
    WebKit folders, `deflated.cbz`. Not backed up (download scratch and test fixtures only).
  - Library still holds the three local test series ("Trilogy Check", "Open In Check",
    "In Place Check"); Files still holds the test `.cbz`/`.zip`/`.pdf` files.
  - `tmp/` holds 18 known entries plus `MangaCartaTests/` (the #303 sweep's folder) after the
    2026-09-30 cleanup.
  - Which build is installed: see "Seeded simulator: changed 2026-10-07" above.
  - Older backups: `~/Manga-Reader-sim-backup-2026-09-29-pre-openin/` and
    `~/Manga-Reader-sim-backup-2026-09-27-post-smoke/`.
- **The app's data container moves on every reinstall, and every test run reinstalls.** Look it up
  with `xcrun simctl get_app_container <udid> Elias-Magdaleno.Manga-Reader data` right before use
  while booted, then edit plists with PlistBuddy while shut down. Never use
  `simctl spawn … defaults write`. Read the app's settings from
  `Library/Preferences/Elias-Magdaleno.Manga-Reader.plist` only.
- **Name-based `xcodebuild` destinations fail.** Use the simulator id above, and keep parallel testing
  on for pass/fail runs.
- **Keep build products out of the repo.** `build/` is not ignored; use a `-derivedDataPath` under
  session scratch.
- **`/private/tmp` can be wiped between sessions**, so push work before ending one.
- **The simulator GUI is Device Hub.** Live UI tests run by name on clones; see the header of
  `MangaCartaUITests.swift`.
- **Temporary directories in tests (#303):** use `makeTestDirectory("<prefix>")` in XCTest, or
  `TestDirectory("<prefix>")` + `defer { dir.remove() }` in Swift Testing. A fixture class holds its
  `TestDirectory` and removes it in `deinit`. A Swift Testing suite that needs several directories
  per test is a `final class` with one root per test, removed in `deinit` (Swift Testing makes a
  fresh instance per test). Everything lives under `tmp/MangaCartaTests/`, swept after ten minutes.
- **A computed property can't be read in a class `init`** before every stored property is set. Take
  a local (`let directory = testDirectory.url`) at the top of the `init` instead.
- **Grep the whole call path before telling the owner something doesn't exist.** On 2026-09-30 a
  grep limited to `Local*` files missed that local import mints its Work through
  `LibraryStore.toggle`; the claim went to the owner and had to be corrected.
- **To replace this handoff,** `git mv` it into `archive/` and carry every still-open item forward.

- **Publishing an engine has a short window where installs fail.** `raw.githubusercontent.com` serves
  the new `engine.js` at once, while GitHub Pages serves the old `index.json` (old hash) for a few
  minutes. An install in that window fails the hash check. Confirm the Pages index carries the new
  hash before calling a publish done.
- **Engine-supplied numbers never go straight into `Int(_:)`.** It traps on huge, infinite or NaN
  doubles. Range-check first (#316).

- **Parallel workers must not run UI suites at the same time.** Two workers sharing the seeded
  simulator both got signal-killed hermetic UI runs on 2026-10-01 (#317's worker reported `failed`
  for it). Run alone, the same suites passed 19/19. Have parallel workers run unit tests only, then
  run the 6 CI-gated hermetic suites yourself, one branch at a time:
  `-only-testing:MangaCartaUITests/UpdatesUITests -only-testing:MangaCartaUITests/SourcePreferenceUITests -only-testing:MangaCartaUITests/RepositorySettingsUITests -only-testing:MangaCartaUITests/LocalImportUITests -only-testing:MangaCartaUITests/AccessibilityAuditUITests -only-testing:MangaCartaUITests/MALHubUITests` (`.github/workflows/ci.yml` is the source of truth).
- **`Secrets.xcconfig` is not in a fresh worktree.** It is gitignored (it holds `MAL_CLIENT_ID`, read into `MALClientID`) and is
  the target's base configuration. #318's worker copied it in from the main checkout to build;
  builds in the #315 worktree passed without it. If a worktree build complains about it, copy it in
  and never commit it.
- **Check a worker's stated exceptions, not just its diff.** #317's worker left one test on the
  standard domain "deliberately"; that test already held an isolated suite, and the exception was
  wrong.
- **A single-test `xcodebuild` run can hang after the result prints** (seen with a Swift Testing
  `-only-testing:'Suite/test()'` selector). Read the output file; if the verdict is there, kill the
  process instead of waiting.

- **Reading an accessibility audit.** `performAccessibilityAudit`'s issue handler gets the element;
  print `elementType.rawValue` (9 button, 43 image, 48 static text), label and identifier, and return
  `true` to collect rather than fail. Judge every finding against a screenshot: here contrast fired
  on text under the tab bar's blur, and text-clipped on labels that render whole.
- **A `.plain` button's hit region is its label.** A frame, padding or fill applied to the `Button`
  itself is drawn but not tappable; put them inside the label and end with `.contentShape(...)`
  *after* the padding (#326).
- **Viewing a UI test's screenshots:** run with `-resultBundlePath <scratch>/x.xcresult`, then
  `xcrun xcresulttool export attachments --path <it> --output-path <dir>`; `manifest.json` maps
  attachment names to files.

- **Orca can update and restart itself mid-run** (1.4.218 → 1.4.220 on 2026-10-04). A pending
  `check --wait` then returns `runtime_unavailable` / `outcome_unknown`, and the worker shows
  `unverifiable` / `restored_unconfirmed`. The worker survived. Prove it with
  `lsof -a -p <codex pid> -d cwd` pointing at the worktree. **`--retry-request <id>` only replays the
  cancelled result** (`connectionLost: true`, no messages); start a fresh `check --wait` instead.
- **`LocalImportUITests` ran ~27 min for one test locally** during #334's hermetic run (passed; CI
  took the normal ~12 min for the whole job). Likely simulator state, not code. If it recurs, look at
  the seeded simulator before the test.
- **The UI-test two-listing fixture can't catch wrong-Source reads**: both fixture sources return `[]`
  from `pageURLs` for any chapter id. Test Listing routing at the view-model seam
  (`MangaDetailRetargetTests`), not through UI tests.

- **"No Work → unchanged" needs a same-Listing test.** #332's first version put the opened
  `manga.id` into the listing set even with no Work, which quietly turned on ordinal matching
  *within* one Listing (two groups' chapter 7 shared a resume marker; unread on one cleared the
  other). A cross-Listing no-Work test can't see that. `testWithoutWorkSameListingOrdinalDoesNotMatch`
  now guards it.
- **Two PRs squash-merged back to back never ran CI together.** #336 and #337 both edited
  `HistoryStore` and merged within a minute. Run the full unit suite on the resulting `main` (done
  here, green) before building on it.
- **A worker's unit-test run can kill your UI run.** Two `RepositorySettingsUITests` failures on
  #329's branch happened while the #330 worker was testing on the same simulator; alone the suite
  passed 5/5. Run the hermetic UI suites only when no worker is mid-test.
- **A worker's "mutation run hung" is not a result.** #332's worker applied its third mutation but
  the run hung on launch; it said so honestly. Re-run that mutation yourself before opening the PR.
- **Small fixes don't need a worker.** #331 was ~15 lines over an existing lookup; writing the spec
  would have cost more than the change. Dispatch when there is real implementation to delegate.

- **Sweep method that worked (2026-10-04, 2026-10-05).** Two read-only workers on different
  providers, split by area (Sources+reader / Library+history+tracking+launch); spec forbids edits
  and requires file:line plus a user repro per finding; workers write reports to the ignored
  `.worktrees/`; the coordinator verifies each against `main` before filing. 7 of 7 held up.
- **Workers' tests miss the case the fix is for, and their own mutations don't show it.** Twice
  today (#347, #348) the worker's mutation was real but a *different* mutation of the same fix
  survived — the tests parked the stale load on the wrong await, or used different manga ids. Run
  a mutation of your own on the line the issue is about, not the one the worker picked.
- **Parallel workers starve each other's mutation runs.** Three workers on one simulator: two
  reported `failed` only because their mutation/full-suite runs couldn't launch. The specs now
  say to retry launch failures 5× at 60s. Plan to run the mutation and full suite yourself.
- **`Timed out waiting for AX loaded notification`** fails a UI run before any test executes.
  `xcrun simctl shutdown` + `boot` the seeded simulator and rerun; it passed 20/20 after.
- **Swift Testing suites are selected by struct name**, not file name
  (`-only-testing:MangaCartaTests/MALAccountStoreLifecycleTests`). A wrong selector runs 0 tests
  and reports success — check the count before trusting a "mutation survived".
- **`LegacySourceID.unattributed` is `"mangadex"`.** A Library item or Manga with no `sourceId`
  keys as legacy MangaDex, not as local — don't fall back to it for local items.
- **zsh arrays are 1-indexed.** A `T=("" …)` / `${T[$i]}` loop written for bash shifted every
  issue title by one; feed titles through `while read` instead.
- **Stale PR CI after a sibling merges.** When two PRs touch one file and one merges, run
  `gh pr update-branch <n>` on the other so CI runs on the combined code (done for #353).

- **Tapping a real notification on the simulator (2026-10-07).** Write an `.apns` file with
  `"Simulator Target Bundle": "Elias-Magdaleno.Manga-Reader"`, an `aps.alert`, and a top-level
  `"workId": "<a WorkID UUID from works.json>"` (`UpdateNotifier.workIdUserInfoKey`). Send it with
  `xcrun simctl push <udid> Elias-Magdaleno.Manga-Reader <file>`. It reaches the same
  `UpdateNotificationDelegate.didReceive` a local notification does. The app must have permission
  first (see #356). For a cold-launch tap, `simctl terminate` before pushing.
- **Drive the simulator with the iOS Simulator control tool, and name the device on every call.**
  After a desktop-app restart it silently defaulted to the also-booted "iPhone 16 Pro (CI repro)",
  and a tap landed there. Separately, clicking around Device Hub with computer-use brought up
  "Remove iPhone 16 Pro (CI repro)?", which Escape didn't dismiss. Avoid Device Hub clicks for
  simulator work.
- **Watching an app's network calls on the simulator:** `xcrun simctl spawn <udid> log stream --level
  debug --predicate 'process == "MangaCarta" AND (...)'`. The
  `com.apple.networkextension` `ne_tracker_check_is_hostname_blocked` lines name every host the app
  resolves, which shows a request was attempted. `lsof` on the app's pid showed no TCP sockets, so
  don't rely on it. macOS has no `timeout`; background the stream and `kill` it.
- **`ImageLoadReporter` logs only failures, and only in DEBUG** (`Image-load report dropped: …`).
  A silent log isn't proof of delivery; probe the endpoint directly as well.
- **Codex can generate images** (`codex features list` shows `image_generation stable true`, CLI
  0.160.1). Driven through Orca like any worker, it made both icon rounds. What worked: generate
  only the light variant, derive dark and tinted from its pixels (so the composition can't drift),
  and have it check any kanji. Verify `sips -g hasAlpha` and the sizes yourself.
- **A long chain of mutating commands in one Bash call can be refused** by the auto-mode classifier
  ("Irreversible Local Destruction") when it overwrites a tracked file and `git rm`s another.
  Splitting it into single, reversible steps went through, and the `git rm` ran once the owner
  approved it.

- **A live MAL run proves nothing by passing.** Progress is queued only on an unread-to-read
  transition, and the drain checks MAL first and skips when MAL is already at or past the target.
  Check the account's MAL history (`myanimelist.net/history/<user>/manga`); a hard-refreshed list
  page can still lag. A run whose app was closed before sending sends on the next launch.
- **Reading the app's MAL traffic:** `log show` CFNetwork lines name a URL only when a connection
  opens, so a request reusing a connection looks like nothing happened. Match the `Task <uuid>`
  lines instead (`sent request, body N 0` is a GET; the summary line has the status).
- **A worker's tests can all pass while the bug stays.** #356's worker tested the notifier and the
  Library callback, but nothing between them and the composition, which was the missing caller.
  Mutate the wiring the issue is actually about.

- **`devicectl device info apps` lists only Xcode-installed apps** unless you pass
  `--include-all-apps`. That is how the Aidoku `.cbz` claim was found on 2026-10-08. Installing a
  build on the owner's phone: `xcodebuild -destination id=<device UDID> build` (with a scratch
  `-derivedDataPath`), then `xcrun devicectl device install app --device <UDID> <path>.app`; data
  is kept. Phone UDID: `00008140-000414383A79801C`.
- **An exported UTI beats an imported one.** Any app claiming a file type by an identifier it
  only imports loses that extension to another app that exports one. On a device, read the
  type with Files → Get Info → "Kind" and compare against the declared `UTTypeDescription`s.
- **Check the MAL entry before a live run, not after.** MAL at or past the test's target means the
  run passes while sending nothing; set it below 124 first and record the original separately,
  because `fire`'s own snapshot records the lowered value.
