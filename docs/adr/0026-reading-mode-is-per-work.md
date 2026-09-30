# ADR-0026 — Reading mode is per Work, and the reader sets it

- **Status:** Accepted (2026-09-30)
- **Related:** ADR-0001, ADR-0014, ADR-0025
- **Issue:** [#290](https://github.com/eliasmagdaleno/MangaCarta/issues/290)
- **Design:** [`docs/superpowers/specs/2026-09-30-per-title-reading-mode-design.md`](../superpowers/specs/2026-09-30-per-title-reading-mode-design.md)

## Context

Reading mode (left to right, right to left, webtoon) was one app-wide setting, changed only from
the reader's mode menu. A reader with a left-to-right comic beside right-to-left manga had to flip
it on every switch, and flipping it for one title flipped it for all of them.

## Decision

**A reading mode belongs to the Work** (ADR-0001), not to a Listing. The mode is a fact about the
title, so it follows the reader across Sources — a pin, or a change in the ranking, does not lose
it. Two Sources shipping one title in different formats is real but rare, and keying by Listing
would make the mode seem to vanish on every switch.

**Two tiers, in this order:** the Work's own mode, else the global default.

- **Every change in the reader is per title.** Picking a mode in the reader's menu gives the open
  Work its own mode, even when it equals the default: choosing it on purpose is what pins it. The
  menu's **Default** entry clears it.
- **The global default moves to Settings** (a Reader section). Changing it moves only Works with no
  mode of their own. It keeps the existing `readingMode` key, so no reader's mode changes on update.
- **A local import's ComicInfo seeds the Work's own mode** at import, only if the Work has none:
  `Manga=YesAndRightToLeft` → right to left, `Manga=No` → left to right, `Yes` / `Unknown` /
  absent → nothing. The seeded value is indistinguishable from one the reader chose.
- **Merges carry the mode** to the surviving Work; when both had one, the survivor's wins.

## Consequences

- A reader who used the reader's menu to change the mode *everywhere* now does that in Settings.
- There is no "suggested" tier: nothing records that a mode came from ComicInfo.
- **Source-supplied defaults are not part of this decision.** No Source declares one, and adding it
  is a Host API change. If one lands, it is a third tier between the Work's own mode and the
  global default, and is recorded as an amendment here.
- Files imported before ComicInfo's `Manga` field was parsed are not backfilled.
