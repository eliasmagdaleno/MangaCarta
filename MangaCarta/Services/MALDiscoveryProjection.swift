import Foundation

enum MALDiscoveryReason: Equatable {
    case related(type: String, label: String)
    case recommendation
}

/// A MAL title as the detail page shows it. Only what a nested MAL node really carries — no
/// synopsis, genres or `nsfw`, which would read as "MAL says none". `resolvedListing` is the
/// existing external-id reverse resolution; nil means "not on your Sources".
struct MALDiscoveryCandidate: Identifiable, Equatable {
    var id: Int { malId }
    let malId: Int
    let title: String
    let coverURL: URL?
    let reason: MALDiscoveryReason
    let resolvedListing: Manga?
}

struct MALDetailDiscovery: Equatable {
    let related: [MALDiscoveryCandidate]
    let similar: [MALDiscoveryCandidate]
}

/// Turns one cached MAL detail into the detail page's two MAL-native rails (MAL-hub design §1–2,
/// §6). Pure: the reverse resolutions, the adult switch and Source admission are all passed in, so
/// the whole policy is testable without a network or a registry.
enum MALDiscoveryProjection {
    /// MAL `relation_type` → display label, in the Related design's semantic order (decision 4):
    /// the common "where next?" relations first. MAL publishes no chronology, so this is a reading
    /// order, not a timeline.
    private static let relations: [(type: String, label: String)] = [
        ("prequel", "Prequel"), ("sequel", "Sequel"), ("side_story", "Side story"),
        ("spin_off", "Spin-off"), ("alternative_version", "Alternative version"),
        ("alternative_setting", "Alternative setting"), ("full_story", "Full story"),
        ("summary", "Summary"), ("parent_story", "Parent story"),
        ("serialization", "Serialization"), ("other", "Other"),
    ]

    /// The fixed label for a known type; an unknown future type stays visible with a sentence-cased
    /// label (`fan_fiction` → "Fan fiction") rather than being hidden until someone maps it.
    static func relationLabel(type: String) -> String {
        if let known = relations.first(where: { $0.type == type }) { return known.label }
        return type.split(separator: "_").enumerated().map { index, word in
            index == 0 ? word.capitalized : word.lowercased()
        }.joined(separator: " ")
    }

    /// Unknown types sort after every known one.
    private static func rank(_ type: String) -> Int {
        relations.firstIndex(where: { $0.type == type }) ?? relations.count
    }

    // swiftlint:disable function_parameter_count
    // Every input is explicit so the policy is testable in isolation; a parameter struct would
    // only rename them.
    static func project(detail: MyAnimeListMangaDetail, parentMALID: Int,
                        parentListingID: String, resolutions: [Int: Manga],
                        showAdultContent: Bool, admits: (Manga) -> Bool,
                        recommendationLimit: Int) -> MALDetailDiscovery {
        let related = (detail.relatedManga ?? []).enumerated().sorted { lhs, rhs in
            // Original index breaks ties: Swift's `sort` is not guaranteed stable.
            let l = rank(lhs.element.relationType), r = rank(rhs.element.relationType)
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        var relatedSeen = Set<Int>()
        let relatedCandidates = related.compactMap { item -> MALDiscoveryCandidate? in
            let relation = item.element
            return candidate(malID: relation.node.id, title: relation.node.title,
                             picture: relation.node.mainPicture,
                             reason: .related(type: relation.relationType,
                                              label: relationLabel(type: relation.relationType)),
                             parentMALID: parentMALID, parentListingID: parentListingID,
                             resolutions: resolutions, showAdultContent: showAdultContent, admits: admits,
                             seen: &relatedSeen)
        }
        var recommendationSeen = Set<Int>()
        let recommendations = MoreLikeThisProvider.topRecommendations(
            detail.recommendations ?? [], limit: recommendationLimit)
        let similar = recommendations.compactMap { item in
            candidate(malID: item.node.id, title: item.node.title, picture: item.node.mainPicture,
                      reason: .recommendation, parentMALID: parentMALID, parentListingID: parentListingID,
                      resolutions: resolutions, showAdultContent: showAdultContent, admits: admits,
                      seen: &recommendationSeen)
        }
        return MALDetailDiscovery(related: relatedCandidates, similar: similar)
    }

    /// One rail entry, or nil when it is the parent itself, a repeat, a resolved Listing that
    /// Source admission rejects, or — with "Show adult content" off — unresolved (option B: a
    /// nested MAL node carries no adult signal, so unknown is not safe).
    private static func candidate(malID: Int, title: String,
                                  picture: MyAnimeListManga.MainPicture?, reason: MALDiscoveryReason,
                                  parentMALID: Int, parentListingID: String,
                                  resolutions: [Int: Manga], showAdultContent: Bool,
                                  admits: (Manga) -> Bool,
                                  seen: inout Set<Int>) -> MALDiscoveryCandidate? {
        guard malID != parentMALID, seen.insert(malID).inserted else { return nil }
        let resolved = resolutions[malID]
        if let resolved {
            guard resolved.id != parentListingID, admits(resolved) else { return nil }
        } else if !showAdultContent {
            return nil
        }
        let url = (picture?.large ?? picture?.medium).flatMap(URL.init(string:))
        return MALDiscoveryCandidate(malId: malID, title: title, coverURL: url, reason: reason,
                                     resolvedListing: resolved)
    }
    // swiftlint:enable function_parameter_count
}
