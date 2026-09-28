# ADR-0018 verified in the app — 2026-08-11

**Question.** ADR-0018 Hazard 3 says the decision was accepted on a traced call chain and unit
tests, never on a running app. Does Decision 3 — *an unmatched refusal does not survive an
authoritative id* — actually fire, on real data, against the real APIs?

**Answer.** Yes. A Work that was refused with no external id acquired `mal: 133081` through an
ordinary user action, and on the next launch the queue reconsidered it, resolved it, and cleared
the refusal. The control Work, for which no id exists anywhere, was untouched.

**Scope of the claim.** This verifies **Decision 3**. Decision 1 (history carries the id its source
published) remains unit-tested only — see "What could not be verified".

## Setup

Seeded simulator `iPhone 17` / `2A0D54DF-5961-4286-A2B6-F24B4F7537B4`, the same one ADR-0017 was
verified on. State captured before the run:

| | |
|---|---|
| Works | 10 |
| Refusals in `upgrade-attempts.json` | 4, all `.unmatched(knownTitlesCount: 1)` |
| `Wind Breaker` Work | `externalIds: {}`, one Listing `mangadex / 9eb78304-0436-484d-9a79-a925b45e2731`, no snapshot |
| Placeholders `Qelparre Drift` / `Bramgot no Yeshu` / `Zurnak Vhelli` | `externalIds: {}`, WeebCentral, invented titles |
| History entry for `9eb78304` | `malId: nil` |

MangaDex publishes `links.mal = 133081` for that manga — checked live. So the Work was refused
*while an authoritative id sat one request away*, which is exactly the situation ADR-0018 is about.

**Fixtures.** `Wind Breaker` is the **positive** case and a placeholder is the **negative control**.
The 2026-08-11 handoff had these the other way round, reasoning from Wind Breaker's 1.00/1.00
ambiguity tie. The tie is what caused the refusal; it is irrelevant to whether an authoritative id
ends it. Recorded as ADR-0018 amendment 1.

Incidentally the tie is visible in the same data: MangaDex's first two hits for "Wind Breaker" are
`9eb78304` (mal 133081, Nii Satoru) and `c1c408f6` (mal 103237, the Korean series). Two real,
distinct works sharing a title exactly — the collision ADR-0008's ambiguity guard exists for.

## Method

`MangaCartaUITests/MangaCartaUITests.testADR0018WindBreakerAcquiresMalIdThroughSearch`, run
once by hand. Not a CI test: it asserts against one simulator's seeded state and stops being
meaningful when the refusals age out of their fourteen-day TTL (~2026-08-23).
**Retired 2026-09-28:** the test is deleted from `MangaCartaUITests.swift`. The seeded simulator
has since added Wind Breaker to its library, so the run cannot be repeated there; recover it from
`git show 62301f9:MangaCartaUITests/MangaCartaUITests.swift`.

The run goes through **Search**, not History. A search result's `Manga` came straight off the API
and carries `links.mal`; a pre-amendment history entry carries `malId: nil`, so the History route
could not have supplied the id no matter what the guard does.

Two route changes were forced by what the app actually does, both recorded because each is a small
finding:

1. **The reader path was unavailable.** MangaDex serves no chapters for this title — the detail page
   reads `0 AVAILABLE / No chapters yet`. The seeded history entry therefore points at a
   `chapterId` the source no longer serves, and could never have been resumed.
2. **`Add to Library` was used instead.** `LibraryStore.toggle` calls `works?.mint(from: manga)`
   (`LibraryStore.swift:138`) with the same API-sourced `Manga`, so it absorbs the id onto the
   existing Work under `ListingKey(mangadex, 9eb78304…)`. A real user action on a real code path —
   not a planted fixture. Planting one by hand-editing `works.json` was considered and rejected: it
   would have proved the guard works in a state the app cannot produce.

Then: relaunch, let the upgrade queue drain, read the files off the container.

## Results

**Immediately after the library add:**

| Work | before | after |
|---|---|---|
| `Wind Breaker` | `{}` | **`{'mal': 133081}`** |
| `Qelparre Drift` | `{}` | `{}` |
| `Bramgot no Yeshu` | `{}` | `{}` |
| `Zurnak Vhelli` | `{}` | `{}` |

The refusal record still read `.unmatched` at this point, which is correct and worth stating: the
guard is a **read-time** check (`UpgradeAttemptMemory.swift:96`), not a rewrite of stored memory.
An observer looking for the record to change here would wrongly conclude nothing happened.

**After the next launch and a queue drain:**

| | before | after |
|---|---|---|
| Refusals | 4 | **3** — `Wind Breaker`'s entry cleared |
| `Wind Breaker` ids | `{}` | `{'anilist': 135083, 'mal': 133081}` |
| `Wind Breaker` snapshot | none | AniList, **28 tags, 3 genres** |
| `Wind Breaker` known titles | 1 | 5 |
| Placeholders | refused, no ids, no snapshot | unchanged |

That is the whole chain: guard releases → queue reconsiders → resolver short-circuits on the
authoritative id → AniList fetch → tags land → `memory.forget`. The Work is back in the taste
profile carrying 28 tags of real signal, where before it contributed nothing and displayed
ADR-0015's "cannot be matched" notice.

**Hazard 3 is closed.**

## What could not be verified

- **Decision 1's in-app leg.** No refused Work on this simulator is re-readable — `Wind Breaker`
  has no chapters, and the other three refusals are invented WeebCentral titles that exist nowhere.
  The history-write path is covered by unit tests only, including two added here for
  `ReadingEntry.asManga`. Do not read this document as verifying it.
- **The rendered notice.** The guard's effect on `tagBlocked` was verified through the data it
  drives, not by asserting the notice's disappearance in the UI. Absence is a weak assertion — the
  notice is also absent when the view never rendered.

## Found on the way

**`ReadingEntry.asManga` dropped the id** (`HistoryView.swift:140`, `malId: nil` hardcoded). This is
the resume path: `HistoryView` hands `entry.asManga` to `ReaderView`, which hands it to
`HistoryStore.record`, which reads `malId` off it. So ADR-0018's "the id arrives naturally as titles
are read again" was not true on the route a re-read actually takes — the same boundary loss the ADR
was written to close, one layer further out. Fixed, with two tests. `asManga` widened from
`fileprivate` to internal so it can be tested.

`BookmarksView.asManga` looks identical but is **correct** as-is: `LibraryItem` has no `malId` to
carry, because ADR-0018's Scope deliberately excludes it. A comment now says so, since the next
reader will otherwise "fix" it.

## Method worth reusing

- **A compile error is not a red.** The first run of the new unit test failed to build
  (`fileprivate`), which proves nothing. Widening access, re-running, and getting
  `("nil") is not equal to ("Optional(133081)")` is the red worth having. Same lesson as the
  ADR-0018 session that preceded this one, learned again in the same session it was written down.
- **Trace who can write the field before claiming a code path is dead.** The first answer to "how
  does a refused Work ever get an id?" was *it can't* — which would have made Decision 3 dormant
  code. Enumerating the three writers of `externalIds` found the path, and it turned out to be the
  common case rather than an edge one.
- **Check the container after every install.** Running the unit tests reinstalled the app and
  changed its data-container UUID twice; the data survived, but a path captured before a build is
  stale after it. Resolve the container by `MCMMetadataIdentifier`, not by remembering the UUID.
