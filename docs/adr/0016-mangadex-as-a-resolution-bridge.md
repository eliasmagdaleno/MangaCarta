# ADR-0016 — MangaDex as a resolution bridge

- **Status:** **Rejected (2026-08-10)** on measurement, after being built. Superseded by
  [ADR-0017](0017-excluding-novels-from-mal-resolution-candidates.md), which is the fix the
  measurement pointed at. Kept in full because the *reasoning* below is sound and the
  *premise* is not — and that gap is the whole lesson.
  **Still Rejected for MangaDex-sourced titles.** The reopening clause below fired on 2026-08-11 for
  a source that publishes no external ids, and the implementation was revived — scoped, and with
  Decision 6 dropped — by
  [ADR-0019](0019-bridging-resolution-for-sources-that-publish-no-external-ids.md). Read that ADR for
  what ships; read this one for why it did not ship here
- **Amends:** nothing, in the end. It *would* have amended ADR-0008's "resolution always goes
  through MyAnimeList" single-route rule; rejected, that rule stands untouched.
- **Related:** ADR-0001 (Work vs Listing — the boundary Decision 4 refuses to cross),
  ADR-0009 (`knownTitles` monotonicity, which Decision 5 feeds and Attempt memory depends on),
  ADR-0011 (the pool cache that persists `Manga` whole — Decision 1's compatibility constraint),
  ADR-0015 (the notice this is meant to make rarer, and whose "reported, not inferred" standard
  Hazard 3 revises), ADR-0005 (manual link — still parked, and Decision 4 keeps it that way)

## Rejection (2026-08-10) — the premise was wrong, and a cheaper fix dominates

Decision 8 said the acceptance evidence was a before/after refusal count, not the test suite. It
was run, and it says **do not ship this**.

Twelve scraping-style titles, put through a harness replicating `MALTitleMatcher` exactly (same
normalization, Levenshtein, 0.90 threshold, 0.05 margin) against the live MAL and MangaDex APIs:

| Configuration | Refused | Extra requests per refusal |
|---|---|---|
| MAL only (the state this ADR set out to fix) | **6 / 12** | — |
| MAL + this bridge, as built | **3 / 12** | 2–5 |
| **MAL with novels filtered out** (ADR-0017) | **2 / 12** | **0** |

**The bridge's marginal contribution on top of the novel filter is zero** — both survivors stay
refused with it running.

### Why: the Context's diagnosis was wrong

This ADR argued the failures were a *reach* problem — MAL's search coping badly with romaji /
English / native spellings. **Not one of the six refusals was a threshold miss. All six were
ambiguity-guard rejections**, and the tie was usually one thing:

```
Solo Leveling    121496 manhwa  vs  119184 novel   ← same title
ORV              132214 manhwa  vs  143441 novel   ← same title
Mount Hua        146878 manhwa  vs  161366 novel   ← same title
Wind Breaker     103237 manhwa  vs  133081 manga   ← two real comics
```

MAL files novels under `/manga`, and an adaptation carries its source novel's title. The matcher
saw two candidates at identical similarity and did exactly what it was designed to do. `MALTitleMatcher`
was never the weak link; it was correctly reporting a collision in MAL's catalog.

The bridge did recover three of these, and not by luck — MangaDex indexes comics, so the novel twin
is absent from its results and the tie dissolves. But that is a roundabout way to exclude novels,
and `media_type` excludes them directly, for free, in the response the app already fetches. The
filter also recovers a case the bridge could not (`Hwasan Gwihwan` → 146878, verified correct).
`Wind Breaker` stays refused under every configuration, correctly: two genuinely different comics
share that title, and that is the doubt the guard exists for.

Every id recovered in every configuration was verified to be the right series. No false matches.

### What this cost, and what it bought

The bridge was designed, grilled, written as eight decisions, corrected once on measured data
(the Amendment below), then implemented with eleven tests and two mutation checks — and the cheaper
fix never came up, because the failure was diagnosed from the *shape of the code* rather than from
one live response body. **A refusal has a reason, and the reason was one API call away the whole
time.** The Amendment below is the same error caught earlier and cheaper; this section is that error
caught late and expensive.

What survives: the measurement method, ADR-0017, and the fact that Decision 8 was the thing that
worked. The implementation is on the unmerged branch `mangadex-alt-titles`
(`70bae88`, `b57be7c`, `19a6ecd`) if it is ever wanted.

### The caveat that could reopen this

Twelve titles, hand-picked, **skewed toward Korean webtoons** — exactly where novel adaptations are
common, and so exactly where the novel collision would dominate. This sample cannot rule out that a
library heavy on Japanese scanlations suffers real reach failures the bridge would fix and the filter
would not. **If ADR-0017 ships and refusals persist with `.unmatched` outcomes whose top MAL
candidate scored *below* 0.90 rather than tying**, that is a reach failure, and this ADR is the
thing to reopen.

## Amendment (2026-09-22) — the bridge exists only when an installed Source publishes external ids

[ADR-0003 Amendment 6](0003-extension-substrate.md#amendment-6--the-app-store-build-ships-no-built-in-and-no-bundled-source-2026-09-22)
removes the built-in MangaDex Source. Everything this ADR and ADR-0019 describe assumed MangaDex was
always registered: its `links.mal` gave MangaDex-sourced Works a MAL id directly, and ADR-0019's
bridge looks titles up in MangaDex to borrow one. **From this amendment on, that route is available
only when the reader has installed a Source that publishes external ids.** The extension contract is
gaining an external-ids field (e.g. `malId`) for this, so an installed MangaDex engine can supply
what the compiled Source did.

With no such Source installed, MAL/AniList resolution falls back to MAL's own search — the weakest
of the searches, per this ADR's Context — and **some Works stay unresolved** that the bridge would
have resolved. More Like This, the metadata upgrade bridge and the MAL-dependent parts of For You
return less, or nothing, for those Works. **The owner accepted this on 2026-09-22** as the cost of
shipping no content Source.

Nothing above is re-decided: this ADR stays Rejected for MangaDex-sourced titles, ADR-0019 stays the
record of what ships, and its thresholds and gate are unchanged. What changed is only whether the
bridge's data source is present.

## Amendment (2026-08-09) — Decision 3's mechanism was wrong

The first draft of Decision 3 said: MangaDex's near-duplicate entries (colour re-releases, regional
editions) score within the ambiguity margin of each other, **but usually share one `malId`**, so
collapsing candidates by `malId` recovers a false rejection without weakening the guard.

**The shared-`malId` premise was inferred, not checked, and it is false.** Queried against the live
API for *Solo Leveling*, *One Punch Man* and *Tower of God*, the pattern is the same every time: the
canonical entry carries `links.mal` and the variants — *Fan Colored*, *Webcomic*, *Book Version*,
*Doujinshi*, *Pre-serialization* — carry **no `mal` link at all**. Collapsing by `malId` would have
grouped every unrelated id-less entry into one bucket keyed on nil.

The hazard it was aimed at is real, and worse than the draft described. Running this repo's own
normalization and cross-product scoring over a live `title=Tower of God` search:

```
1.000  mal=122663   Sinui Tap                      ← correct
1.000  mal=None     Tower of God (Book Version)
0.500  mal=181485   Urek Mazino
0.316  mal=82743    Genshi Otome to Kami no Tou
0.190  mal=105067   The Female God of Babel: KAMISAMA Club in Tower of Babel
```

Both leaders sit at **exactly 1.000** — the Korean series lists "Tower of God" among its alt titles,
and so does the Book Version. Margin zero, ambiguity guard fires, **the bridge returns nothing on the
most obvious input it will ever receive.** The corrected mechanism is in Decision 3 below.

This is the same failure ADR-0015 recorded six times: a claim about current behaviour written from
plausibility rather than from the response body. It was caught here only because the ADR was
grilled before implementation, which is the practice that section argued for.

## Context

A Work gets tags from one of two routes (ADR-0007): a provider snapshot, or a provisional snapshot
built from Listing tags. A Work with neither is not a **tagged Work**, does not count toward the
recommender's cold-start gate, and contributes nothing to the tag vector. ADR-0015 gave that state a
voice — a notice when *nothing* is taggable, and per-title notices for individual refusals.

Both notices are apologies. This ADR is about the failure underneath them.

**There is exactly one way a Work without a free external id acquires one.** `MALEntityResolver`
searches MyAnimeList by title — once per known title, capped at three, unioned into one candidate
pool — and hands the pool to `MALTitleMatcher`, which accepts at 0.90 similarity with a 0.05
ambiguity margin. MangaDex-sourced Works never reach this path: `attributes.links.mal` gives them a
`malId` for free. **So every silently-unresolved Work in the store failed the same MAL title
search** — which is the weakest search of the three catalogs the app already talks to, matching
largely on primary title and coping badly with romaji / English / native spelling differences.

A WeebCentral Work therefore fails on a single spelling and, once `.unmatched(knownTitlesCount)` is
recorded, stays failed until its title count grows — which nothing makes happen.

Meanwhile MangaDex already answers the question this needs. Its search is materially better, it
returns an **`altTitles` array** — every spelling a series goes by — and any entry it returns carries
`links.mal`. The app has `MangaDexAPI.searchManga(title:)` today and **does not decode `altTitles`
at all**: `MangaAttributes` reads only `title`, and `toManga` collapses that to one English string.

The premise of this ADR is that the recommender's refusals are mostly a *reach* problem, not a
catalog-coverage problem, and that the reach is one already-present API call away.

### What is not known

**The split between "MAL's search was too weak" and "this title is genuinely not on MAL" has never
been measured.** The code distinguishes them — `.unmatched` versus `.absentFromProvider` — but
nothing reports the ratio, and the only library available is seeded test data, so field numbers are
not coming. A bridge helps the first case and cannot help the second.

This ADR proceeds anyway, and says so plainly rather than implying evidence it does not have. The
justification is cost, not confidence: Decision 2 is a fallback on an already-failing path, so its
worst case is one wasted request on a Work that is refused today either way. Measuring first would
cost the same library-seeding work that testing it costs, and produce a study instead of a fix.
**Decision 6 makes the measurement a by-product of shipping it.**

## Decisions

### 1. Decode `altTitles`, and carry them on `Manga`

`MangaAttributes` gains `altTitles: [[String: String]]?`; `toManga` flattens the locale maps into a
title list on `Manga`.

Without this the bridge is MAL's search with a different hostname — it would match one spelling
against one spelling, which is the exact weakness being routed around. The multi-spelling data *is*
the bridge's edge, and nothing else in this ADR is worth building without it.

`Manga` is `Codable` and ADR-0011's ranked-pool cache persists it whole, so the new field must decode
against cache files written before it existed: **optional, defaulted, never required.** An
undecodable cache entry is already treated as a miss, so the failure mode is a re-fetch rather than a
crash — but a re-fetch of the whole pool is a real cost and the default is what avoids paying it.

Shipped **as its own change**, ahead of the bridge. It is a schema change to a persisted type with no
behavioural payload; if the compatibility claim above is wrong, that has to fail in isolation.

### 2. The bridge is a fallback inside `MALEntityResolver`, behind an injected closure

MangaDex is consulted **only after** the MAL search has produced no confident match.

*Inside the resolver, not beside it.* The resolver is already the single answer to "what is this
Work's MAL id". A separate `MangaDexBridge` type would be a second place that decides what a
confident match is, and those two definitions drift the first time either is tuned — the same
argument ADR-0015 made for returning the refusal reason from the function that already knows it.

*Behind a closure*, in the shape `Search` already uses. `MyAnimeListAPI` is static onto
`URLSession.shared` and the existing seam exists because of it; the bridge takes the same treatment
rather than dragging `SourceRegistry` into a resolver that has no other reason to know about sources.

*After, not before.* Ordering it first would spend an extra request on every title MAL matches
fine. Ordering it second spends one only on titles that are refused today — a request against a
refusal is a trade up, a request against a success is waste. The free `links.mal` fast path means
MangaDex-sourced Works reach neither search.

**Rate limiting needs nothing new.** `MangaDexAPI.request` retries a 429 once honouring
`Retry-After` and then throws `.rateLimited`; `MetadataUpgradeQueue` excludes 429 from permanent
failures. A rate-limited bridge attempt therefore records nothing and is reconsidered next pass —
already the correct behaviour, by two mechanisms that were built independently.

### 3. Same thresholds, and **partition the pool by whether an entry carries a `malId`**

The bridge reuses `MALTitleMatcher` unchanged at 0.90 / 0.05. **Candidates are split into two pools —
those with a `links.mal` id and those without — and the id-bearing pool is matched first.** Each pool
gets its own ranking and its own ambiguity guard.

*Same thresholds.* The bridge is a **two-hop** match — fuzzy title → MangaDex entry, then trust that
entry's `malId` — so it has two chances to land on the wrong series, and a wrong id yields
confidently wrong tags. That is a worse failure than the absent tags it replaces, and it is invisible
to the reader, who has no way to know the recommender is reasoning about a different manga. Loosening
the threshold to buy recall would trade a visible, honest failure for a silent, dishonest one. The
recall comes from Decision 1's better evidence instead. A *stricter* bridge threshold was also
rejected: it would put two definitions of "confident" in the codebase for no measured reason.

*Partition, don't collapse.* MangaDex carries variant entries for the same series — colour
re-releases, webcomic originals, book editions — whose alt-title lists contain the canonical English
title verbatim, so they tie the real entry at 1.000 and trip the ambiguity guard (see the Amendment
above for the measured case). **These variants carry no `mal` link**, which is what makes the
partition both possible and principled: an entry with no id cannot answer the question being asked,
so it does not belong in the ranking that answers it. Removing it is not loosening the guard — it is
declining to count a non-answer as a competing answer. The guard still fires on genuine two-*series*
ambiguity, which is the doubt it exists for.

The id-less pool is not discarded: it is exactly the input Decision 6 needs. So the partition serves
both decisions rather than trading one against the other, and it is the one place this ADR touches
matching behaviour.

**Ordering matters and is not an optimization.** Matching the id-less pool first would let a variant
win outright — a Work whose source spelling happens to match *Tower of God (Book Version)* better than
the canonical entry would route into Decision 6's re-search when a correct id was sitting in the other
pool. Id-bearing first, always.

### 4. A bridge hit records `externalIds.mal` — and **not** a Listing

A confident bridge match is literally the statement *"this Work is also MangaDex manga X"*, and
`Work.listings` is right there. **It is not written.**

The id is what was needed and what the match verified. A Listing claim is a larger, permanent
assertion: it affects merging, it affects reverse resolution, and it is the substance of ADR-0005's
manual-link override — deliberately parked, on the grounds that its build is blocked on a report that
has not arrived. Writing Listings on the strength of a fuzzy match would unpark that decision as a
side effect of an unrelated one, which is the wrong way for a parked ADR to come back.

Recording the id already buys the compounding benefit: `malId(for work:)`'s first line returns a
known id for free forever after, so the bridge costs at most one search per Work per lifetime.

**This is the decision most likely to read as an oversight later.** A future reader will find a
bridge that identifies a MangaDex manga and discards the link, and will be tempted to "fix" it. The
discard is the decision.

### 5. Harvest the matched entry's titles onto the Work

Every spelling from the matched MangaDex entry goes through `Work.noteTitle` — **including when the
bridge finds a match but produces no id** (Decision 6).

`knownTitles` is matcher fuel and ADR-0009 established it as monotonic, which is exactly what
Attempt memory's `.unmatched(knownTitlesCount)` fingerprint watches: a grown title count reopens a
Work the queue had given up on, with no new mechanism. So harvesting does not merely help the current
attempt — **it makes the refusal self-healing**, and it improves reverse resolution and every later
match too. It is the cheapest decision here and the only one that compounds.

### 6. A match with no `malId` re-searches MAL once, then gives up honestly

MangaDex's `links.mal` is often absent — Decision 3's id-less pool — so the bridge can identify the
right series and still have no id. **Reached only when the id-bearing pool produced no match.** In
that case the harvested titles (Decision 5) are used for **one further round** of MAL searches,
bounded by the same `titleSearchLimit` as the primary round and restricted to spellings the Work did
not already know — the ones that already failed are not worth re-asking.

This is the case the bridge is best placed to fix: MAL rejected one spelling, and five more are now
in hand — the missing evidence, not a second guess at the same question. One extra request in an
already-failing case.

If that misses too, the resolver returns `nil` and the miss is recorded as `.unmatched` — honestly,
because the searches did happen and did produce candidates. **A transient failure anywhere in the
bridge throws and records nothing**, preserving ADR-0008's rule that a network blip must never be
remembered as an answer about a Work.

### 7. Both entry points get the bridge; Work-level first

`malId(for work:)` (feeding the upgrade queue → tags → the For You rail) is bridged first, because it
is where the refusals this ADR targets are produced. `malId(for manga:)` (feeding "More Like This")
follows immediately.

Not "Work-level only". The 2026-08-08 device check established that these two resolvers are
independent and **can disagree** — the per-title notice had to be gated on the rail being empty *and*
the Work being refused, precisely because a Work-level refusal does not imply a Listing-level one.
Bridging one and not the other would widen a gap that has already cost a session, in exchange for
nothing.

### 8. Verification is a before/after refusal count, not a test suite

Unit tests cover the resolver's branches: bridge hit, bridge miss, matched-without-`malId` → MAL
re-search, transient throw records nothing, and the pool partition — **including a regression test
built from the measured *Tower of God* candidate set above**, which fails on the unpartitioned matcher
and passes on the partitioned one. That case is the reason Decision 3 exists and is the one test here
that encodes a real API response rather than an invented one.

**Those tests cannot establish this ADR's premise.** With injected closures they prove the code does
what it was written to do, and say nothing about whether real MangaDex search finds real WeebCentral
titles. So the acceptance evidence is a **device check that counts refusals before and after against
one identical seeded library** — WeebCentral-sourced history using real titles that MAL currently
fails. That number moving is the whole claim.

Two traps from prior sessions apply and are recorded here so the check is not re-derived:
`EntityResolutionStore` is keyed `sourceId:mangaId` and **keeps hits forever**, so seeds must not
reuse `mangaId`s between runs; and the drain re-creates `upgrade-attempts.json` on its own, so
deleting it is not a negative control.

## Hazards

1. **The unmeasured split stands.** If most refusals are `.absentFromProvider` rather than
   `.unmatched`, this ADR buys little. Decision 8's count is what will say so, and a null result is a
   real outcome to accept rather than to tune thresholds until it goes away.
2. **Two-hop false matches are silent.** Decision 3 mitigates by refusing to loosen, but a wrong
   `malId` still produces confidently wrong tags with no surface that would reveal it. The app has no
   way to notice this and neither does its owner.
3. **ADR-0015's "reported, not inferred" standard cannot be met here.** That standard defers the
   mixed-library hazard until a reader reports bad recommendations. The only library is seeded test
   data and the app is not read in earnest, so **that report will never arrive** — the gate is not
   "not yet", it is "never". The standard was sound when written and is inapplicable to a project with
   no users. Work under it is now judged on cost and on whether the failure is silent, which is how
   this ADR was judged.
4. **Decision 4 will look like a bug.** Named in Decision 4 itself; repeated here because the
   Hazards section is where a sceptical reader looks first.

## Revisit triggers

- **The refusal count barely moves** under Decision 8 → the premise is wrong; report the
  `.unmatched` / `.absentFromProvider` split before building anything further on resolution reach.
- **A wrong recommendation is traced to a bridged id** → Hazard 2 has fired; revisit Decision 3's
  "same thresholds", with the two-hop path as the argument for a stricter one.
- **ADR-0005 comes back** (a manual-link surface is built) → Decision 4's boundary is up for
  reconsideration, because a manual link is the authoritative Listing claim the bridge declines to
  make, and the two would then sit side by side.
- **A third catalog gains a search route** → the fallback chain stops being a special case and wants
  a named ordering rather than an `if` in the resolver.
