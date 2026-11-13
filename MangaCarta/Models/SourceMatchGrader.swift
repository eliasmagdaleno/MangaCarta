import Foundation

enum SourceMatchGrader {
    static func grade(referenceMALID: Int?, spellings: [String], candidate: Manga,
                      matcher: MALTitleMatcher = .init()) -> AddSourceGrade {
        if let candidateMALID = candidate.malId, let referenceMALID {
            return candidateMALID == referenceMALID ? .sameEntry : .differentEntry
        }
        let score = matcher.rankedScores(
            sourceTitles: spellings,
            candidates: [(id: candidate.id, titles: [candidate.title] + (candidate.altTitles ?? []))]
        ).first?.score ?? 0
        return score >= matcher.acceptanceThreshold ? .likely : .ungraded
    }
}
