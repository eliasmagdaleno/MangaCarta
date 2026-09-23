# Handoff — no built-in Sources: decision made, removal and local import started

Date: 2026-09-22, 17:15 PDT (updated 2026-09-23 09:30 PDT)
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
`main` at **`04a033d`** (#211). Nothing merged overnight; every open PR below is CI-green as of 09:30.

**This is the live handoff, and it is the whole of what is outstanding.** Writing a new one means
`git mv`-ing this into `archive/` first and carrying forward whatever below is still true
(`CLAUDE.md` → "Handoffs").

## Standing instructions from the user

- **Codex `gpt-5.6-luna` medium for implementation; Claude for review, decisions and docs.** Claude
  subagents are fine for read-only reviews, research and docs PRs (used heavily this session).
- **Every worker PR gets a Claude code review before merge.** This session the reviews caught three
  real bugs the workers' own tests passed over (see "Mechanics learned").
- **At forks, the user prefers prose discussion with a recommendation**, not a quiz.

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

## Merged this session

#204 (previous handoff), #205 (#188 Home declared feeds), #206 (#197 age-gate overlap), #207 (#196
repository destination policy), #208 (#190 extension-storage quarantine), #209 (flaky
`RepositorySettingsUITests` toggle — it was on `main` since #201; fixed by tapping the switch).
Closed: #168.

## Open PRs and their state (updated 2026-09-23 09:30 PDT)

| PR | What | State | Next |
|---|---|---|---|
| #218 | this handoff | docs | merge |
| #215 | ADR-0003 A6 + ADR-0022 A4 + ADR-0016 amendment | docs, ready | **owner reads + merges — first** |
| #216 | Local import spec + ADR-0025 | docs, ready (art still owner's) | owner reads + merges |
| #211 | #189 uninstalled-source fallback | **merged 2026-09-22** after Claude re-review; second CI run fully green (first-run UI failure was a flake) | remove worktree `fix-189-registry-uninstalled-fallback`; follow-up is #219 |
| #212 | #203 ChapterOrdinal precision | reworked, full suite passed | CI green → merge |
| #213 | #186 nested paging + v1 compatibility shim | **Ready.** Shim `fa0a43e`: every request carries nested `page` *and* identical legacy top-level `cursor`/`limit`; removal is dated in code + spec (published engines nested, no later than slice 6). Claude review: correct; the `engine-v1.js` fixture is byte-identical to `main`'s engine. CI then failed one test — `testExactlyOneCopyOfTheEngineScriptExists` counted the fixture as a second engine copy; Claude allowlisted the fixture with a remove-with-the-shim comment (`b2b91c7`), 14/14 local, **CI all green** | **owner merges** |
| #214 | #210 DNS-rebinding peer check | **Ready.** Two Claude reviews, rework + rebase (`c77f148`), coordinator full unit suite passed (936+150) and mutation checks on both `RepositoryTransport:115` and `HostHTTPClient:79` fail the real-path tests. **CI all green 22:45.** PR body says "Refs #210", exfiltration-only | **owner merges**; then file an issue for connect-time IP pinning (request can still reach a rebound host; proxies unhandled) |
| #217 | Local import slice 1: ZIP reader | **Ready.** Last pass `f0b77a0` reviewed: `unzip -v` confirms `deflated.cbz` is Deflate and `stored.zip` is Stored; full-payload + compression-method asserts; `extract()` exact-bytes and symlink-escape test; no `pages[0]` crash. **CI all green** | **owner merges**. Caveat for slice 2: `extract()` now refuses any destination whose path contains a symlink — believed fine on device (`resolvingSymlinksInPath` strips `/private`), but verify one real-device import |
| #223 | No-built-in slice 1: zero-source safety + `LegacySourceID` | Coordinator suite caught a real regression (stale active id returned nil despite a Source existing); fixed at `05955b1` with mutation check; 14 changed assertions audited and listed in the PR body; rebased onto main keeping #211 behaviour (`0dc8b15`). **CI all green 22:45** | short Claude review of the conflict resolution → owner merges. Slice 2 plan (#222) later needs "first *browsable* Source" instead of first Source |
| #220 | App Store submission copy (`docs/app-store/submission-copy.md`) | **draft**, docs | owner decisions below |
| #221 | MangaDex engine research (`docs/research/2026-09-22-mangadex-engine.md`) | docs | owner reads + merges |
| #222 | Local import slice 2 plan (`docs/superpowers/plans/2026-09-22-local-import-slice-2.md`) | docs; owner's five answers recorded at `7ed53ab` | merge; implement after zero-sources slice 1 and #217 |
| #195 | stale draft of ADR-0003 A5 | superseded | close it (owner OK pending) |

New issue: **#219** — `SourceRegistry.sourceForRefresh` ignores `knownSourceIDs`, so refresh still sends an uninstalled Source's Listings to the fallback Source (`LibraryRefreshCoordinator:168`, `LibraryStore:298`). `ready-for-agent`.

**No Codex workers live.** Both dispatches of run `run_e5fecb527d0a` (`ctx_ee4c7cf33ff0` #213, `ctx_3586b3d6910b` #217) were drained and released 2026-09-22 ~22:55. Removal slice 1 is PR **#223**.

**Merging is the owner's.** The auto-mode classifier refuses `gh pr merge` from the agent ("Merge Without Review"), even after a subagent review; the owner runs `! gh pr merge <n> --squash --delete-branch` (non-zero exit when the branch is in a worktree is harmless — check `gh pr view <n> --json state`).

Drain: `orca orchestration check --run run_e5fecb527d0a --terminal term_28f131d2-4563-47ea-b1bc-9df935d3b3d5 --json` (`--ack <deliveryId>`), then `orca orchestration worker-release --dispatch <id> --json`. **An empty queue is not progress** — also run `orca orchestration worker-read --dispatch <id>` and `git -C <worktree> status` per worker.

### Owner decisions pending from this session
- **#220 App Store copy:** (1) add an ADR-0022 amendment pointing at the new file (recommended); (2) age tier ~13+ Mild (agent's pick) vs 16+/18+; (3) give App Review a test repository with only owner sample content, or drop that sentence (never `proxy-link/mangacarta-sources`); (4) who makes sample/screenshot art; (5) subtitle "Read your comics, your way" vs "CBZ, ZIP & PDF comic reader", and whether "no ads"/privacy lines match the privacy label and #149. Two claims ("Import from Files" first run, ComicInfo.xml) describe unshipped features — verify against the build before submitting.

## What is owed — the plan

### No-built-in-Sources removal (slices; map in #215's context and the dependency inventory below)
1. ✅ dispatched — zero-source safety + legacy nil id (slice 1 above).
2. Route the recommender (`RecommendationEngine` injects `MangaDexSource()`), `MALReverseResolver`
   and the `MALEntityResolver` bridge (`MangaDexAPI.searchManga`) through the registry / "a Source
   that publishes external ids" instead of `MangaDexAPI`.
3. Move the `Manga` model and `mangaCoverURL` out of `MangaDexAPI.swift`.
4. Add external ids (`malId`, …) to the extension manga contract.
5. MangaDex JSON-API engine. Researched in **#221**; it needs three host changes first, each its
   own issue: (a) a wildcard allowed in `assetOrigins` only (e.g. `https://*.mangadex.network`) —
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

**Sequencing caution:** slices 2 and 4 touch the same registry code as slice 1 — start them after
slice 1 merges, or expect a rebase.

### Local import (per #216 / ADR-0025; owner answers recorded there)
Slice 1 = #217 (ZIP reader, in rework). Slice 2 is fully planned in **#222**, with five owner
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
- Open issues: #186 (#213), #203 (#212), #210 (#214), #219 (refresh misrouting), #150, #90.

### Cleanup the owner runs (agent removal was refused by the permission classifier)
```sh
for w in fix-188-home-rails-declared-feeds fix-190-extension-storage-unreadable fix-197-age-gate-overlap fix-repo-settings-uitest-toggle; do orca worktree rm --worktree path:$HOME/orca/workspaces/Manga-Reader/$w; done
xcrun simctl delete Luna-190   # left behind by a worker
```
Remaining worktrees belong to the open PRs above; remove each after its PR merges.

## Mechanics learned this pass

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
