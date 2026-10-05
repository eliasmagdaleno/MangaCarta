# ADR-0027 — Read state is per Work, matched by chapter ordinal

- **Status:** Accepted (2026-10-04)
- **Related:** ADR-0001, ADR-0004, ADR-0007, ADR-0014, ADR-0021, ADR-0026
- **Issue:** [#332](https://github.com/eliasmagdaleno/MangaCarta/issues/332); also governs
  [#331](https://github.com/eliasmagdaleno/MangaCarta/issues/331)

## Context

Whether a chapter is read is stored per **Listing**: `HistoryStore` keys entries and read marks by
the Source's own manga and chapter ids, and every chapter row asks `isRead(chapterId:)`. Chapter ids
are Source-scoped, so nothing recorded on one Source matches a chapter row from another.

Until #328 this rarely showed, because reading through a switched Listing failed outright. Once the
reader follows the detail page's active Listing (a per-Work pin, a pick in the source picker, or the
ranking choosing another Source — ADR-0004), it becomes the normal path for any Work with two
Listings. Chapters 1–10 finished on Source A then show as unread on Source B, with no resume marker,
and the Library badge never falls.

The Updates surface already treats reading as Work-wide: `LibraryUpdatesPresentation` unions the
read chapter numbers of every Listing of a Work before comparing ordinals.

## Decision

**A chapter's read state belongs to the Work** (ADR-0001), the way its reading mode does
(ADR-0026). Reading chapter 7 is a fact about the title, not about whose scans showed it.

- **Matched by ordinal.** A chapter on any Listing is read when its own chapter id is read, *or* its
  `ChapterOrdinal` is read on any Listing of the same Work. A chapter whose number does not parse
  (`"?"`, a oneshot label) matches by chapter id only. Two unparseable labels are never assumed to
  be the same chapter.
- **Derived at read time; storage stays Listing-keyed.** `HistoryStore` keeps recording entries and
  marks under the Listing they happened on, as ADR-0007 keeps the Work's edges Listing-keyed. The
  Work-wide view is computed from the Work's `listings` when asked. So a Work merge unions read
  state with no migration, and a Listing never claims a chapter it did not serve.
- **The resume marker follows the ordinal too.** A mid-chapter entry on A gives B's row of the same
  ordinal its in-progress marker and its resume position, as Continue already does through
  `resumeAction`'s chapter-number fallback. The reader clamps the page to the chapter it actually
  loads, so a Source that paginates differently lands near the spot, not past the end.
- **Marking read records under the active Listing.** Every mark/unmark call site passes the one
  `Manga` the reader would open (the detail page's active Listing), so a mark never depends on which
  screen made it.
- **Marking unread clears the ordinal across the Work.** It removes entries and marks for that
  ordinal under every Listing of the Work, not only the tapped chapter id. Otherwise the chapter
  stays read through another Listing and "unread" doesn't stick.
- **No Work, no change.** A title browsed but never committed to has no Work (ADR-0007). Its read
  state is its own Listing's, exactly as before.

## Consequences

- One Work-wide read lookup serves chapter rows, the resume marker, the Library badge (#331) and the
  Updates surface. The existing union in `LibraryUpdatesPresentation` moves behind it rather than
  being copied.
- Two Sources numbering one title differently (a different split of extras, or a renumbering) will
  match the wrong chapters. Ordinals are already trusted this way for update detection (ADR-0021);
  this decision accepts the same risk for read state.
- Marking a chapter unread on B also un-reads it on A. That is the point, but it is a wider effect
  than before.
- `CLAUDE.md`'s "Read state" paragraph describes per-Listing `isRead`; it is updated when this
  ships, not before.
