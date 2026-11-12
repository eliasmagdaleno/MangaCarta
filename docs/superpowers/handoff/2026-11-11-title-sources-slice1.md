# Handoff: per-title Sources slice 1 merged; next is slice 2, Add a Source

Date: 2026-11-11 (afternoon). This is the one live handoff. The previous one, `archive/2026-11-11-mal-hub-done.md`, is
superseded, and every open item in it is carried here. Recheck GitHub, the worktrees and the working tree before
acting.

**The owner's instruction stands: features first, testing last** (memory `features-first-testing-last`).

## State

Merged, branches and worktrees deleted:
- **2026-11-10:** #368–#385 (designs, ADR-0028, MAL-hub slices 1–2, research, handoffs).
- **2026-11-11:**
  - **#386**, MAL-hub slice 3 (preview, mixed rails, chooser, `ChallengeSheets`). The MAL hub is done.
  - **#387**, the morning handoff.
  - **#388**, the per-title Sources design: `docs/superpowers/specs/2026-11-11-per-title-sources-design.md`, ADR-0005
    Amendment 2, and the glossary's **Removed Listing**. Accepted, with both open questions decided by the owner:
    Remove asks why ("same title" keeps reads, "different title" drops them); adding a copy that belongs to another
    multi-copy title offers both **Combine the titles** and **Move just this copy**.
  - **#389**, the analytics design revised to **consent first, everywhere** (owner decision): nothing recorded or
    sent and no id minted until the reader agrees. EU/EEA/UK and unknown regions get "Share" / "Not now"; elsewhere,
    including Switzerland, "OK" / "Turn off". Device ID is Linked: Yes. `PRODUCT.md` records the decision, and the
    local-formats design has the exact UnRAR attribution.
  - **#390** (merged 2026-11-12 00:20 UTC, all four checks green), per-title Sources **slice 1, the model** (no UI). It
    added:
    - `Work.removedListings` (`RemovedListing`: a key plus `keepsReadState`) and `Work.handLinkedListings`;
    - `WorkStore.addListing` (returns `.added` / `.alreadyLinked` / `.belongsToOtherWork(id)` / `.workNotFound`;
      it never merges, and it reports another Work that owns the copy *or its MAL id*), `moveCopy`,
      `removeListing(_:from:keepingReadState:)`, `retiredListings(of:)` and `liftRemoval`. `merge` now returns
      `Bool`;
    - the §4 stickiness rules, enforced in mint, `setExternalIds` and `merge`;
    - retired Listings in `HistoryStore.workListings(for:)`;
    - `WorkSourcesCoordinator` in `AppComposition`, with `add`, `remove` and `combine`, and the cleanup of pin,
      Library item, MAL-hub choice and update check state. **Views call it, never the stores.**
    - The tests are `WorkStoreTests` (51) and `PerTitleSourcesTests` (10).

**Orca:** run `run_f62f70421d79` and its coordinator terminal `term_8017fed9-33cd-412c-b5bd-cd1ec062a83c` (opened in
the main checkout) are from slice 1. The worker reported and closed. Reuse the terminal as `--from` for slice 2, or
close it (`orca terminal close --terminal <handle>`) when done.

**Working tree:** `MangaCarta/Info.plist` may still carry an uncommitted Xcode rewrite that drops
`LSSupportsOpeningDocumentsInPlace` (#294). Never commit it as is. `stash@{0}` and `stash@{1}` are old Xcode churn and
safe to drop. Leave `.worktrees/device-build`, the uncommitted `.cbz` UTI fix, alone.

## Next

1. **Per-title Sources slice 2: Add a Source.** The design's §1, §2 and §6, plus its "Slices" list. In order:
   - Extract `SourceTitleSearch` from `MALHubResolver`: the per-Source timed search, the four-in-flight limit, the
     challenge-aware 8 s deadline, and the retry merge. **The hub's existing tests must pass unmodified**; that is
     the proof the extraction changed nothing.
   - Make the detail page's Source stamp always a menu for a remote title (`SourcePickerStamp`,
     `Views/Components/SourceBranding.swift:139`; today a single Listing renders the plain `SourceStamp`,
     `MangaDetailView.swift:99-118`). Add "Add a Source…". Local titles keep the plain stamp.
   - Build the Add sheet, with its grades: same MAL entry, likely match, different MAL entry, ungraded. Add the top-3
     chapter counts via `MALHubChapterCountLoader`, "Couldn't check" with "Try again", `.challengeSheets(nested: true)`,
     and "Removed earlier" rows.
   - Add the confirmations: different MAL id; belongs to another Work with no other copies (Add = combine); belongs
     to another Work with other copies (Combine / Move just this copy). Use `WorkSourcesCoordinator.add` /
     `combine` / a coordinator wrapper for `moveCopy` (the coordinator has no `move` yet; add one so the view never
     calls `WorkStore`).
   - Adding to an uncommitted title mints its Work first.
   - Add a hermetic UI fixture `-uitest-title-sources` (Sources A–D, a title on A and B), gated in CI's hermetic job
     (`.github/workflows/ci.yml`, no trailing backslash on the last `-only-testing`), and a large Dynamic Type
     screenshot.
   - A new `Views/` file needs `xcp add-file` (Views is not synchronized); `Views/Components/` is synchronized.
2. **Per-title Sources slice 3: Remove a Source.** The menu entry, the "asks why" dialog (§3), and UI tests (remove
   as same title and a read chapter stays read; as different title it doesn't; still removed after relaunch and a
   Library refresh). The model and cleanup are already in #390.
3. **Analytics** is decided on consent. Its remaining open questions (1, 4–9: provider, retention, export,
   `source_installed`, adult purge, legal review, Related opens) still need the owner, each with a recommended
   answer (design §"Open questions"). Ask them in one pass when the owner wants analytics next. The `mlt_opened`
   hook hangs off the MAL-hub rails (analytics design §11.1).
4. **Item 12, per-Source refresh cadence:** still blocked on measured device data. Don't guess.
5. **Library-wide switching to another Source** (owner's item 3, Paperback's "Migrate"): its own design, after
   slices 2–3. `moveCopy` and `combine` from #390 are its building blocks.

Small and owed: mark the MAL-hub design's open question 3 decided (remembered choices stay on the preview, no
Settings list; owner, 2026-11-11) when next touching that doc.

The rest of the feature queue is specced and on `main`:
- notification actions;
- Updates screen;
- widgets;
- detail sections (segmented Chapters / Related / Similar, built over the MAL-hub rails);
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
- **The detail header's cover spinner spins forever when the cover is nil.** Seen in MAL-hub slice 3's screenshots.
  `MangaCoverCard` was fixed; the detail header was not. Fix it when touching the detail page (slice 2 does).
- MAL-hub adult filtering option A (a per-card MAL `nsfw` fetch) is a recorded follow-up in the design.
- **`WorkStore.link`'s removed-Listing guard is unreachable today** (its only caller, mint's external-id path,
  already refuses a removed copy), so no test can catch its deletion. It's a backstop for future callers. If a new
  caller of `link` appears, add a test through it.

## Lessons from this session

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
8. **Bare 429s (optional):** a 429 with no retry header does not pause (Amendment 8, on purpose).
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
- Four leftover worker simulators (`Luna-R186`, `Luna-230`, `Luna-190`, `Luna-removal2-final`) are
  also iPhone 17 Pros, so **name-based destinations are ambiguous**. Target the seeded simulator by
  id.

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
