//
//  MangaModels.swift
//  MangaCarta
//
//  Created by Elias Magdaleno on 10/8/25.
//

import Foundation

// MARK: - Public Types (used by Views / ViewModels)

// A lightweight representation of a manga item that ALWAYS carries a cover URL if available.
// `Codable`/`Equatable` are declared here rather than in an extension because Swift only
// synthesizes them in the file that declares the type. ADR-0011's pool cache persists
// resolved `Manga` values whole — a lossy mirror could not produce an openable candidate —
// and an undecodable cache file is treated as a miss, which is what protects that if this
// struct ever gains a field.
struct Manga: Identifiable, Codable, Equatable {    // Conform to Identifiable so SwiftUI lists work nicely.
    let id: String                                  // The source's ID for the manga (unique only WITHIN a source).
    let sourceId: String                            // Which source this manga came from (e.g. "mangadex").
    let title: String                               // Display title (prefer English; fallback to first available).
    let description: String                         // Short description (English if available).
    let status: String                              // e.g., ongoing, completed (may be "unknown").
    let year: Int?                                  // Optional year of publication.
    let coverURL: URL?                              // ✅ Pre-built cover URL (nil if none).
    let malId: Int?                                 // Canonical MyAnimeList id, if known (nil for sources without one).
    // Every other spelling the source knows this manga by — romaji, native, regional.
    // Matcher fuel for ADR-0016's bridge: matching one spelling against one spelling is
    // the weakness the bridge exists to route around, so this is the field that makes it
    // worth building. Empty/absent for sources that publish no alternates.
    //
    // `var` and optional, deliberately, and it is the only such property here. Both fall
    // out of ADR-0011's pool cache persisting this type whole:
    //   • optional → the synthesized decoder uses `decodeIfPresent`, so cache files
    //     written before this field existed still decode instead of being read as a miss
    //     and re-fetched.
    //   • `var` → Swift gives an optional `var` an implicit `= nil` in the memberwise
    //     initializer (a `let` optional gets no such default), which is what keeps ~40
    //     existing construction sites compiling untouched.
    // Read it as `altTitles ?? []`; nil and empty mean the same thing to every consumer.
    var altTitles: [String]?
    /// Host API classification for this Listing. Missing means unknown, never safe.
    /// Optional keeps persisted `Manga` values from before extension support decodable.
    var contentRating: String?
}

/// A small item representing “latest updates” (which chapter just arrived for a manga).
struct MangaUpdate: Identifiable {                  // Helper type for Latest Updates rails.
    let id: String                                  // Use `chapterId` as unique ID for the update item.
    let chapterId: String                           // The chapter we’ll open for reading.
    let manga: Manga                                // The associated manga (with cover).
    var title: String { manga.title }               // Convenience for UI bindings.
    init(chapterId: String, manga: Manga) {         // Convenience initializer for clarity.
        self.id = chapterId
        self.chapterId = chapterId
        self.manga = manga
    }
}

// MARK: - Detail + Chapter domain types (used by MangaDetailView / MangaDetailViewModel)

/// A single readable chapter for the detail screen's chapter list.
struct Chapter: Identifiable, Equatable, Codable {  // Identifiable so SwiftUI ForEach works directly.
    let id: String                                  // Chapter UUID (used to open the reader).
    let number: String                              // Chapter number as displayed (e.g., "12").
    let title: String?                              // Optional chapter title.
    let date: Date?                                 // When the chapter was added/published (nil if unknown).
    let groups: [String]?                            // Scanlation groups, when the source knows them.

    init(id: String, number: String, title: String?, date: Date? = nil, groups: [String]? = nil) {
        self.id = id
        self.number = number
        self.title = title
        self.date = date
        self.groups = groups
    }

    /// Parse an ISO-8601 timestamp (with or without fractional seconds) into a `Date`.
    /// Shared by the sources that expose a chapter date. Returns nil for nil/empty/garbage.
    static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// A source tag. Compiled MangaDex tags carry both fields; extension-backed HTML
/// sources may have neither stable ids nor groups under the Host API v1 contract.
struct Tag: Codable, Hashable {
    let id: String?
    let name: String
    let group: String?
}

/// Enriched manga metadata shown on the detail screen.
struct MangaDetail {                                // Plain value type consumed by the detail view model.
    let description: String                         // English description (falls back to any locale).
    let authors: [String]                           // Author + artist names (deduped, order preserved).
    let tags: [Tag]                                 // Genre/theme tags with id, name, and group.
    let contentRating: String?                      // safe / suggestive / erotica / pornographic.
}
