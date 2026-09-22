import Foundation

/// Reconnects persisted references from the former compiled Source (`"weebcentral"`) to the
/// bundled Source (`<fixed-uuid>:weebcentral`) — ADR-0003 Amendment 5, part 5. It rewrites
/// only payloads that contain the bare id, so a second launch is byte-for-byte inert and a
/// file with no legacy reference is never rewritten.
///
/// Two shapes carry a source id: a string *value* equal to the bare id (every `ListingKey`,
/// `Manga.sourceId`, `source.primaryID`), and a dictionary *key* prefixed with it —
/// `EntityResolutionStore` keys its cache `"<sourceId>:<mangaId>"`. Both are rewritten.
///
/// `listing-counts.json` is deliberately not here: it lives in `Caches/`, is 24h-TTL and
/// disposable, and a stale entry under the old id is a cache miss, not a wrong answer.
@MainActor
enum WeebCentralIdentityMigration {
    static let legacyID = "weebcentral"
    static let qualifiedID = "\(BundledRepositories.weebCentralRepositoryID.uuidString.lowercased()):weebcentral"

    private static let legacyKeyPrefix = legacyID + ":"
    private static let files = ["works.json", "updates.json"]
    private static let defaultsKeys = [
        "library.items", "library.collections", "history.entries", "history.readMarks",
        "entityResolution.cache", "entityResolution.reverseCache", "taste.tagCache",
        "taste.notInterested", "taste.moreLikeThis", "source.primaryID", "source.workChoices"
    ]

    static func run(directory: URL, defaults: UserDefaults) {
        for name in files { rewriteFile(directory.appendingPathComponent(name)) }
        for key in defaultsKeys { rewriteDefaults(key, defaults: defaults) }
    }

    private static func rewriteFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let rewritten = rewritingLegacy(in: data) else { return }
        try? rewritten.write(to: url, options: .atomic)
    }

    private static func rewriteDefaults(_ key: String, defaults: UserDefaults) {
        if let string = defaults.string(forKey: key), string == legacyID {
            defaults.set(qualifiedID, forKey: key)
            return
        }
        guard let data = defaults.data(forKey: key),
              let rewritten = rewritingLegacy(in: data) else { return }
        defaults.set(rewritten, forKey: key)
    }

    /// Rewrites the id inside JSON text without parsing it into objects, so every byte that is
    /// not the id survives as it was — numbers included (#203: a `JSONSerialization` round trip
    /// moved a stored chapter number by one ULP), and key order too. Walks the string tokens: a
    /// value exactly `"weebcentral"` becomes the qualified id, and a *key* starting
    /// `"weebcentral:"` gets the qualified prefix. Returns `nil` when nothing matched or the
    /// data is not JSON, so a legacy-free payload is never written.
    static func rewritingLegacy(in data: Data) -> Data? {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        let bytes = [UInt8](data)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), colon = UInt8(ascii: ":")
        let legacyValue = Array("\"\(legacyID)\"".utf8)
        let legacyKeyStart = Array("\"\(legacyKeyPrefix)".utf8)
        let qualifiedValue = Array("\"\(qualifiedID)\"".utf8)
        let qualifiedKeyStart = Array("\"\(qualifiedID):".utf8)

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        while index < bytes.count {
            guard bytes[index] == quote else { output.append(bytes[index]); index += 1; continue }
            var end = index + 1
            while end < bytes.count, bytes[end] != quote { end += bytes[end] == backslash ? 2 : 1 }
            let token = Array(bytes[index...min(end, bytes.count - 1)])
            var after = end + 1
            while after < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[after]) { after += 1 }
            let isKey = after < bytes.count && bytes[after] == colon
            if !isKey, token == legacyValue {
                output += qualifiedValue; changed = true
            } else if isKey, token.starts(with: legacyKeyStart) {
                output += qualifiedKeyStart + token.dropFirst(legacyKeyStart.count); changed = true
            } else {
                output += token
            }
            index = end + 1
        }
        return changed ? Data(output) : nil
    }
}
