//
//  MALTitleMatcher.swift
//  MangaCarta
//
//  Pure title-matching core for cross-source entity resolution: given a source manga's
//  title and MAL search candidates (each with its full title set), decide which MAL id
//  it is — or that there's no confident match. No network, no persistence; fully unit-
//  tested. Precision-biased: a high threshold plus an ambiguity guard, and any doubt
//  resolves to `.noMatch` rather than a wrong id.
//

import Foundation

/// A MAL search result reduced to what matching needs: its id and every title it goes by.
struct MALCandidate: Equatable {
    let malId: Int
    let titles: [String]
}

enum MALMatchDecision: Equatable {
    case matched(malId: Int)
    case noMatch
}

struct MALTitleMatcher {
    /// Minimum normalized similarity (0...1) required to accept a fuzzy match.
    var acceptanceThreshold: Double = 0.90
    /// The best candidate must beat the runner-up by at least this margin, else the
    /// match is treated as ambiguous and rejected.
    var ambiguityMargin: Double = 0.05

    /// Tokens dropped during normalization — structural noise, not identity.
    private static let noiseTokens: Set<String> = ["manga", "season", "part", "cour"]

    /// Lowercase, strip diacritics, replace every non-alphanumeric with a space, drop
    /// noise tokens, and collapse/trim whitespace.
    static func normalize(_ title: String) -> String {
        let folded = title.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let spacedScalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(spacedScalars)
            .split(separator: " ")
            .map(String.init)
            .filter { !noiseTokens.contains($0) }
            .joined(separator: " ")
    }

    /// Normalized Levenshtein similarity in [0, 1]; 1.0 iff the strings are equal.
    /// Callers pass already-normalized strings.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let distance = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        return 1.0 - Double(distance) / Double(maxLen)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,        // deletion
                                 current[j - 1] + 1,     // insertion
                                 previous[j - 1] + cost) // substitution
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// The id of the best-matching candidate for a **set** of source titles — a Work's
    /// `knownTitles` — or nil if none clears the acceptance threshold and the ambiguity
    /// guard. Generic over the id type so it serves both MAL-id matching (forward) and
    /// MangaDex-id matching (reverse). Precision-biased: any doubt resolves to nil.
    ///
    /// Each candidate scores as the maximum similarity over the **title cross-product**,
    /// which is symmetric with what this already did on the candidate side. That produces
    /// **one** ranked list and therefore one ambiguity guard.
    ///
    /// This is deliberately not "run the single-title matcher per title and take the
    /// best": a maximum across N independent ranked lists has no runner-up to compare
    /// against, so it would raise recall and the false-match rate together. Running a
    /// precision-biased matcher repeatedly does not preserve precision (ADR-0008).
    func bestMatch<ID>(sourceTitles: [String],
                       candidates: [(id: ID, titles: [String])]) -> ID? {
        let scored = rankedScores(sourceTitles: sourceTitles, candidates: candidates)
        guard !scored.isEmpty else { return nil }

        guard let best = scored.first, best.score >= acceptanceThreshold else { return nil }
        // Ambiguity guard rejects even exact matches (1.0) if the runner-up is too close.
        if scored.count >= 2, best.score - scored[1].score < ambiguityMargin {
            return nil   // too close to call — precision over recall
        }
        return best.id
    }

    /// Scores every candidate using the same normalized title cross-product as `bestMatch`.
    /// Ties retain input order so callers can present deterministic choices.
    func rankedScores<ID>(sourceTitles: [String],
                          candidates: [(id: ID, titles: [String])]) -> [(id: ID, score: Double)] {
        let normSources = sourceTitles.map(Self.normalize).filter { !$0.isEmpty }
        guard !normSources.isEmpty else { return [] }
        let raw: [(Int, ID, Double)] = candidates.enumerated().map { index, candidate in
            let normCandidates = candidate.titles.map(Self.normalize).filter { !$0.isEmpty }
            var best = 0.0
            for source in normSources {
                for title in normCandidates { best = max(best, Self.similarity(source, title)) }
            }
            return (index, candidate.id, best)
        }
        return raw.sorted { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0 < rhs.0 : lhs.2 > rhs.2
        }.map { ($0.1, $0.2) }
    }

    func rankedScores<ID>(sourceTitle: String,
                          candidates: [(id: ID, titles: [String])]) -> [(id: ID, score: Double)] {
        rankedScores(sourceTitles: [sourceTitle], candidates: candidates)
    }

    /// Single-title matching, for callers that have one Listing rather than a Work.
    /// Delegates, so there is one scoring path and the threshold has one definition.
    func bestMatch<ID>(sourceTitle: String,
                       candidates: [(id: ID, titles: [String])]) -> ID? {
        bestMatch(sourceTitles: [sourceTitle], candidates: candidates)
    }

    /// Best MAL match for `sourceTitle` among `candidates`, or `.noMatch`. Delegates to
    /// the generic `bestMatch`; kept for callers that speak the `MALCandidate`/decision API.
    func decide(sourceTitle: String, candidates: [MALCandidate]) -> MALMatchDecision {
        let match = bestMatch(sourceTitle: sourceTitle,
                              candidates: candidates.map { (id: $0.malId, titles: $0.titles) })
        return match.map { .matched(malId: $0) } ?? .noMatch
    }
}
