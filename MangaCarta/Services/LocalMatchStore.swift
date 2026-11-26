import Foundation

@MainActor
final class LocalMatchStore {
    private let directory: URL
    private(set) var records: [WorkID: LocalMatchRecord] = [:]
    private var fileURL: URL { directory.appendingPathComponent("local-matches.json") }

    init(directory: URL = WorkStore.applicationSupportDirectory()) {
        self.directory = directory
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Persisted.self, from: data), payload.version == 1 else { return }
        records = Dictionary(uniqueKeysWithValues: payload.records.map { ($0.localWorkID, $0) })
    }

    func record(for workID: WorkID) -> LocalMatchRecord? { records[workID] }

    func save(_ record: LocalMatchRecord) {
        records[record.localWorkID] = record
        persist()
    }

    func markUnmatched(workID: WorkID, at date: Date = Date()) {
        let previous = records[workID]
        save(LocalMatchRecord(localWorkID: workID, confirmedAt: date, status: .unmatched,
                              evidence: previous?.evidence ?? []))
    }

    func remove(workID: WorkID) { records[workID] = nil; persist() }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Persisted(version: 1, records: Array(records.values)))
                .write(to: fileURL, options: .atomic)
        } catch { /* Keep in-memory intent; a later write can retry. */ }
    }

    private struct Persisted: Codable { let version: Int; let records: [LocalMatchRecord] }
}
