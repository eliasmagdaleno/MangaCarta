# Handoff — no built-in Sources: slices 3–4 merged; import UI, PDF and #230 in review

Date: 2026-09-24, 09:50 PDT (supersedes `archive/2026-09-23-no-built-in-sources.md`)
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
`main` at **`0dc7e68`** (#234). Merged 2026-09-24: **#225, #229, #212, #213, #214, #234** (plus #224 late on 09-23).
**Three worker PRs are open and need the coordinator: #235, #236, #237.** See "Next session — start here".

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs"). **PR #228** (an in-place update of the 09-23 handoff) is superseded by this
file — close it.

## Standing instructions from the user

- **Codex `gpt-5.6-luna` medium for implementation; Claude for review, decisions and docs.** Claude
  subagents are encouraged for read-only reviews, research, issue filing and docs — the user asked for
  them to be used more (2026-09-24). Every worker PR gets a Claude review subagent **and** a
  coordinator full unit suite (or green CI when the machine is overloaded) before merge.
- **When the permission classifier blocks an action, ask the user for permission to do it** — don't
  hand them a `!` command. On an explicit yes, retry the same action. (Memory:
  `ask-before-handing-back-blocked-actions`.) The user has since approved merges on request.
- **At forks, prose discussion with a recommendation**, not a quiz.

## Next session — start here

1. **#236 — local import slice 3 (import UI, empty states, delete).** Worker (`ctx_fb418e2252ca`,
   terminal `term_6e07e945-928f-48f3-80d9-73aac161345e`, worktree `local-import-3`) finished the review
   fixes (release build now compiles, fixtures no longer ship in the app, UI test goes through
   `LocalImportViewModel`, real image CBZ, delete size/errors/dismiss, Work minted on import, `.cbz`
   imported not exported). **But its last "style: wrap embedded hermetic fixture data" commit
   (`8242523`) broke `MangaCartaUITests/LocalImportUITests.swift:56-58`** — a duplicated
   `private static let fixtureBase64 =` line and missing commas between the string literals — so CI is
   red on compile. **The fix request was sent to the worker at 09:50** — check it landed and CI is green, then: Claude re-review (verify every item of the 8-point
   fix list was really done, esp. the Release build and the pbxproj resource phases), full suite, merge.
   **Deferred from #236 — file one issue:** one shared `LocalImportViewModel` (three exist: Home,
   Library, Settings); Settings row item count + disk used; Delete in the Library context menu;
   "Add a repository" secondary link on first run; cancel semantics vs spec §5.
2. **#235 — local import slice 4 (PDF).** Worker (`ctx_51a51cb3d001`, `term_5227a3a1-…`, worktree
   `local-import-4`) reports all six review fixes done (PDFKit `thumbnail(of:for: .cropBox)` rendering
   with rotation, pixel-content tests, autoreleasepool, `isLocked`, duplicate recheck, zero-page/locked
   tests), 9 tests. **CI all green.** Next: Claude re-review — confirm the tests decode pixels and would
   go RED on a flipped/unscaled render — then full suite, merge. **#235 and #236 both edit
   `LocalLibraryStore`; merge #236 first, then have the #235 worker merge `origin/main` (merge, not
   rebase — avoids force-push) and re-run.**
3. **#237 — #230 wildcard asset origins.** Worker (`ctx_ed76eb35e76e`, `term_bd455455-b5de-4afb-b690-d0706da0875c`,
   worktree `fix-230-wildcard-asset-origins`), one commit `09c5262`. CI: one failure,
   `BrowserInteractionSpikeTests.testBackgroundChallengeReturnsInteractionRequiredWithoutPresentingUI` —
   **the known flake** (it also failed #212 then passed on re-run). Re-run the failed job, Claude
   review (brief required Host API version gating per §7, wildcard only in `assetOrigins`, exactly one
   label, public-suffix deny-list, public-address check on image loads, mutation checks), full suite,
   merge. **Consider filing an issue to quarantine that spike test** — it has now flaked twice in a day.
4. **Next workers once slots free (≤3 simulator workers):** **#231** (scanlation group — after #236
   merges; both touch the chapter list/detail view), **#232** (per-site rate limiter — independent),
   **#233** (connect-time IP pinning — #214 is merged, so unblocked).
5. **Small docs PR:** the host API spec has two "Amendment 3" headings (Q10 version grammar at ~:436,
   and #213's nested paging at ~:728), and #213's "v1/v2 engines" (engine script revisions) now read
   like Host API versions next to 1.1. Renumber #213's to Amendment 4; say "pre-#186 / nested-shape
   engines".
6. `CLAUDE.md` "Current state": #225 added a one-line Local bullet *above* the intro sentence — fold it
   into the list; also add slice 4's Host API 1.1 and the import UI/PDF once merged.
7. **Owner's docs queue** (all docs, all ready): **#215 first** (ADR-0003 A6 — the no-built-in decision),
   then **#220** (App Store copy + ADR-0022 A5; *#215 and #220 both append to ADR-0022* — merge #215
   first, then fix #220's conflict), #216, #227 (ADR-0019 A2), #221, #222; close **#228**.
8. **Worktree cleanup** (agent removal has been refused; ask the owner, or ask permission): 
   `no-built-in-slice-2`, `no-built-in-slice-3`, `no-built-in-slice-4`, `local-import-slice-2`,
   `local-import-zip-reader`, `zero-sources-slice-1`, plus the list under "Cleanup" below. Workers
   released: `ctx_db771c360a5a`, `ctx_132baef04933`, `ctx_eaa119bd881a`, `ctx_18ae51152205`. Still held:
   `ctx_fb418e2252ca` (#236), `ctx_51a51cb3d001` (#235), `ctx_ed76eb35e76e` (#237).

## Decided this session (2026-09-24)

- **App Store (in #220, ADR-0022 A5):** target **16+** (first-party manga apps are 13+ but curate;
  plug-ins can bring seinen content undeclared); **no test repository** for App Review; subtitle
  `CBZ & ZIP comic reader` (add PDF when it ships); listing claims are a checklist against the build.
  Sample/screenshot art is still the owner's.
- **Slice 4 contract (option A):** a new optional `listing` operation rather than widening `detail`;
  Host API **1.1** gates it and `externalIds` (spec §7), rather than rewording §7.
- **#224's design** is recorded as ADR-0019 Amendment 2 (**#227**), not ADR-0016 (which #215 edits).
- **#195 closed** (superseded by #215).

## Merged this session (2026-09-23 late → 09-24)

#224 (`69fb5b2`), #225 (`6fb1d81`), #226 (handoff), #229 (`fd46b9b`), #212 (`d7b2ba7`), #213 (`59fbd05`),
#214 (`e609a1a`), #234 (`0dc7e68`). Filed: #230, #231, #232, #233 (all `ready-for-agent`).

## The big decision this session (owner, 2026-09-22)

MangaCarta ships to the App Store with **no built-in and no bundled content Sources**, reversing
ADR-0003 Amendment 5. MangaDex stops being compiled in too. Users add a repository by URL; the app
ships **no default, suggested or linked repository**. The app's legitimate first-run purpose is
**local import** (CBZ/ZIP/PDF via Files). MAL-dependent features (More Like This, the MAL/AniList
upgrade bridge, part of For You) work only when an installed Source publishes external ids — the
owner accepted that.

Recorded in **PR #215** (ADR-0003 Amendment 6, ADR-0022 Amendment 4, ADR-0016 amendment, §12 and
glossary notes) and **PR #216** (local import spec + **ADR-0025** "Local files as a Source"). **Both
are open, awaiting the owner's read and merge.** Until #215 merges, that decision is recorded only
in #186's comments and here — merge it first.

### Engines repository (done)

- GitHub account **`proxy-link`** (separate from `eliasmagdaleno`), public repo
  **`proxy-link/mangacarta-sources`**, cloned at `~/mangacarta-sources`, GitHub Pages on.
- SSH alias `github-proxy-link` in `~/.ssh/config` (key `~/.ssh/id_ed25519_proxy_link`, verified).
  Clone/push only through that alias. The clone's local git identity is
  `proxy-link <332702946+proxy-link@users.noreply.github.com>` — **never commit there as Elias**.
- `gh` is signed in as `eliasmagdaleno` only, pinned by a `GITHUB_TOKEN` env var; it cannot act as
  proxy-link. Repo creation/settings for proxy-link are the owner's, on the web.
- README (Inkdex-style: community-maintained, "does not provide or host content", no site names,
  removal requests honoured) points at `https://proxy-link.github.io/mangacarta-sources/index.json`,
  which is **404 until the engines are published** (slices 7–8 below). Owner chose the name knowing
  it links the repo to the app; Inkdex/Paperback precedent.


## What is owed — the plan

### No-built-in-Sources removal (slices; map in #215's context and the dependency inventory below)
1. ✅ merged — #223.
2. ✅ merged — #224. Route the recommender (`RecommendationEngine` injects `MangaDexSource()`), `MALReverseResolver`
   and the `MALEntityResolver` bridge (`MangaDexAPI.searchManga`) through the registry / "a Source
   that publishes external ids" instead of `MangaDexAPI`.
3. ✅ merged — #229 (`Manga`, `Chapter`, `Tag`, `MangaDetail`, `MangaUpdate` → `Models/MangaModels.swift`; `CoverSize` + `mangaCoverURL` → `Models/MangaDexCoverURL.swift`).
4. ✅ merged — #234: declaration `externalIds: ["mal"]` + optional `listing` operation (lookup by id), both gated on **Host API 1.1**; `externalIds` requires `listing`; listing-id mismatch ⇒ `invalid_result`.
5. MangaDex JSON-API engine. Researched in **#221**; it needs three host changes first — now filed as
   **#230** (wildcard asset origins — PR #237 in review), **#231** (scanlation group), **#232** (rate limiter): (a) a wildcard allowed in `assetOrigins` only (e.g. `https://*.mangadex.network`) —
   at-home image hosts are per-location and valid ~15 min, so exact origins cannot work; refuse
   shared-hosting suffixes and apply the public-address check to image loads; (b) a scanlation-group
   field on `ExtensionChapter`/`Chapter` — MangaDex's AUP requires crediting groups and the compiled
   source already violates this, so it is worth doing now; (c) a per-site rate limiter (~5 req/s, 40/min
   on at-home). Soft gap: no at-home report endpoint. `User-Agent` needs no change. `malId` already
   flows through listing `externalIds`; detail not checked.
6. Remove the bundled WeebCentral package, `BundledRepositoryTransport`, `bundled.invalid` routing
   and `installBundledSources()`; handle devices that already installed it (Amendment 6 leaves this
   to the removal PR).
7. Publish WeebCentral + MangaDex engines and a real `index.json` to `proxy-link/mangacarta-sources`
   (as proxy-link, via the alias).
8. Migrate persisted `"mangadex"` ids to the installed engine's qualified id — generalise
   `WeebCentralIdentityMigration`; keep data dormant, never delete, when MangaDex isn't installed.
9. Delete `MangaDexSource` / `MangaDexAPI`; fix Settings copy naming MangaDex.
10. Tests, `SimulatorSeed` fixture, UI tests (~40 files mention MangaDex; the live MAL/MangaDex UI
    tests need rethinking). Largest slice.

Dependency facts found (Explore, 2026-09-22): `SourceRegistry` crashes on `sources[0]` with zero
sources; nil-sourceId-means-MangaDex at `HistoryView:155`, `BookmarksView:265`, `LibraryStore:17,337`,
`HistoryStore:25`, `LibraryRefreshCoordinator:230`, `LibraryUpdatesPresentation:58`,
`TasteProfile:198`, `FulfillmentRouter:107` (slice 1 covers these). No deep-link handlers exist.



### Local import (per #216 / ADR-0025; owner answers recorded there)
Slice 1 = #217, slice 2 = #225 (**both merged**); slice 3 = **PR #236**, slice 4 (PDF) = **PR #235** — see top. Slice 2 is fully planned in **#222** and implemented in **PR #225 (merged 2026-09-24)**, with five owner
decisions (2026-09-22): `itemId` = first 16 bytes of the file's SHA-256 (re-import restores
history; settles spec §2/§5); one folder + loose root images → root images lead, then the folder;
only the app's staged copy is deleted, never the user's file; `local` kept out of the MAL outbox
(`MALProgressCoordinator` guard); "Local" hidden from Settings > About > Sources. The plan also found:
`sources[0]` fallbacks at `SourceRegistry:68,87,93` must become "first browsable"; `isBrowsable`/
`participatesInUpdates` must be protocol requirements (`MangaSource.swift:58-60`); the older
`LibraryStore:282-298` refresh path needs the same skip; `ImageCache` must not cache `file://`;
`WorkStore` needs `removeListing`. Land zero-sources slice 1 first — both edit
`SourceRegistry.swift:49-117`. Summary of scope: `LocalSource` (id `local`, compiled, always registered,
**not browsable** → hidden from Home's picker, not counted as "a Source installed"), import flow via
the document picker into `Application Support/LocalLibrary/`, staging-then-move, original deleted
after unpacking, SHA-256 duplicate check, one chapter per top-level folder (wrapper folder = one
chapter; root images = leading chapter; deeper nesting flattened), `participatesInUpdates = false`,
skipped by `MetadataUpgradeQueue` and MAL sync, one "remove = delete from device" action with a
warning. Later slices per the spec.

### Before App Store submission (from #215's research — carry these)
- No copyrighted manga in screenshots/marketing; no site names in metadata; no "free manga" wording.
- App Review notes and age-rating answers were written for "two content sources" — rewrite.
- Screenshot and App-Review sample-file art (public domain or original): **owner's, open.**
- Name: MangaCarta cleared a web check (no App Store/Play collision; a small "Manga Carta" podcast
  exists; mangacarta.com/.net taken, .app likely free). **Owner still to:** reserve the name in App
  Store Connect and run a USPTO knockout for MANGACARTA and CARTA (class 9). Then close #150.

### Carried from the previous handoff
- **App icon** — `docs/design/app-icon-brief.md` to a designer; placeholder ships until then.
- **Device-in-hand** — MAL live-write verify (`scripts/mal_live_write.py`,
  `TEST_RUNNER_MAL_LIVE_WRITE=1`); VoiceOver pass #90.
- Open issues: #150, #90, #230–#233. (#186, #203, #210 closed by #213, #212, #214 — verify they auto-closed.)

### Cleanup the owner runs (agent removal was refused by the permission classifier)
```sh
for w in fix-188-home-rails-declared-feeds fix-190-extension-storage-unreadable fix-197-age-gate-overlap fix-repo-settings-uitest-toggle; do orca worktree rm --worktree path:$HOME/orca/workspaces/Manga-Reader/$w; done
xcrun simctl delete Luna-190   # left behind by a worker
```
Also now removable: `local-import-zip-reader` (#217) and `zero-sources-slice-1` (#223).
Remaining worktrees belong to the open PRs and live workers above; remove each after its PR merges.

## Mechanics learned this pass

- **Workers' green tests can hide broken features — reviews keep catching it.** 2026-09-24: #235's PDF
  renderer drew unscaled and unflipped (tests only checked file names); #236's UI test bypassed the
  import it claimed to test and the app didn't compile in **Release** (CI builds Debug only — ask for a
  `-configuration Release build` when a PR touches `#if DEBUG` code); #225's focused run missed a stale
  registry test the full suite caught. Brief reviewers: "would this test fail if the feature were broken?"
- **A worker's final "style"/lint commit can break the build** (#236 `8242523`). Check CI after the
  *last* push, not the last substantive one.
- **Luna follows numbered fix lists well; ask for `git merge origin/main`, not rebase**, when a PR
  conflicts — no force-push, which the classifier blocks.
- **Two workers running parallel-testing suites drove load to ~600** (from a baseline of ~10). Don't run
  a coordinator suite then; rely on CI's `Build & unit tests` (the full unit suite) as full-suite
  evidence, and merge on green at the reviewed head.
- `npx skills check -g` **applies** updates (not a dry run). Impeccable is updated separately with
  `npx impeccable update` (it also installs global hooks — kept, per the owner).

- **Worker tests pass for the wrong reason; reviews catch it.** Three this session: a Swift Testing
  test using `XCTAssert` (Swift Testing doesn't record those, and it also wrote to a nonexistent dir —
  it could never pass or fail); a "legacy" decode test using a shape that never existed on disk
  (real files were keyed objects → data loss); a registry fix that lived in memory and vanished on
  relaunch. Brief reviewers to ask "does the test exercise the real on-disk / relaunch path?"
- **Worker "full suite" totals must be checked.** The suite is ~1080; one worker reported "148/148".
- **Six parallel simulators swamp the M5** (load ~1000; `FBProcessExit 64`; stuck xcodebuild after
  tests finish). Keep ≤3 simulator-bound workers, and have each create its own sim
  (`xcrun simctl create "Luna-<n>" "iPhone 17 Pro"`). Run coordinator suites serially.
- **New Orca worktrees lack `Secrets.xcconfig`** (gitignored) and fail to compile — copy it from the
  main checkout into each worktree root before dispatch.
- **A dispatched worker can sit idle with its brief unsubmitted** (seen 2026-09-22: 4 hours).
  `worker-read` shows `› [Pasted Content N chars]` at the prompt. Fix: `orca terminal send
  --terminal <handle> --enter` (no `--text`; `--wait-submit` needs `--text`). Check every new
  worker's first output after dispatch.
- **"Paused" workers stay paused across sessions.** A worker told to wait does not resume because a
  later handoff says so — verify with `worker-read`, then send it an explicit resume.
- **Worker-reported "full suite" is unreliable under load; run suites from the coordinator, one at a time.** With four workers building, load hit ~430 and every worker's full suite stalled; they pushed with focused tests only. Coordinator serial runs then found real failures in #213 and #223 that workers had not seen. Workers now get "run ONLY these classes" briefs; the coordinator or CI runs the full suite. CI's `Build & unit tests` is the full unit suite, so a green CI run is the full-suite evidence.
- **Pre-boot the simulator and pass its UDID** (`-destination id=<udid>`). A name-only destination picked the wrong runtime, and a non-booted sim once failed right after "Testing started" with no tests run.
- **`-only-testing` needs the Swift Testing *type* name, not the file name** — `HostCapabilityTests` selected only XCTest classes and silently skipped `struct HostHTTPTests`. Confirm "Test run with N tests" appears before trusting a mutation run.
- **This Orca build:** `worker-start --worktree new-top-level` is unsupported — create the worktree
  with `orca worktree create --name … --repo path:… --base-branch main --no-parent`, then
  `worker-start --worktree path:<path> --run <run> --from <coordinator handle>` (outside an Orca
  terminal `--from` is required). `worker-release` rejects `--run/--from`; pass only `--dispatch`.
- **`gh pr merge --delete-branch` exits non-zero when the local branch is in a worktree** even though
  the merge succeeded — check `gh pr view --json state`, not the exit code.
- **Docs-only CI runs skip the real jobs**, so `main` can look green over a red UI test (that is how
  #201's regression hid). Check the last *code* run.
- `timeout` does not exist on macOS.
- **Luna works best on short numbered lists and claims "succeeded" early.** One large brief (the 11-task
  #222 plan) came back as one commit with no tests and `--outcome succeeded`; the next round came back
  as 7 tests with the core put down as "Deviations". A six-item numbered list, with "commit and push
  after each" and "send failed if anything is left", finished it. Always read the diff and PR body before
  believing `worker_done`, and check that every suite constructing a changed type was actually run (#224's
  first round skipped `WorkMintingTests` → CI red).
- **Stalls:** a Codex session froze at "Working" for ~5h after a DNS failure, and both workers paused
  ~16:45–21:20 while the Mac slept (keep it awake with `caffeinate -dis`). The turn timer on screen only
  counts the current turn, so compare two reads to tell live from frozen.
- **Esc makes Codex *exit*** (`--interrupt` with `\e`), and text sent afterwards goes to **zsh** — it sat
  at a `quote>` prompt as a command. Recover with Ctrl-C (`--text $'\x03'`), then
  `codex resume <session-id>` (printed on exit), then send the message.
- `orca terminal send` reports "no turn start was observed" even when Codex accepted the prompt; read the
  screen instead of retrying.
- **`orca worktree create --base-branch main` bases on the *local* `main`, which is stale** (it gave `8e8f256` while `origin/main` was two merges ahead). After creating: `git -C <wt> reset --hard origin/main` (after `git fetch`), confirm `git log -1`, then dispatch.
- **`gh pr merge --auto` on an already-green PR merges immediately** — then the local-branch-delete error appears, as above.
