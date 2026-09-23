# CLAUDE.md

Guidance for coding agents working in this repository — Claude Code and Codex alike.

**`AGENTS.md` is a symlink to this file.** One source of truth, so the two cannot drift:
edit *this* file, never a copy. (They were separate files until 2026-08-21, and the copy
had already gone stale about what `isRead` means.) If Codex ever needs genuinely different
instructions, replace the symlink with a real file at that point — not before.

## Overview

Native SwiftUI iOS app (a MangaDex reader client). No third-party dependencies or
package manager — pure SwiftUI + Foundation. Xcode project only (no SPM/CocoaPods).

- Scheme / target: `MangaCarta`
- Deployment target: iOS 17.5 (some UI branches on `#available(iOS 18.0, *)`)
- Test targets: `MangaCartaTests` (unit), `MangaCartaUITests` (UI)

## Commands

One non-obvious requirement applies to **every** `xcodebuild` invocation here:

- **Target the iPhone 17 Pro simulator** (`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`).
  It is also the device holding the seeded fixture (see `scripts/seed-simulator.sh`), so a
  run against a different device gets an empty library and quietly different results.
- **Use parallel testing.** This repository now runs on an M5 MacBook with enough overhead for
  Xcode's cloned simulator instances. Leave parallel testing enabled (the default), or pass
  `-parallel-testing-enabled YES` when an explicit setting is useful.
- **CI's toolchain is a major version behind this machine's.** The workflow pins `macos-15`,
  which builds with Xcode 16.4 / Swift 6.0; local development is on Xcode 26.x / Swift 6.2. So a
  green local build proves nothing about CI when the change uses newer language syntax. This has
  already cost one red run: `extension BGTask: @MainActor BGTaskLike {}` — an SE-0470 *isolated
  conformance*, Swift 6.2 only — compiled locally and failed on CI with `error: unknown attribute
  'MainActor'` (fixed in #101 by boxing `BGTask` in a `@MainActor` wrapper instead). Treat
  isolated conformances, `nonisolated(nonsending)`, `@concurrent`, and `Task.immediate` as
  unavailable, and expect the failure to appear only after pushing.

Run a single test class or method (Swift Testing / XCTest via `xcodebuild`):

```sh
xcodebuild -scheme MangaCarta -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:MangaCartaTests/MangaCartaTests/<testMethod>
```

For interactive work, opening `MangaCarta.xcodeproj` in Xcode and using ⌘B / ⌘U is
usually faster than the CLI.

## Architecture

MVVM over a source-abstraction layer. Data flows: `MangaSource` (protocol, network) →
`@MainActor` `ObservableObject` view models → SwiftUI views. Nothing outside the source
adapters calls `MangaDexAPI` directly.

- **`Models/MangaSource.swift`** — deliberately **bridge-friendly** (only `Int`/`String`
  params, value/Codable returns) so a future dynamic-extension runtime can conform via a
  bridge. `newTitles`/`latestUpdates` are optional capabilities whose default impls throw
  `SourceError.unsupported`.
- **`Services/SourceRegistry.swift`** — owns the registered sources and the active browse
  source. ViewModels/Services fetch through this, **never** `MangaDexAPI`. The registry is
  **injected, not reached for**: `AppComposition.registry` is the graph's one, it is in the
  environment, and views take it from there. `SourceRegistry.shared` survives only as that
  composition's production default and in `#Preview` blocks — a view or view model reading
  it directly is the bug fixed on 2026-09-02, where an injected registry and the singleton
  were different objects and every source lookup on the detail page missed.
- **`Services/WebViewService.swift`** + **`Services/SourceContext.swift`** — the host
  capability layer for HTML-scraping sources. The shared off-screen `WKWebView` uses a
  **persistent** data store so Cloudflare's `cf_clearance` survives, plus a **pinned UA**;
  an injected JS script's final expression must be a `JSON.stringify(...)` string.
  Interactive Cloudflare challenges surface the WebView in a sheet; declines are sticky for
  30s and task cancellation is honored. Sources receive it via `SourceContext` — mock the
  `WebViewExtracting` protocol in tests.
- **`Models/WeebCentralSource.swift`** — the per-page JS extraction scripts are co-located
  raw strings, and they are **the volatile part** when the site redesigns.
- **`Models/MangaDexAPI.swift`** — decoding goes through one generic `request` helper using
  `.convertFromSnakeCase`. `toManga(id:relationships:)` stamps `Manga.sourceId` with the
  MangaDex source id — every conversion path must keep doing so.
- **`Models/*ViewModel.swift`** — errors surface as `errorMessage` strings, never thrown
  past the view model.

Key conventions worth preserving:

- **Covers are always prefetched.** Every `/manga` query injects
  `includes[]=cover_art`, and `MangaAttributes.toManga` pre-builds a `coverURL` so the
  `Manga` model always carries a ready-to-use cover URL for `AsyncImage`. Cover URLs are
  built by the free function `mangaCoverURL(mangaId:fileName:size:)` against
  `uploads.mangadex.org`, defaulting to the 512px JPEG variant.
- **Latest Updates is a two-step fetch:** `fetchLatestUpdates` first pulls recent
  `/chapter` entries (with `includes[]=manga`), dedupes to unique manga preserving order,
  then batch-fetches those manga by `ids[]` with covers. Reader page URLs come from
  `pageURLs(for:)` which hits `/at-home/server/{chapterId}` and composes
  `{baseUrl}/{data|data-saver}/{hash}/{file}`.

## Adding files to the project

`Models/`, `Services/`, and `Components/` are Xcode 16 **synchronized groups**
(`PBXFileSystemSynchronizedRootGroup`) — new files dropped in them are compiled
automatically. Note `Components/` is synchronized but lives **nested under `Views/`** on
disk (`MangaCarta/Views/Components/`), so a shared UI component goes there and needs no
`project.pbxproj` edit.

**`Views/` and `MangaCartaTests/` are NOT synchronized** — they are plain `PBXGroup`s, so
a new file in either needs four `project.pbxproj` entries: a `PBXFileReference`, a
`PBXBuildFile`, a child entry in the group, and an entry in the target's `Sources` build
phase.

Use **`xcp`** (`brew install xcp` — XcodeProjectCLI) rather than editing by hand; it writes
all four:

```sh
xcp add-file "$PWD/MangaCarta.xcodeproj" \
  --file "$PWD/MangaCartaTests/NewTests.swift" --targets MangaCartaTests
```

`xcp delete-file` reverses it, and **also deletes the file from disk** unless you pass
`--project-only`. `xcp list-targets MangaCarta.xcodeproj` is a safe read-only check.
Verified 2026-07-26 with xcp 1.2.1: the added file compiled and its test ran.

**Caveat:** any `xcp` write reformats the three `PBXFileSystemSynchronizedRootGroup` entries
from one line each to multi-line — semantically identical and Xcode accepts it, but it turns a
4-line change into ~31 insertions / 3 deletions. Either keep the reformat or `git checkout`
those hunks before committing.

**The reformat can vanish on its own, which makes `git diff` right after `xcp` untrustworthy.**
If Xcode has the project open it rewrites `project.pbxproj` back to one-line form on its own
schedule — so the same `xcp add-file` shows 31 insertions immediately and 4 insertions some
minutes later, with nothing in between having touched the file. **Check `git diff --stat`
immediately before `git add`, not right after `xcp`** — and don't conclude from one clean diff
that the caveat above no longer applies.

**The rewrite is not tied to `xcp` at all.** Corrected 2026-08-08: this section used to say
"neither `xcodebuild build` nor `xcodebuild test` does this; only Xcode itself." A session that
never ran `xcp` saw `project.pbxproj` churn twice anyway — the three synchronized-group entries
collapsing from multi-line to one-line, plus a `name =` key dropped from a file reference —
during plain `xcodebuild build` / `test` runs, with Xcode open the whole time. Whether
`xcodebuild` provokes it or Xcode simply rewrote on its own schedule was **not** isolated (Xcode
was running in both cases), so the only claim worth carrying is the practical one: **if Xcode has
the project open, treat `project.pbxproj` as able to change under you at any moment, `xcp` or
not.** Check it before every `git add`, and `git checkout` the file when the churn is unrelated
to your change.

Adding the file in Xcode also does all four correctly. Hand-editing `pbxproj` is the last
resort; if you must, mirror an existing entry across all four sections.

## Current state

- `LocalSource` and `LocalLibraryStore` provide the on-device CBZ/ZIP library; Local is always registered but excluded from browse and update surfaces.

The app builds and the core reading loop is implemented.

- **Reader:** R→L is implemented as **reversed page order — NOT a mirror transform.** A
  previous mirror-based approach inverted zoomed panning. Paged zoom is `UIScrollView`-backed
  (`Components/ZoomableContainer.swift`) for native pinch/pan physics.
- **Read state:** per-chapter read/unread marks ship (`HistoryStore`, since 2026-07-14) —
  single and batch `markRead`/`markUnread`, mark-all-below, dimmed rows, unread badges.
  `isRead` means **read to the end, or manually marked** — `ReadingEntry.isComplete` is
  `pageCount > 0 && page >= pageCount - 1` (#65, 2026-08-20). Opening a chapter still
  records an entry, which is what mints the Work and what makes the vertical reader record
  anything at all; but an opened-and-abandoned chapter is *not* read, so it still counts
  toward the unread badge.
- **Background refresh:** ADR-0021 shipped 2026-08-30 (PR #101, issue #92). The library now
  polls for new chapters on its own — `LibraryRefreshCoordinator` runs the pipeline,
  `UpdateScheduler` drives it from `BGTaskScheduler` plus foreground activation, and
  `UpdateNotifier` posts authorization-gated new-chapter notifications. Update state persists
  in `updates.json` (`UpdateStateStore`); "newly discovered" is tracked separately from
  `isRead` and clearing it never marks anything read.
- **Fulfillment:** ADR-0004 shipped 2026-08-31 (PRs #116, #118). A Work with more than one
  Listing is served by a ranked choice, not by whichever source was seen first —
  `FulfillmentRouter` ranks, `ListingCountCache` supplies the chapter counts ranking needs (24h
  TTL), and `FulfillmentCoordinator` ties the two to the registry. Two user controls override it:
  a **primary source** in Settings, which settles *ties only*, and a **per-Work pin** on the
  detail page, which beats the ranking outright and persists (`SourcePreferenceStore`).
  Switching genuinely re-fetches — `MangaDetailViewModel.retarget(to:using:)` moves fulfillment
  while the displayed `Manga` stays put, because ADR-0001 makes the Work the identity and a
  Listing only one source's copy. A `nil` chapter count means **unknown, never zero**; see
  ADR-0004 and its amendments for the evidence tiers and the reasoning behind each control.
- **Extension runtime:** Phase 3 shipped 2026-09-11 — a JavaScriptCore substrate for
  configuration-backed Sources, per ADR-0003 and the Host API design. `ExtensionRuntime` builds one
  `JSContext` per invocation from a bundle script plus a validated `SourceDeclaration`;
  `SourceDeclarationValidator` and `ExtensionDomainValidator` police what goes in and what comes
  back; `SourceLifecycleRegistry` owns disable/uninstall/reinstall. An engine is one bundle script
  serving differently configured Sources with no site baked into it; WeebCentral is a declaration,
  not code.
- **Phase 4 (repository format + installer) is complete** as of 2026-09-22: all three host
  capabilities are bridged (#170); `RepositoryIndexValidator` parses format-1 indexes (#173);
  `RepositoryStore` + `ExtensionInstaller` mint identity, install, update and persist over
  `SourceLifecycleRegistry` (#175, #183); and `ExtensionSource` is the `MangaSource` adapter over
  `ExtensionRuntime` (#184). **Installed Sources are now live in the app graph:** at launch
  `ExtensionSourceRegistrar` restores every active install from the store into
  `AppComposition.registry`, *added* beside the built-in Source, never substituted. The host stamps
  `Manga.sourceId` with the qualified id on every conversion path (the MangaDex `toManga` rule), and a
  disabled or uninstalled Source fails as unavailable while its Listings, pins and history are kept.
  **S5 and S6 landed 2026-09-21** (#193, #192): Settings has a repository manager (add by URL,
  refresh, change URL, remove; install/update/disable/enable/uninstall) over the production
  `URLSessionRepositoryTransport`, and a `mixed`/`adultOnly` install always shows the declared-age
  sheet (ADR-0022 A2; format design §7.1 — a confirmed reader sees the class named but is not asked
  again).
  **The WeebCentral cutover landed 2026-09-22** (#201; ADR-0003 Amendment 5, format design §12). The
  compiled `WeebCentralSource` is deleted and `builtInSources()` is MangaDex alone. WeebCentral ships
  as a **bundled package** in `MangaCarta/Resources/BundledRepositories/weebcentral/`, which must stay
  a **folder reference** in the pbxproj — otherwise Xcode flattens it and
  `url(forResource:subdirectory:)` returns nil. Bundled URLs use the never-resolvable host
  `bundled.invalid`, which `AppRepositoryTransport` serves from the app bundle;
  `ExtensionComposition.installBundledSources()` installs on first launch, and
  `WeebCentralIdentityMigration` rewrites persisted bare `"weebcentral"` ids to the qualified id.
- Design/spec/plan for shipped work live in `docs/superpowers/{specs,plans}/`.

Still minimal: no cross-device sync. Content refresh is no longer manual-only (see above);
`MetadataUpgradeQueue` also runs on its own on `scenePhase` becoming active.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `eliasmagdaleno/MangaCarta`, via the `gh` CLI.
See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label string equal to its name (`needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. The glossary is `docs/glossary.md` — **not** `CONTEXT.md`, which does not exist
here — and decisions are the numbered ADRs in `docs/adr/`. See `docs/agents/domain.md`.

### Handoffs

`docs/superpowers/handoff/` holds **exactly one file: the live one.** Everything else lives in
`archive/` and is a historical record — never work from it.

Writing a new handoff means `git mv`-ing the current one into `archive/` first, and **carrying
anything still owed into the new document.** A handoff is the complete picture of what is
outstanding, not the newest slice; if the previous session left work unfinished, that work is
now yours to restate, not to leave behind in a file nobody will open.

This replaced a convention of banner-marking each file "consumed" by hand. Sixty of sixty-six
carried no marker, which is what a rule that depends on remembering is worth. Currency is now a
fact about location. The cost of forgetting is visible in one `ls`.

The rot this prevents has hit this repository five times; the fifth changed what an agent *did*
rather than merely what a document said. See `docs/superpowers/handoff/archive/README.md`.

### Document ownership

**Every fact about this project has exactly one owning document. Non-owners link; they never
restate.**

| Owner | Owns |
|---|---|
| `docs/adr/` | Decisions and their reasoning. **Amend, never correct.** |
| `docs/glossary.md` | Terms. What a word means here. |
| `CLAUDE.md` | Build and agent conventions, and current implementation state. |
| `PRODUCT.md` | Intent, users, positioning, and open product questions. |
| `DESIGN.md` | The visual system — tokens, components, do's and don'ts. |
| `README.md` | A stranger's first sixty seconds: what this is, a screenshot, how to run it. |
| `docs/superpowers/handoff/` | What is outstanding *right now* (see "Handoffs" above). |

The failure this prevents is not a document going stale — it is the *same fact stated twice* and
the two copies diverging, which is three of the five known instances of rot here. A duplicate
cannot be kept true by diligence; both copies need updating by someone who remembers both exist,
and the archive convention above records what a rule like that is worth.

So the fix for a stale claim is usually **deletion plus a link**, not a correction. Before adding
a fact to a document, ask whether that document owns it. If it does not, the fact belongs in the
owner and this document gets a pointer — or nothing at all.

Two consequences worth stating outright:

- **`README.md` carries no shipped/next/deferred roadmap and no architecture breakdown.** Both
  were duplicates — of the live handoff and of `CLAUDE.md`'s "Architecture" and "Current state"
  — and both were wrong when the rule was written: the README still called the extension system
  "shelved" after it had become the critical path, and still gave build commands for the wrong
  simulator. Its Features list stays, because *what the app does* is what a stranger came for;
  it is a description, not an inventory of what has landed.
- **A decision that lives only in a handoff is not recorded.** Handoffs get archived, and
  archived handoffs are explicitly never to be worked from. Promote it to an ADR — or to an
  amendment, if it revises one — while the handoff is still live.
