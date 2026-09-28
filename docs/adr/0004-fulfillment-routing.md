# ADR-0004 — Fulfillment: most complete English chapter run wins; MangaDex breaks ties

- **Status:** Accepted, with a required fallback (2026-07-24). **Amended 2026-08-31 —
  Amendment 1 below replaces the MangaDex tiebreak with a reader-chosen primary source, and makes
  the per-Work override sticky.** The ranking itself is unchanged; read Amendment 1 for the
  tiebreak
- **Related:** ADR-0001 (Work vs Listing), ADR-0002 (catalog), ADR-0005 (manual link override),
  ADR-0007 (Work shape — the cached counts this ADR ranks on live in a separate, evictable store;
  a missing count means *unknown*, never zero)

## Context

Once a Work has several Listings (ADR-0001), opening it must choose one. The user's stated
preference: the source with the **most complete chapter availability in English**, using MAL /
AniList's known chapter total as the reference for "how many are out"; MangaDex preferred when
two sources tie.

## Decision

Rank a Work's Listings by **English chapter completeness**, then prefer MangaDex on a tie.

```
1. count each Listing's distinct English chapters
2. rank by that count, descending
3. equal counts → prefer MangaDex; then by source registration order
```

MangaDex-first is a **quality** preference (better scans, better metadata, no ads), not an
availability one — so it only applies at equal completeness. A source with materially more
chapters wins over MangaDex.

## The reference total does not work as stated — required fallback

Verified live against AniList on 2026-07-24:

| Work | `status` | `chapters` |
|---|---|---|
| Solo Leveling | `FINISHED` | 201 |
| Jujutsu Kaisen | `FINISHED` | 272 |
| **One Piece** | **`RELEASING`** | **`null`** |

**Ongoing series report `chapters: null`.** The metadata providers only know a total once a
series has finished — and ongoing series are exactly the case where sources diverge on how
current they are. A finished series is either complete on a source or it isn't; the routing
decision barely matters. For One Piece it matters every week, and that is precisely where the
reference total is unavailable.

So the policy is:

- **Reference total known** (`FINISHED`, non-null `chapters`): completeness is
  `sourceChapters / total`, and a source at 100% can short-circuit the comparison.
- **Reference total unknown** (`RELEASING`, null): **the sources define the frontier.** Rank by
  raw English chapter count — whoever has the most is by definition the most current. No
  provider call is needed or useful.

The provider total therefore *refines* the ranking when available; it is never required for it.

## Consequences and open questions

- **Counting strategy: optimistic render, then reconcile.** Counting chapters per Listing means
  asking every candidate source for a chapter list — N network round-trips, where the slowest
  source (a Cloudflare/WebView fetch) sets the wait. Neither pure strategy is acceptable: *eager*
  background-refresh of everything in library + history burns network, battery, and rate limit on
  works the user never opens; *lazy* counting on open puts a spinner in front of every detail page.

  So: choose the Listing immediately from cached counts (or the MangaDex-first default when
  nothing is cached), render at once, then refresh counts in the background and update the source
  picker if a better Listing appears. Counts cache with a ~24h TTL. **First paint never blocks on
  N sources.**

  Two things make this safe rather than sloppy: it is the same shape as
  `LibraryStore.refresh(history:)`, so it introduces no new pattern; and because the user can
  switch source from the detail page, a briefly-stale auto-pick costs a tap rather than a bug.
- **Counts are not trustworthy across sources, and that risk is accepted.** Sources split
  chapters differently, host duplicate uploads, and mix languages, so a source that lists every
  chapter three times can win a route it shouldn't. Cross-source count *normalization* is
  explicitly **not** attempted: when the true total is unknowable anyway (the `RELEASING` case
  above), a naive "highest count wins" is a reasonable estimator, and the cost of being wrong is
  low **because the user can correct it in one tap** (below). Revisit only if bad routes turn out
  to be common in practice.
- **The user can switch source from the manga detail page.** This is promoted from a nice-to-have
  to a *load-bearing requirement*: it is the mitigation that makes the naive count acceptable. The
  detail page shows which Listing is being served and offers the alternatives, so a stale
  auto-pick costs a tap rather than a bug report.
- **Source reliability should be learned from those switches.** When a user switches away from
  source A to source B for a Work, that is direct evidence B was more current. Aggregated per
  source, it becomes a reliability prior feeding step 2 of the ranking. Prefer learning this
  **implicitly from switch events** over an explicit "flag this source" control: it needs no UI,
  cannot be forgotten, and every user correction improves routing for free. An explicit flag can
  come later as a secondary signal if the implicit one proves too sparse.
- **Silent non-resolution interacts with this.** A Listing that never resolved to the Work
  (ADR-0005) is invisible to routing — it cannot be ranked, so the "best" source may simply never
  be considered. Routing quality is bounded by resolution quality.
- The chosen Listing should be **visible and overridable in the UI**. An automatic choice the
  user cannot see or change is indistinguishable from a bug when it picks badly.

---

## Amendment 1 — the tiebreak is the reader's, and their override sticks (2026-08-31)

The original text above stands in full except for the tiebreak, which this replaces. Nothing about
completeness ranking changes: step 1 and step 2 are exactly as written.

### What prompted it

This ADR already said the chosen Listing "should be **visible and overridable in the UI** — an
automatic choice the user cannot see or change is indistinguishable from a bug when it picks
badly." Building that raised the question the original left open: **does an override survive the
visit?**

Transient overriding satisfies the letter of the sentence above and is cheaper. It was rejected.
A reader who deliberately switches to WeebCentral because they prefer those scans, and finds the
app back on MangaDex tomorrow because a count moved, experiences that as breakage rather than as
policy — which is the exact failure the original sentence set out to prevent.

Paperback is the reference point here, and the reason its model works is that it separates two
different statements a reader can make.

### Decision

**Two preferences, composing, both beating the built-in default and neither beating completeness.**

1. **A primary source** — "when several sources have a manga, prefer this one." It replaces
   MangaDex in step 3. MangaDex remains the default *until a reader chooses*, because a reader who
   has chosen has said something more specific than the app's built-in guess.
2. **A per-Work choice** — "for *this* manga, read it here." It beats the ranking outright, and it
   persists.

The quality/availability split from the original decision governs both. Preferring a source's
scans is not a claim that it carries chapters it does not have, so **a primary source settles ties
only** and never lifts a less complete Listing above a more complete one. A per-Work choice is
different in kind: it is the reader looking at *this* title and deciding, so it outranks the
ranking rather than tiebreaking within it.

### Consequences

- **A pin whose source is no longer registered falls back to the ranking, but is not deleted.**
  An extension can be removed and adult gating can be switched off; both are reversible. Silently
  discarding a stated preference because something was temporarily unavailable is how an app loses
  a user's settings.
- **Clearing a choice clears it** rather than pinning the ranking's current answer. A reader
  switching back is saying "stop overriding", and the two readings diverge the moment a better
  Listing appears.
- **The store holds no default.** `primarySourceId` is `nil` until chosen; the fallback to MangaDex
  lives in the router alone, because naming the same default in two places is two places to drift.
- **The learned-reliability idea in the original consequences is now cheaper to build, not
  harder.** Per-Work pins are exactly the "switch events" that section wanted to learn from, and
  they are now durable rather than lost at dismissal. Still unbuilt, still optional.

## Amendment 2 — no built-in favourite: without a primary source, install order settles ties (2026-09-27)

Amendment 1 stands except for its default. Where it and the original say "prefer MangaDex" or
"MangaDex remains the default until a reader chooses", read: **with no primary source chosen, a tie
goes to the Source installed first.** Completeness ranking, the primary source, and per-Work pins
are unchanged.

### What prompted it

ADR-0003 Amendment 6 removed every compiled-in remote Source. MangaDex is now an engine a reader
installs from a repository, and its id is minted at install (`<repository UUID>:mangadex`). The
router's default still looked for the legacy id `mangadex`, which no installed Source carries, so
the default had silently become registration order, while Settings still labelled "No preference"
as "Prefer MangaDex". The code and the label disagreed, and the label was the one that was wrong.

### Decision

**Drop the default rather than restore it.** Two ways to make the label true again were weighed:

1. **Match an installed MangaDex by its `localId`.** Rejected. A `localId` is the repository's to
   choose, so any repository could name its Source `mangadex` and inherit the app's preference. A
   default keyed on a name the app does not control is a preference for sale.
2. **No built-in favourite.** Chosen. Every Source is now the reader's own install, and the app has
   no scans of its own to vouch for. The original rationale — MangaDex's better scans and metadata —
   is still available to any reader who agrees with it: choosing MangaDex as the primary source
   restores exactly the old behaviour.

The tiebreak is now: the reader's primary source, then registration order, which for installed
Sources is install order, oldest first (`ExtensionSourceRegistrar`).

### Consequences

- **"No preference" says what it does:** Settings describes it as "The first installed source wins
  ties".
- **No migration.** Nothing stored the old default — Amendment 1 kept it out of the store on purpose
  — so there is nothing to rewrite. A reader who wants MangaDex to win ties picks it once.
- **A reinstall keeps its place.** Reinstalling reuses the record's original `installedAt`
  (`ExtensionInstaller.install`), and the registrar orders by it, so uninstalling and reinstalling a
  Source does not quietly change which one wins ties.

