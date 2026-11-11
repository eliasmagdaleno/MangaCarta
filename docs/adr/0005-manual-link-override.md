# ADR-0005 — Resolution failures are user-correctable via a manual link override

- **Status:** Accepted (2026-07-24), amended 2026-08-08 and 2026-11-11. **Being built**: the Listing → Work
  override is un-parked by Amendment 2, below
- **Related:** ADR-0001 (Work vs Listing), ADR-0004 (fulfillment routing), ADR-0015 (ships the
  visibility half of this decision for the total-failure case, and names this ADR as its first
  revisit trigger)

## Amendment 2 (2026-11-11): the Listing → Work override is un-parked

Amendment 1 parked the Listing → Work case until "a third source lands". That has happened: installed
Sources replaced the two built-in ones (ADR-0003 Amendment 6). The owner has also asked for it, on
2026-11-11, as per-title Add a Source / Remove a Source. It is designed in
`docs/superpowers/specs/2026-11-11-per-title-sources-design.md`. Four decisions there belong to this ADR:

- **The override lives on the Work, in `works.json`.** It isn't a separate store. The Work records the
  Listings the reader added by hand and the Listings the reader removed. `works.json` is authoritative
  user data, not a cache, which meets "never evicted".
- **A removal is sticky and keeps ADR-0008's invariant.** A removed Listing is never relinked
  automatically. If the reader commits to it again, it mints its own Work, which doesn't take an external
  id owned by a Work that removed it. So there are never two Works for one id, and nothing for the
  load-time repair to merge.
- **Unlinking asks why.** "Same title, unwanted copy" keeps the copy's reads counting for the Work, as a
  retired Listing (ADR-0027's union widens to include it). "A different title" stops them counting.
  History itself is never deleted.
- **Local Listings are out of scope.** Local-library matching owns their link and unlink. Both features
  use one `WorkStore` link operation.

Amendment 1's Work → MAL id override is unaffected and still blocked on a report.

## Amendment (2026-08-08)

This ADR was grilled against the call sites it commits to, on the handoff's recommendation that it
be built next. **It is not being built next**, and two things in it are wrong. The decision itself —
keep the precision bias, give the user an override — is unchanged.

**1. The target is Work → MAL id, not Listing → Work.** As written, this ADR is about linking a
Listing to a Work: two sources' pages for the same manga, collapsed by hand. The primitive for that
is `WorkStore.merge(_:into:)` (`:243`), whose own comment already anticipates "a manual link arrives
after both Works already exist". But that is not the failure the app observes. `SourceRegistry`
registers exactly two sources (`:46`) — MangaDex, which hands over `attributes.links.mal` for free
and never reaches the title matcher, and WeebCentral, which does. So every silently-unresolved Work
today failed at **Work → MAL id**, recorded as `UpgradeAttemptMemory.unmatched(knownTitlesCount:)`
and surfaced by ADR-0015's notice. The primitive is `setExternalIds(_:on:)` (`:230`), not `merge`.

The Context below argues from "under ADR-0003 the number of sources is meant to grow substantially".
That growth is **shelved deliberately since 2026-07-21** (the extension/repo system and comix.to).
The Listing → Work case is therefore not a near-term failure; it is a real one that has not arrived.

**2. It is blocked on a report, not pending.** ADR-0015 set the standard for its own mixed-library
hazard: not due until *reported* as bad output rather than inferred from reading the code. The same
test applies here, and this ADR fails it — the failure was derived from reading `MALTitleMatcher`,
not from anyone hitting it.

**What survives and is worth building before any of the above:** the *visibility* requirement. This
ADR's first implied requirement — failures must become visible — is half-shipped. ADR-0015 covers
the total-failure case (every Work untaggable → a notice). The **per-item** case does not: three
untaggable Works beside twenty taggable ones clears the gate, builds a rail, and leaves the omission
exactly as silent as it was before. That gap is small, needs no override store and no picker UI, and
is what this ADR's argument actually earns today.

**Shipped, same day:** `UnmatchedTitleNotice`, in `MangaDetailView`'s "More Like This" slot. The
first implied requirement is now met on both scales; the override itself remains blocked on a report.
Four things about it are decisions rather than details:

- **The predicate is `RecommendationEngine.isUnmatchable`, wrapping the same `tagBlocked` closure the
  rail state is built from.** One predicate, so the detail screen and the rail cannot disagree about
  one Work. It lives on the engine because ADR-0010 keeps `UpgradeAttemptMemory` out of the
  environment, and the engine already holds the closure and already *is* an `EnvironmentObject`.
- **Not published, deliberately.** A settled refusal reopened on a fourteen-day TTL is not something
  that changes while a screen is open. A title opened mid-drain gains the notice on the next visit.
- **Statement only, no action.** Unlike the rail notice, which can honestly say "read something from
  MangaDex", there is no useful action here — and the real remedy is this ADR's override, which does
  not exist. Telling someone to go read a *different* title because they opened this one is bad advice.
- **The copy says "couldn't look up", not "couldn't match".** `suppresses` is true for *two*
  outcomes and only one is a matching failure: `.unmatched` is, `.absentFromProvider(malId:)` is not —
  there the title matched MyAnimeList and AniList simply has no entry for that id. Naming it as a
  match failure would be false in that case, and the distinction is not one the reader can act on.
- **A title with no Work shows nothing.** Works mint only at commitment points (ADR-0007), so a
  browsed title has no recorded attempt; inferring refusal from the source instead would be guessing,
  against this area's standing precision bias.

One thing the device check corrected: the placement's premise was "More Like This is empty for this
title, from the same cause." That is **not** automatically true — `MoreLikeThisProvider` resolves via
`MALEntityResolver.malId(for:)`, which is **Listing-keyed and independent** of the Work-level attempt
memory. They agree in the ordinary case (a Work minted from one Listing carries that Listing's title,
so both matchers see the same string), but they are two resolvers and can differ. The notice is
therefore gated on the rail being empty *and* the Work being refused, never on the refusal alone.

**Revisit when** a Work's absence from recommendations is reported as wrong, or when a third source
lands and the Listing → Work case stops being hypothetical.

## Context

`MALTitleMatcher` is deliberately **precision-biased**: normalized Levenshtein, exact-match-wins,
a 0.90 threshold and a 0.05 ambiguity guard, returning `nil` rather than guessing. That is the
right bias — a wrong link corrupts identity, history, and recommendations, while a missing link
merely omits something.

But the failure is **silent**. A Listing that doesn't resolve simply never appears: no error, no
log, no UI. Today, with MangaDex handing over `malId` for free (`attributes.links.mal`) and only
one scraped source, that is tolerable. Under ADR-0001 every non-MangaDex Listing is linked by
fuzzy title match, and under ADR-0003 the number of sources is meant to grow substantially. Silent
non-resolution then becomes both the most common failure and the least visible one — and per
ADR-0004 it degrades routing invisibly, since an unresolved Listing cannot be ranked.

Alternate titles, romanization differences, and regional retitling (the "Attack on Titan" /
"Shingeki no Kyojin" class of problem) mean this is a permanent condition, not a bug to be fixed
by a better matcher.

## Decision

**Keep the precision bias, and give the user a manual override.** Where the app cannot confidently
link a Listing to a Work, the user can establish the link by hand, and the override is persisted
and authoritative over any future automatic match.

Implied requirements:

- Failures must become **visible** — an unresolved Listing needs somewhere to be seen. Silent
  omission with a manual override the user never knows to reach for is no better than silent
  omission.
- The override store must survive cache invalidation. `EntityResolutionStore` currently expires
  misses after 14 days and keeps hits forever; a **manual link is not a cache entry** and must
  never be evicted or overwritten by a later automatic match.
- The reverse operation — *unlinking* a wrong automatic match — is the same feature and should
  ship with it.

## Consequences

- New UI surface (link/unlink a Listing to a Work) plus a persisted override store.
- The matcher can stay conservative permanently; there is now an escape hatch, so raising recall
  at the cost of precision is never the answer to a complaint.
- Manual links are user data with no backup path — the app has no cross-device sync, so a
  reinstall loses them. Acceptable for now; worth revisiting if sync ever lands.
