//
//  Work.swift
//  MangaCarta
//
//  ADR-0001 split identity from availability: a **Work** is the manga itself, a
//  **Listing** is one source's copy of it. `Manga` is a Listing despite the name.
//  ADR-0007 pins the shape.
//

import Foundation

/// The app's own opaque identifier for a Work. **Immutable for the life of the
/// Work** and never derived from an external id — a provider id may arrive long
/// after the Work exists, or never.
struct WorkID: Hashable, Codable {
    let raw: UUID

    init(raw: UUID = UUID()) { self.raw = raw }
}

/// Identifies a Listing. This — not the Work id — is what history, library, and
/// taste feedback persist; Works are resolved from it at the seam (ADR-0007).
struct ListingKey: Hashable, Codable {
    let sourceId: String
    let mangaId: String

    init(sourceId: String, mangaId: String) {
        self.sourceId = sourceId
        self.mangaId = mangaId
    }

    init(_ listing: Manga) {
        self.init(sourceId: listing.sourceId, mangaId: listing.id)
    }
}

struct RemovedListing: Codable, Equatable, Hashable {
    let key: ListingKey
    let keepsReadState: Bool
}

/// The ids metadata providers assign to a Work. Modelled as a struct rather than a
/// dictionary because the set is small, closed, and typed (`mal` is an `Int`), and
/// adding a provider is an ADR-level event rather than a runtime one.
///
/// These **accumulate and are never replaced** — one AniList query yields both its
/// own id and `idMal`, which is the whole reason AniList was chosen over competing
/// with MyAnimeList (ADR-0002).
struct ExternalIDs: Codable, Equatable {
    var mal: Int?
    var anilist: Int?

    var isEmpty: Bool { mal == nil && anilist == nil }

    /// Union, keeping what's already known. Never overwrites a known id with `nil`.
    mutating func absorb(_ other: ExternalIDs) {
        mal = mal ?? other.mal
        anilist = anilist ?? other.anilist
    }
}

/// Who a Work's metadata came from. `.mangadex` marks a **provisional** snapshot —
/// built from a Listing's own tags at no request cost — rather than a real provider.
enum MetadataProviderID: String, Codable {
    case mangadex, mal, anilist
}

/// A tag on the **searchable axis**: a coarse name a Source can browse by, since
/// `mangaByTag` takes a display name. AniList's 19 `genres` and MangaDex's tags both
/// land here. This axis drives candidate *generation*.
///
/// `group` is MangaDex's bucket (genre / theme / format / content) and is `nil` for
/// AniList genres, which are all genre-level. Kept because `TasteProfile.groupWeight`
/// weights genre above theme above format; a bare name would silently flatten that.
struct QueryableTag: Codable, Equatable {
    let name: String
    let group: String?

    init(name: String, group: String? = nil) {
        self.name = name
        self.group = group
    }
}

/// A Work's metadata, all from **one** authoritative provider and stamped with which
/// one and when. Never merged field-by-field: with no labeled relevance data, the
/// golden diff is the only evidence a ranking change did what was intended, so the
/// number of things that can vary stays small (ADR-0007).
struct MetadataSnapshot: Codable, Equatable {
    var provider: MetadataProviderID
    var fetchedAt: Date
    /// Searchable axis — drives generation.
    var genres: [QueryableTag]
    /// Ranked axis — scoring and re-ranking only.
    var tags: [RankedTag]
    var publicationStatus: PublicationStatus
    /// `nil` while releasing; providers only know a total once a series ends.
    var chapterTotal: Int?

    /// Mirrors `EntityResolutionStore.missTTL` — the same 14 days, for the same
    /// reason: a negative answer is worth re-asking eventually, a positive one isn't.
    static let releasingTTL: TimeInterval = 14 * 24 * 60 * 60

    /// Whether the upgrade queue should refetch this. Derived from the Work's own
    /// publication status rather than one guessed interval for everything.
    func isStale(now: Date = Date()) -> Bool {
        // Provisional snapshots are placeholders: always upgrade them. This is how
        // the queue knows there is work to do.
        guard provider != .mangadex else { return true }
        // FINISHED is terminal -- the chapter total will never change again.
        guard publicationStatus != .finished else { return false }
        return now.timeIntervalSince(fetchedAt) >= Self.releasingTTL
    }
}

/// A manga as a thing in the world, independent of where you read it.
struct Work: Codable, Identifiable {
    let id: WorkID
    /// The Listing title this Work was **minted from**. Set once and never
    /// overwritten by a provider: AniList's canonical title is frequently the
    /// romaji one, so letting a snapshot win would rename a title the user
    /// recognizes as a delayed side effect of a background fetch.
    var displayTitle: String
    /// Every title this Work has been known by — each linked Listing's mint-time
    /// title plus any provider's titles. Accumulates, never shrinks. Matcher fuel.
    var knownTitles: [String]
    var externalIds: ExternalIDs
    var listings: [ListingKey]
    var removedListings: [RemovedListing] = []
    var handLinkedListings: [ListingKey] = []
    /// `nil` until anything is known — a Work minted from a scraped source with no
    /// external id is legitimately metadata-less until resolution reaches it.
    var snapshot: MetadataSnapshot?

    init(id: WorkID, displayTitle: String, knownTitles: [String], externalIds: ExternalIDs,
         listings: [ListingKey], removedListings: [RemovedListing] = [],
         handLinkedListings: [ListingKey] = [], snapshot: MetadataSnapshot? = nil) {
        self.id = id; self.displayTitle = displayTitle; self.knownTitles = knownTitles
        self.externalIds = externalIds; self.listings = listings
        self.removedListings = removedListings; self.handLinkedListings = handLinkedListings
        self.snapshot = snapshot
    }

    enum CodingKeys: String, CodingKey {
        case id, displayTitle, knownTitles, externalIds, listings, removedListings, handLinkedListings, snapshot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(WorkID.self, forKey: .id)
        displayTitle = try c.decode(String.self, forKey: .displayTitle)
        knownTitles = try c.decode([String].self, forKey: .knownTitles)
        externalIds = try c.decode(ExternalIDs.self, forKey: .externalIds)
        listings = try c.decode([ListingKey].self, forKey: .listings)
        removedListings = try c.decodeIfPresent([RemovedListing].self, forKey: .removedListings) ?? []
        handLinkedListings = try c.decodeIfPresent([ListingKey].self, forKey: .handLinkedListings) ?? []
        snapshot = try c.decodeIfPresent(MetadataSnapshot.self, forKey: .snapshot)
    }

    /// Adds a title if it's new, preserving order. Blank titles are ignored.
    mutating func noteTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !knownTitles.contains(trimmed) else { return }
        knownTitles.append(trimmed)
    }
}
