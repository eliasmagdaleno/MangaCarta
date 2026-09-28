//
//  AdultContentFilter.swift
//  MangaCarta
//
//  Whether a title may appear in discovery (ADR-0022 Amendment 6). With the switch off,
//  `erotica` and `pornographic` titles are hidden from every Source. An unrated title
//  is settled by its Source's own declaration: a `mixed` Source said it carries adult
//  titles, so its unknowns are hidden; a `none` Source vouched for all of its titles.
//

import Foundation

enum AdultContentFilter {
    static let adultRatings: Set<String> = ["erotica", "pornographic"]

    static func admits(rating: String?, sourceDeclaresAdultTitles: Bool, showAdultContent: Bool) -> Bool {
        if showAdultContent { return true }
        guard let rating else { return !sourceDeclaresAdultTitles }
        return !adultRatings.contains(rating)
    }
}

/// The reader's "Show adult content" switch. The key predates the rename and is kept so
/// that turning the switch on survives the upgrade.
enum AdultContentSetting {
    static let key = "settings.showAdultSources"

    @Sendable static func current() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
