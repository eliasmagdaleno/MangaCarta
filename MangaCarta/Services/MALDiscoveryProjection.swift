import Foundation

// The projection's explicit arguments keep its policy independently testable.
// swiftlint:disable function_parameter_count cyclomatic_complexity line_length

enum MALDiscoveryReason: Equatable {
    case related(type: String, label: String)
    case recommendation
}

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

enum MALDiscoveryProjection {
    private static let relationOrder = ["prequel", "sequel", "side_story", "spin_off", "alternative_version", "alternative_setting", "full_story", "summary", "parent_story", "serialization", "other"]

    static func relationLabel(type: String) -> String {
        switch type {
        case "prequel": return "Prequel"
        case "sequel": return "Sequel"
        case "side_story": return "Side story"
        case "spin_off": return "Spin-off"
        case "alternative_version": return "Alternative version"
        case "alternative_setting": return "Alternative setting"
        case "full_story": return "Full story"
        case "summary": return "Summary"
        case "parent_story": return "Parent story"
        case "serialization": return "Serialization"
        case "other": return "Other"
        default:
            return type.split(separator: "_").enumerated().map { index, word in
                index == 0 ? word.capitalized : word.lowercased()
            }.joined(separator: " ")
        }
    }

    static func project(detail: MyAnimeListMangaDetail, parentMALID: Int,
                        parentListingID: String, resolutions: [Int: Manga],
                        showAdultContent: Bool, admits: (Manga) -> Bool,
                        recommendationLimit: Int) -> MALDetailDiscovery {
        let related = (detail.relatedManga ?? []).enumerated().sorted { lhs, rhs in
            let l = relationOrder.firstIndex(of: lhs.element.relationType) ?? relationOrder.count
            let r = relationOrder.firstIndex(of: rhs.element.relationType) ?? relationOrder.count
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        var relatedSeen = Set<Int>()
        let relatedCandidates = related.compactMap { item -> MALDiscoveryCandidate? in
            let relation = item.element
            return candidate(malID: relation.node.id, title: relation.node.title,
                             picture: relation.node.mainPicture, reason: .related(type: relation.relationType, label: relationLabel(type: relation.relationType)),
                             parentMALID: parentMALID, parentListingID: parentListingID,
                             resolutions: resolutions, showAdultContent: showAdultContent, admits: admits,
                             seen: &relatedSeen)
        }
        var recommendationSeen = Set<Int>()
        let recommendations = MoreLikeThisProvider.topRecommendations(detail.recommendations ?? [], limit: recommendationLimit)
        let similar = recommendations.compactMap { item in
            candidate(malID: item.node.id, title: item.node.title, picture: item.node.mainPicture,
                      reason: .recommendation, parentMALID: parentMALID, parentListingID: parentListingID,
                      resolutions: resolutions, showAdultContent: showAdultContent, admits: admits,
                      seen: &recommendationSeen)
        }
        return MALDetailDiscovery(related: relatedCandidates, similar: similar)
    }

    private static func candidate(malID: Int, title: String, picture: MyAnimeListManga.MainPicture?, reason: MALDiscoveryReason,
                                  parentMALID: Int, parentListingID: String, resolutions: [Int: Manga],
                                  showAdultContent: Bool, admits: (Manga) -> Bool, seen: inout Set<Int>) -> MALDiscoveryCandidate? {
        guard malID != parentMALID, seen.insert(malID).inserted else { return nil }
        let resolved = resolutions[malID]
        if let resolved {
            guard resolved.id != parentListingID, admits(resolved) else { return nil }
        } else if !showAdultContent {
            return nil
        }
        let url = (picture?.large ?? picture?.medium).flatMap(URL.init(string:))
        return MALDiscoveryCandidate(malId: malID, title: title, coverURL: url, reason: reason, resolvedListing: resolved)
    }
}

// swiftlint:enable function_parameter_count cyclomatic_complexity line_length
