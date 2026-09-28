# Handoff — mixed-Source title filter built (Tasks 1–6), not yet verified end to end

Date: 2026-09-28 (afternoon). This is the one live handoff. The prior handoff
(`2026-09-27-live-tests-and-tiebreak.md`) was moved to `archive/` before this one was written.
Recheck GitHub and the working trees before acting.

## Completed

- **Owner decision: `mixed` Sources are visible, and the switch hides adult titles, not Sources.**
  Recorded as ADR-0022 Amendment 6 (#262, merged). With the switch off, `erotica`/`pornographic`
  titles are hidden. `suggestive` shows by default. An unrated title from a `mixed` Source is hidden;
  one from a `none` Source is shown. Discovery is filtered; Library, history and notifications are not.
  `adultOnly` Sources and the reader's "Treat as adult" elevation still hide the whole Source. This
  closes the previous handoff's Next 2 and its "adult fallback edge" (Other 3), once the branch below merges.
- **#260 merged:** ADR-0004 A2. With no built-in favourite, install order settles ties.
- **#263 merged:** the hermetic UI job boots its simulator and waits on `simctl bootstatus -b`
  before the suites run. #260's two red runs were cold-boot timeouts in the first test to run,
  `LocalImportUITests.testImportReadAndDelete`, at launch and then at orientation. The other 16
  tests passed both times. With the fix, #263's own hermetic job and #260's re-run are green.
- **The title filter is implemented on `feat/mixed-source-title-filter`** (worktree
  `/private/tmp/mangacarta-mixed-titles`; pushed: **no**). Plan:
  `docs/superpowers/plans/2026-09-28-mixed-source-title-filter.md`, committed on that branch.
  Tasks 1–5 are reviewed and complete. Task 6 is committed (`8a87cb9`) but not yet verified or
  reviewed; see Next 1.
  - T1 `eaeb82f`: `AdultContentFilter.admits` and `AdultContentSetting`. The key stays
    `settings.showAdultSources`.
  - T2 `e3bf3de`: `isNSFW` now means `adultOnly` or elevated; new `declaresAdultTitles`.
  - T3 `f33e7ab..afdc8ee`: `active` and the fallback never pick a hidden Source while the switch is
    off. Also the notification-redaction fix (see "Decisions to promote").
  - T4 `f147a89`: `ExtensionSource` filters its five listing methods; `MALEntityResolver` uses the
    unfiltered `externalIdResolutionSource`.
  - T5 `e86f210`: `SourceRegistry.admitsForDiscovery` filters the For You rail, the ranked grid and
    More Like This. It fails closed on an unknown Source.
  - T6 `8a87cb9`: label "Show adult content", Home and Search refetch on change, and docs
    (CLAUDE.md, submission-copy, glossary).
  - After T5, the controller's full unit run was XCTest 1014 and Swift Testing 235, with 0 failures.
    Mutation checks were caught for the T4 filter, the T4 unfiltered resolution copy, and the T5
    engine filter.

## Next

1. **Finish the branch.** The SDD ledger is
   `/private/tmp/mangacarta-mixed-titles/.superpowers/sdd/2026-09-28-mixed-source-title-filter/progress.md`.
   Trust it and `git log` over memory.
   - a. Verify T6: run the full `MangaCartaTests` target, then `MangaCartaUITests/RepositorySettingsUITests`.
     That suite clears `settings.declaredAgeOver18` and `settings.showAdultSources`, so restore both
     to `true` on the seeded simulator afterwards (command under "Operating notes").
   - b. Review T6: build the package with the skill's `review-package` script over `e86f210..8a87cb9`,
     then dispatch a task reviewer.
   - c. Run a final whole-branch review on Opus over `f0122a4^..HEAD`. Point it at the ledger's
     deferred minors and rulings.
   - d. Check it on the simulator:
     - with the switch off and MangaDex installed, Home shows MangaDex rails;
     - a search for a known `erotica`-rated title returns nothing;
     - turning the switch on and going back to Search shows it.
   - e. Push and open the PR. The branch carries a `chore: untrack the SDD workspace reports` commit,
     because Luna force-added its report files; the squash nets them out.
2. **Decisions to promote to an ADR** (a decision that lives only in a handoff is not recorded).
   Add them to ADR-0022 as Amendment 7, or fold them into A6's PR if it is still open:
   - **Notification redaction keeps the pre-A6 meaning.** `UpdateNotifier.hidesAdultDetails` and
     `LibraryRefreshCoordinator`'s `sourceIsAdult` treat `isNSFW || declaresAdultTitles` as adult,
     so a saved Work on a `mixed` Source still has its notification details redacted while the
     switch is off. A6 point 4 says notifications are never *filtered*; redaction is not filtering.
   - **The fallback browse Source still prefers a non-adult Source when the switch is on.** A6 point 7
     only forbids the hidden case. The plan's code dropped the preference; Task 3 restored it.
   - **An all-adult feed page ends that feed** (`PagedMangaLoader` stops on an empty page). This is
     accepted and pinned by `testAFullyFilteredPageEndsTheFeed_acceptedByADR0022A6`.
3. **The remaining live UI tests.** Only 3 of the 16 that browse were run after #258. Run the rest
   by name, sort failures into "the catalog moved" and "real regression", and retire the ones that
   only proved the compiled Source.
4. **Cleanup the agent could not do (classifier-blocked):** remove the worktree
   `/private/tmp/mangacarta-tiebreak` and the branch `fix/no-preference-means-install-order`,
   locally and on origin. #260 is merged.

## Other outstanding work

1. **Rate-limit hint gap:** `ExtensionSource.invoke` drops `retryAfterSeconds` when it maps
   `ExtensionInvocationError` to `SourceError.invocation`. The MangaDex research also records the
   unimplemented at-home image-fetch report path. Decide both before claiming complete AUP coverage.
2. **Flaky tests:**
   - `MALAuthenticatedClientTests` "Concurrent 401s share one refresh" depends on order.
   - `LocalImportUITests.testImportReadAndDelete` should be fixed by #263. If it fails again on CI,
     the next suspect is the test's own launch timeout, not the boot.
3. **Deferred minors from the SDD run** (the final review should triage them):
   - `SourceRegistry.setInstalledSources` restores a stored chosen Source by existence alone, not
     `isBrowsableNow`. `active` still gates it, so it is contained.
   - `@Sendable` on `AdultContentSetting.current` is redundant.
4. **README is stale:** its Features line still says "MangaDex plus a Cloudflare-protected,
   HTML-scraped site", as if both were built in. Since #255 neither ships.
5. **`MangaDexSource` / `MangaDexAPI`** still compile because AniList, MAL and the resolver use
   them, but nothing registers them. Deleting or narrowing them is a separate refactor.
6. **App Store draft:** `docs/app-store/submission-copy.md` still needs the owner's original or
   public-domain sample and screenshot art, a sample URL/attachment, and contact placeholders. T6
   rewords the adult-content review note. Recheck every claim against the build that ships.
7. **Local import:** ComicInfo/open-in and Series grouping remain, per the local-import design.
8. **Human gates:** a manual VoiceOver device pass (#90); the MAL live-write check
   (`scripts/mal_live_write.py`, `TEST_RUNNER_MAL_LIVE_WRITE=1`); the MangaCarta name
   reservation/trademark check (#150); the app icon brief at `docs/design/app-icon-brief.md`.

## Operating notes

- **Orca orchestration does not work from a session that is not in an Orca terminal.**
  `run-create` fails with `no_active_sender_terminal`, and the only open terminal belonged to another
  project, so it was not borrowed. Luna ran through the plain CLI instead:
  `codex exec -m gpt-5.6-luna -c model_reasoning_effort=medium -s workspace-write --add-dir <worktree> -C <worktree> - < prompt.md`.
- **Luna's `workspace-write` sandbox cannot reach CoreSimulatorService**, so it cannot build or
  test (Task 1 once got through on an escalation; Tasks 2–6 did not). The controller runs every
  test and a mutation check per task. This caught a missing `import Foundation`, a dropped fallback
  preference, and a test that never reached the path it claimed to test.
- **Luna force-adds `.superpowers/` report files** despite the ignore rule. The dispatch rules
  now forbid it; check `git ls-files .superpowers` before pushing.
- **Seeded-simulator defaults:** unit tests that set `SourceRegistry.activeSourceID` write the real
  `source.activeID`, so they must save and restore it. The key is absent on the seeded simulator,
  and in the 09-27 post-smoke backup, and nothing was lost.
- **Simulator backups:** `~/Manga-Reader-sim-backup-2026-09-27` (pre-smoke) and
  `~/Manga-Reader-sim-backup-2026-09-27-post-smoke`.
- **The hermetic `RepositorySettingsUITests` clear two real settings** at launch. Restore them with
  `xcrun simctl spawn ADDAB2F8-38C7-4D44-97EA-4E98281CF691 defaults write Elias-Magdaleno.Manga-Reader <key> -bool true`
  for `settings.declaredAgeOver18` and `settings.showAdultSources`.
- **Simulator typing:** without Simulator → I/O → Keyboard → **Capture Keyboard**, the Mac keyboard
  drops keys in some fields.
- Name-based `xcodebuild` destination selection fails. Use
  `-destination 'platform=iOS Simulator,id=ADDAB2F8-38C7-4D44-97EA-4E98281CF691'`, the seeded
  iPhone 17 Pro, and keep parallel testing on.
- A new worktree needs `Secrets.xcconfig` copied from the main checkout. Under `/private/tmp`,
  `xcp` needs the `/tmp/...` spelling of the path.
- The classifier blocks `gh pr merge` and force pushes for the agent, and this session it also
  blocked worktree/branch removal. The owner merges without `--delete-branch`.
  `gh pr update-branch <n>` is allowed and brings a PR up to date without a force push.
- `SettingsView.swift` has three pre-existing `swiftlint --strict` violations. CI lints without
  `--strict` and passes.
- To replace this handoff, `git mv` it into `archive/` and carry every still-open item forward.
