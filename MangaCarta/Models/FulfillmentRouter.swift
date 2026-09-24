//
//  FulfillmentRouter.swift
//  MangaCarta
//
//  ADR-0004 — once a Work has several Listings (ADR-0001), opening it must choose
//  one. Rank by English chapter completeness; the reader's primary source breaks
//  ties, and MangaDex is that default until they choose one.
//
//  Pure and synchronous on purpose: the counts it ranks on are fetched and cached
//  elsewhere, so first paint never blocks on N sources.
//

import Foundation

/// One Listing considered for fulfillment, with everything the ranking needs.
struct ListingCandidate: Equatable {
    let key: ListingKey
    /// Distinct English chapters this Listing is known to have. **`nil` means
    /// unknown, never zero** (ADR-0007) — an uncached Listing has not been counted,
    /// which is not the same as a Listing with nothing on it.
    let chapterCount: Int?
    /// Position in `SourceRegistry`'s registration order, the ADR's last tiebreak.
    let registrationIndex: Int
}

enum FulfillmentRouter {

    /// Ranks a Work's Listings best-first.
    /// - Parameter preferredSourceId: the reader's chosen primary source. `nil`
    ///   means they have not chosen one, and MangaDex's built-in preference stands.
    static func rank(_ candidates: [ListingCandidate],
                     referenceTotal: Int?,
                     preferredSourceId: String? = nil) -> [ListingCandidate] {
        candidates.sorted { lhs, rhs in
            let left = evidenceRank(lhs, referenceTotal: referenceTotal)
            let right = evidenceRank(rhs, referenceTotal: referenceTotal)
            if left != right { return left > right }
            return preferenceRank(lhs, preferredSourceId) < preferenceRank(rhs, preferredSourceId)
        }
    }

    /// Orders candidates by how much is known about them, best first. Three tiers,
    /// because a count and the absence of one are different kinds of fact:
    ///
    /// 1. **Counted, non-empty** — real evidence, ordered by the count itself.
    /// 2. **Uncounted** — no evidence either way. Ranked on the preference order
    ///    alone, which is what makes the cold-start pick MangaDex.
    /// 3. **Counted and empty** — the only tier we have positive evidence *against*.
    ///
    /// Tier 2 sitting above tier 3 is ADR-0007's "a missing count means unknown,
    /// never zero" made operational: an uncounted Listing must not be lumped in
    /// with one we looked at and found nothing on.
    ///
    /// Tier 2 sitting *below* tier 1 is the optimistic-render trade ADR-0004 makes
    /// explicit — we pick from the evidence we have, reconcile in the background,
    /// and a briefly-stale pick costs the user a tap rather than a bug.
    ///
    /// A known `referenceTotal` caps the count rather than dividing by it: at 100%
    /// a Listing has every chapter there is, and anything beyond the total is
    /// padding (duplicate uploads, split parts, extras) rather than more manga.
    /// Capping makes every complete Listing tie, which hands the choice to the
    /// quality preference — the ADR's short-circuit, with no ratios to round.
    ///
    /// The total is only ever known for `FINISHED` series; ongoing ones report
    /// `nil`, and there the sources define the frontier all on their own.
    private static func evidenceRank(_ candidate: ListingCandidate,
                                     referenceTotal: Int?) -> (Int, Int) {
        switch candidate.chapterCount {
        case .none: return (1, 0)
        case .some(0): return (0, 0)
        case .some(let count):
            guard let referenceTotal else { return (2, count) }
            return (2, min(count, referenceTotal))
        }
    }

    /// The ADR's step 1: how many *distinct* chapters a Listing actually carries.
    ///
    /// Deduplication is `ChapterOrdinal`'s, not a second implementation — several
    /// scanlation groups upload the same chapter, and sources relabel `"07"` as
    /// `"7"`; only the numeric value is identity, so both collapse to one chapter.
    /// Counting rows would hand every comparison to the most duplicated source.
    ///
    /// Unnumbered entries ("Oneshot", "Extra") are deliberately excluded. They are
    /// readable chapters, but they are not *comparable* ones: one site's "Oneshot"
    /// is another's "Chapter 0", and counting free-text labels would make
    /// completeness depend on labelling style rather than on availability.
    static func distinctChapterCount(_ chapters: [Chapter]) -> Int {
        var frontier = ChapterFrontier()
        frontier.seed(chapters.map(\.number))
        return frontier.known.count
    }

    /// The tiebreak at equal completeness: the reader's primary source, else
    /// MangaDex, then registration order.
    ///
    /// This is a **quality** preference (better scans, better metadata, no ads),
    /// not an availability one — which is why it never outranks a source that
    /// simply has more chapters. That holds for a reader's own choice too: picking
    /// a primary source says which scans they prefer, not that it carries chapters
    /// it does not have.
    ///
    /// MangaDex is the default rather than the rule. A reader who has chosen has
    /// said something more specific than the app's built-in guess.
    private static func preferenceRank(_ candidate: ListingCandidate,
                                       _ preferredSourceId: String?) -> (Int, Int) {
        let preferred = preferredSourceId ?? LegacySourceID.unattributed
        return (candidate.key.sourceId == preferred ? 0 : 1,
                candidate.registrationIndex)
    }
}
