import Foundation

/// Rebinds persisted Listings only after the reader chooses which installed Source
/// should inherit an older Source's data. The binding is applied before app stores
/// load on every launch: retries are idempotent, and a failed write remains retryable.
@MainActor
enum InstalledSourceIDMigration {
    private static let bindingsKey = "source.idMigrationBindings"
    private static let fileNames = ["works.json", "updates.json"]
    private static let dataKeys = ["library.items", "history.entries", "source.workChoices",
                                   "entityResolution.cache"]
    private static let stringKeys = ["source.primaryID", "source.activeID"]

    enum MigrationError: Error, LocalizedError {
        case invalidData(String)
        case collision(String)
        case write(String)

        var errorDescription: String? {
            "Previous Source data could not be reconnected. Nothing was removed."
        }
    }

    static func legacyID(for localID: String) -> String? {
        switch localID {
        case "mangadex": return LegacySourceID.unattributed
        case "weebcentral": return WeebCentralIdentityMigration.qualifiedID
        default: return nil
        }
    }

    static let legacyIDs = [LegacySourceID.unattributed, WeebCentralIdentityMigration.qualifiedID]

    static func request(legacyID oldID: String, installed: InstalledSourceRecord,
                        defaults: UserDefaults) {
        guard legacyID(for: installed.localId) == oldID else { return }
        var bindings = defaults.dictionary(forKey: bindingsKey) as? [String: String] ?? [:]
        bindings[oldID] = installed.qualifiedId.rawValue
        defaults.set(bindings, forKey: bindingsKey)
    }

    static func hasLegacyData(_ legacyID: String, directory: URL, defaults: UserDefaults) -> Bool {
        for name in fileNames {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let rewritten = try? rewrite(data, oldID: legacyID, newID: "migration-probe"),
               rewritten != data { return true }
        }
        for key in dataKeys {
            if let data = defaults.data(forKey: key),
               let rewritten = try? rewrite(data, oldID: legacyID, newID: "migration-probe",
                                            cacheKeys: key == "entityResolution.cache",
                                            legacyNil: legacyID == LegacySourceID.unattributed &&
                                                (key == "library.items" || key == "history.entries")),
               rewritten != data { return true }
        }
        if stringKeys.contains(where: { defaults.string(forKey: $0) == legacyID }) { return true }
        return false
    }

    /// Runs after the former bare WeebCentral migration, before WorkStore and the
    /// UserDefaults-backed stores are constructed.
    ///
    /// A binding is one reader decision, spent once. It is cleared after it applies, and
    /// after a collision (retrying cannot resolve one). Otherwise, while the compiled or
    /// bundled Source still ships, data it records later would move on every launch
    /// without being offered, and one later collision would fail every launch after it.
    /// Only a failed write, or a target that may yet become usable, keeps it for retry.
    static func run(directory: URL, defaults: UserDefaults) throws {
        var bindings = defaults.dictionary(forKey: bindingsKey) as? [String: String] ?? [:]
        guard !bindings.isEmpty else { return }
        let repositories = RepositoryStore(directory: directory)
        var firstError: Error?
        for (oldID, targetID) in bindings.sorted(by: { $0.key < $1.key }) {
            let qualified = QualifiedSourceID(rawValue: targetID)
            guard let installed = repositories.source(qualified),
                  installed.state != .uninstalled,
                  legacyID(for: installed.localId) == oldID else {
                bindings[oldID] = nil
                continue
            }
            guard repositories.repository(installed.repositoryID)?.state == .active,
                  repositories.scriptData(for: installed.bundleId, in: installed.repositoryID) != nil
            else { continue }
            do {
                try rebind(oldID, to: targetID, directory: directory, defaults: defaults)
                bindings[oldID] = nil
            } catch {
                if case MigrationError.collision = error { bindings[oldID] = nil }
                firstError = firstError ?? error
            }
        }
        defaults.set(bindings, forKey: bindingsKey)
        if let firstError { throw firstError }
    }

    /// Rewrites only sourceId fields and the forward-resolution cache's qualified
    /// keys. Other strings (including a title equal to an old Source id) survive.
    /// JSON number tokens are never decoded and re-encoded (#203).
    private static func rebind(_ oldID: String, to newID: String,
                               directory: URL, defaults: UserDefaults) throws {
        var files: [(URL, Data, Data)] = []
        var values: [(String, Data, Data)] = []
        for name in fileNames {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let original = try Data(contentsOf: url)
            let replacement = try rewrite(original, oldID: oldID, newID: newID)
            if replacement != original { files.append((url, original, replacement)) }
        }
        for key in dataKeys {
            guard let original = defaults.data(forKey: key) else { continue }
            let replacement = try rewrite(original, oldID: oldID, newID: newID,
                                          cacheKeys: key == "entityResolution.cache",
                                          legacyNil: oldID == LegacySourceID.unattributed &&
                                              (key == "library.items" || key == "history.entries"))
            if replacement != original { values.append((key, original, replacement)) }
        }

        // Preflight collisions before the first write. An ambiguous merge needs its
        // own explicit resolution; choosing a winner here would discard user data.
        try checkListingCollisions(files: files, values: values, oldID: oldID, newID: newID)

        var writtenFiles: [(URL, Data)] = []
        var writtenValues: [(String, Data)] = []
        var oldStrings: [(String, String)] = []
        do {
            for (url, original, replacement) in files {
                try replacement.write(to: url, options: .atomic)
                writtenFiles.append((url, original))
            }
            for (key, original, replacement) in values {
                defaults.set(replacement, forKey: key)
                guard defaults.data(forKey: key) == replacement else { throw MigrationError.write(key) }
                writtenValues.append((key, original))
            }
            for key in stringKeys where defaults.string(forKey: key) == oldID {
                oldStrings.append((key, oldID))
                defaults.set(newID, forKey: key)
                guard defaults.string(forKey: key) == newID else { throw MigrationError.write(key) }
            }
        } catch {
            for (key, original) in writtenValues.reversed() { defaults.set(original, forKey: key) }
            for (key, original) in oldStrings.reversed() { defaults.set(original, forKey: key) }
            for (url, original) in writtenFiles.reversed() { try? original.write(to: url, options: .atomic) }
            throw MigrationError.write(String(describing: error))
        }
    }

    private static func checkListingCollisions(files: [(URL, Data, Data)],
                                               values: [(String, Data, Data)],
                                               oldID: String, newID: String) throws {
        for (name, original, _) in files.map({ ($0.0.lastPathComponent, $0.1, $0.2) }) + values {
            guard name == "works.json" || name == "updates.json" || name == "library.items" else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: original) else { continue }
            var old: Set<String> = []
            var new: Set<String> = []
            collectListings(object, oldID: oldID, newID: newID,
                            legacyNil: name == "library.items" && oldID == LegacySourceID.unattributed,
                            old: &old, new: &new)
            if !old.isDisjoint(with: new) { throw MigrationError.collision(name) }
        }
    }

    private static func collectListings(_ value: Any, oldID: String, newID: String,
                                        legacyNil: Bool,
                                        old: inout Set<String>, new: inout Set<String>) {
        if let object = value as? [String: Any] {
            if let manga = (object["mangaId"] ?? object["id"]) as? String {
                let source = object["sourceId"] as? String
                if source == oldID || (legacyNil && source == nil) { old.insert(manga) }
                if source == newID { new.insert(manga) }
            }
            for child in object.values { collectListings(child, oldID: oldID, newID: newID,
                                                         legacyNil: legacyNil,
                                                         old: &old, new: &new) }
        } else if let array = value as? [Any] {
            for child in array { collectListings(child, oldID: oldID, newID: newID,
                                                 legacyNil: legacyNil,
                                                 old: &old, new: &new) }
        }
    }

    static func rewrite(_ data: Data, oldID: String, newID: String,
                        cacheKeys: Bool = false, legacyNil: Bool = false) throws -> Data {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw MigrationError.invalidData("JSON")
        }
        let bytes = Array(data)
        let oldValue = Array("\"\(oldID)\"".utf8)
        let newValue = Array("\"\(newID)\"".utf8)
        let oldPrefix = Array("\"\(oldID):".utf8)
        let newPrefix = Array("\"\(newID):".utf8)
        let sourceKey = Array("\"sourceId\"".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var sourceValue = false
        while index < bytes.count {
            if bytes[index] == 34 {
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { index += 1; break }
                    index += 1
                }
                let token = Array(bytes[start..<index])
                var next = index
                while next < bytes.count && [10, 13, 32, 9].contains(bytes[next]) { next += 1 }
                let isKey = next < bytes.count && bytes[next] == 58
                if isKey {
                    sourceValue = token == sourceKey
                    if cacheKeys && token.starts(with: oldPrefix) {
                        output += newPrefix + token.dropFirst(oldPrefix.count)
                    } else { output += token }
                } else {
                    output += sourceValue && token == oldValue ? newValue : token
                    sourceValue = false
                }
            } else if sourceValue && legacyNil && index + 4 <= bytes.count &&
                        Array(bytes[index..<(index + 4)]) == [110, 117, 108, 108] {
                output += newValue
                index += 4
                sourceValue = false
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        var result = Data(output)
        if legacyNil { result = try insertingMissingSourceIDs(result, newID: newID) }
        guard (try? JSONSerialization.jsonObject(with: result)) != nil else {
            throw MigrationError.invalidData("rewritten JSON")
        }
        return result
    }

    private static func insertingMissingSourceIDs(_ data: Data, newID: String) throws -> Data {
        guard let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw MigrationError.invalidData("legacy array")
        }
        let missing = Set(objects.enumerated().compactMap { index, object in
            object["sourceId"] == nil ? index : nil
        })
        guard !missing.isEmpty else { return data }
        let bytes = Array(data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + missing.count * (newID.utf8.count + 16))
        var stack: [UInt8] = []
        var index = 0
        var item = -1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { index += 1; break }
                    index += 1
                }
                output += bytes[start..<index]
                continue
            }
            output.append(byte)
            if byte == 123 {
                if stack == [91] {
                    item += 1
                    if missing.contains(item) {
                        let following = bytes[(index + 1)...].first { ![10, 13, 32, 9].contains($0) }
                        output += Array("\"sourceId\":\"\(newID)\"\(following == 125 ? "" : ",")".utf8)
                    }
                }
                stack.append(byte)
            } else if byte == 91 {
                stack.append(byte)
            } else if byte == 125 || byte == 93 {
                if !stack.isEmpty { stack.removeLast() }
            }
            index += 1
        }
        let result = Data(output)
        guard (try? JSONSerialization.jsonObject(with: result)) != nil else {
            throw MigrationError.invalidData("inserted source IDs")
        }
        return result
    }
}
