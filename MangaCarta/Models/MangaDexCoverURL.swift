// MangaDex-specific cover URL builder; used by the MangaDex adapter and SimulatorSeedFixture; revisit in removal slices 9–10.

import Foundation

/// Sizes for the cover image helper (MangaDex serves 256/512 JPEG variants automatically).
enum CoverSize {                                    // Choose which resolution to use for thumbnails.
    case w256                                       // 256px wide JPEG.
    case w512                                       // 512px wide JPEG (good default for cards).
    case original                                   // Original upload (larger; avoid for grids).
}

/// Builds the canonical cover URL on uploads.mangadex.org for a given manga + filename.
/// - Parameters:
///   - mangaId: The manga’s UUID.
///   - fileName: The cover image file name from the API (e.g., "abcd123.png").
///   - size: Desired variant (256/512/original).
/// - Returns: A URL you can pass to `AsyncImage`.
func mangaCoverURL(mangaId: String, fileName: String, size: CoverSize = .w512) -> URL? {
    let base = "https://uploads.mangadex.org/covers"            // Static covers host.
    switch size {                                               // Choose variant suffix.
    case .w256:
        return URL(string: "\(base)/\(mangaId)/\(fileName).256.jpg") // 256px JPEG.
    case .w512:
        return URL(string: "\(base)/\(mangaId)/\(fileName).512.jpg") // 512px JPEG.
    case .original:
        return URL(string: "\(base)/\(mangaId)/\(fileName)")         // Original upload (PNG/JPG).
    }
}
