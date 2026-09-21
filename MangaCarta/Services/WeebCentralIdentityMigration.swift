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
        guard let data = try? Data(contentsOf: url) else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return }
        let object: Any = parsed
        guard containsLegacy(object) else { return }
        let rewritten = replacingLegacy(in: object)
        guard JSONSerialization.isValidJSONObject(rewritten),
              let output = try? JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys]) else { return }
        try? output.write(to: url, options: .atomic)
    }

    private static func rewriteDefaults(_ key: String, defaults: UserDefaults) {
        if let string = defaults.string(forKey: key), string == legacyID {
            defaults.set(qualifiedID, forKey: key)
            return
        }
        guard let data = defaults.data(forKey: key),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return }
        let object: Any = parsed
        guard containsLegacy(object) else { return }
        let rewritten = replacingLegacy(in: object)
        guard let output = try? JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys]) else { return }
        defaults.set(output, forKey: key)
    }

    private static func containsLegacy(_ value: Any) -> Bool {
        if let string = value as? String { return string == legacyID }
        if let array = value as? [Any] { return array.contains(where: containsLegacy) }
        if let object = value as? [String: Any] {
            return object.keys.contains { $0.hasPrefix(legacyKeyPrefix) }
                || object.values.contains(where: containsLegacy)
        }
        return false
    }

    private static func replacingLegacy(in value: Any) -> Any {
        if let string = value as? String { return string == legacyID ? qualifiedID : string }
        if let array = value as? [Any] { return array.map(replacingLegacy) }
        if let object = value as? [String: Any] {
            var rewritten: [String: Any] = [:]
            for (key, inner) in object {
                let newKey = key.hasPrefix(legacyKeyPrefix)
                    ? qualifiedID + ":" + key.dropFirst(legacyKeyPrefix.count)
                    : key
                rewritten[newKey] = replacingLegacy(in: inner)
            }
            return rewritten
        }
        return value
    }
}
