import Foundation

struct MALSourceChoice: Codable, Equatable {
    let malId: Int
    let sourceId: String
    let manga: Manga
    let title: String
    let confirmedAt: Date
}

/// Durable reader evidence. Persistence is deliberately best-effort: a disk failure must not
/// turn a successful tap into an error, nor create a negative resolution cache.
actor MALSourceChoiceStore {
    private let directory: URL
    private var records: [Int: MALSourceChoice] = [:]
    private var loaded = false

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
            .appendingPathComponent("MALHub", isDirectory: true)) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent("source-choices.json") }

    func choice(for malId: Int) -> MALSourceChoice? {
        loadIfNeeded(); return records[malId]
    }

    func confirm(malId: Int, sourceId: String, manga: Manga, title: String,
                 confirmedAt: Date = Date()) {
        loadIfNeeded()
        records[malId] = MALSourceChoice(malId: malId, sourceId: sourceId, manga: manga,
                                         title: title, confirmedAt: confirmedAt)
        save()
    }

    func remove(malId: Int) {
        loadIfNeeded(); records.removeValue(forKey: malId); save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }; loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: MALSourceChoice].self, from: data) else { return }
        records = decoded.reduce(into: [:]) { result, pair in
            if let id = Int(pair.key) { result[id] = pair.value }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let raw = Dictionary(uniqueKeysWithValues: records.map { (String($0.key), $0.value) })
            try JSONEncoder().encode(raw).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MALSourceChoiceStore write failed: %@", String(describing: error))
        }
    }
}
