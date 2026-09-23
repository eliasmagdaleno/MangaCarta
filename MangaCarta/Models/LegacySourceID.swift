import Foundation

/// Data written before source ids were recorded came from MangaDex; this is a data
/// label, not a registered Source.
enum LegacySourceID {
    static let unattributed = "mangadex"
}
