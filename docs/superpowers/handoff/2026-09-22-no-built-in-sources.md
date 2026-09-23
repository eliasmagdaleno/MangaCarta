# Handoff — no built-in Sources: decision made, removal and local import started

Date: 2026-09-22, 17:15 PDT
Repository: `/Users/eliasmagdaleno/Manga-Reader` (GitHub `eliasmagdaleno/MangaCarta`)
`main` at **`8e8f256`**.

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

## Open PRs and their state

| PR | What | State | Next |
|---|---|---|---|
| #215 | ADR-0003 A6 + ADR-0022 A4 + ADR-0016 amendment | docs, ready | **owner reads + merges** |
| #216 | Local import spec + ADR-0025 | docs, ready (only open item: screenshot/sample art, owner's) | **owner reads + merges** |
| #211 | #189 uninstalled-source fallback | reworked (`d8047bb`) to survive relaunch after review | full suite was running at handoff; review rework; merge |
| #212 | #203 ChapterOrdinal precision | reworked (`fb39011`) after review found it would **wipe every `updates.json`**; full suite 1074/1079 passed; PR body restored by hand | CI green → merge |
| #213 | #186 nested paging `{query, page:{cursor,limit}}` | worker `ctx_994ffe91994d` resumed, fixing only the cutover test | review worker's result; merge |
| #214 | #210 DNS-rebinding peer check | worker tests interrupted by sim contention | full suite + Claude review |
| #217 | Local import slice 1: ZIP reader | focused tests passed; no full suite, no swiftlint | full suite + swiftlint + Claude review |
| #195 | stale draft of ADR-0003 A5 | superseded (A5 merged via #199, reversed by A6) | close it (owner OK pending) |

A serial full-suite run over #211, #214, #217 was started in the background at 17:13; if its result
is lost, re-run: `xcodebuild … -only-testing:MangaCartaTests` in each worktree under
`~/orca/workspaces/Manga-Reader/`, **one at a time**.

**Still running at handoff (Codex, Orca run `run_e5fecb527d0a`):**
- `ctx_994ffe91994d` — #213 cutover test.
- `ctx_9737c57855a8` — **no-built-in slice 1**: zero-source safety (registry `active` optional, Home/
  Browse empty states with "MangaCarta does not provide or host content") + a `LegacySourceID`
  constant replacing 8 places that treated a nil source id as MangaDex. MangaDex stays registered in
  this slice. Worktree `zero-sources-slice-1`.

Drain their reports: `orca orchestration check --run run_e5fecb527d0a --terminal term_28f131d2-4563-47ea-b1bc-9df935d3b3d5 --json`
(`--ack <deliveryId>` each batch), then `orca orchestration worker-release --dispatch <id> --json`.

## What is owed — the plan

### No-built-in-Sources removal (slices; map in #215's context and the dependency inventory below)
1. ✅ dispatched — zero-source safety + legacy nil id (slice 1 above).
2. Route the recommender (`RecommendationEngine` injects `MangaDexSource()`), `MALReverseResolver`
   and the `MALEntityResolver` bridge (`MangaDexAPI.searchManga`) through the registry / "a Source
   that publishes external ids" instead of `MangaDexAPI`.
3. Move the `Manga` model and `mangaCoverURL` out of `MangaDexAPI.swift`.
4. Add external ids (`malId`, …) to the extension manga contract.
5. MangaDex JSON-API engine. Host `http` suffices, but check: dynamic at-home image hosts vs.
   declared origins (may need wildcard origins), and the `User-Agent` MangaDex requires
   (`HostHTTPClient` forbids overriding it). MangaDex AUP: must credit MangaDex **and** scanlation
   groups, honour removals, no ads/paid features.
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
Slice 1 = #217 (ZIP reader). Slice 2 next: `LocalSource` (id `local`, compiled, always registered,
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
- Open issues: #186 (being closed by #213), #189 (#211), #203 (#212), #210 (#214), #150, #90.

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
- **This Orca build:** `worker-start --worktree new-top-level` is unsupported — create the worktree
  with `orca worktree create --name … --repo path:… --base-branch main --no-parent`, then
  `worker-start --worktree path:<path> --run <run> --from <coordinator handle>` (outside an Orca
  terminal `--from` is required). `worker-release` rejects `--run/--from`; pass only `--dispatch`.
- **`gh pr merge --delete-branch` exits non-zero when the local branch is in a worktree** even though
  the merge succeeded — check `gh pr view --json state`, not the exit code.
- **Docs-only CI runs skip the real jobs**, so `main` can look green over a red UI test (that is how
  #201's regression hid). Check the last *code* run.
- `timeout` does not exist on macOS.
