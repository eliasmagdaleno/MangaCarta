import Foundation

struct PendingAnalyticsDelete: Codable, Equatable {
    let install: UUID
    let queued: Date
}

@MainActor
final class AnalyticsEventBuffer {
    static let capacity = 500

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var events: [AnalyticsEnvelope]
    private(set) var pendingDeletes: [PendingAnalyticsDelete]

    var directoryURL: URL { directory }

    private var bufferURL: URL { directory.appendingPathComponent("buffer.json") }
    private var installURL: URL { directory.appendingPathComponent("install.json") }
    private var ledgerURL: URL { directory.appendingPathComponent("ledger.json") }
    private var deletesURL: URL { directory.appendingPathComponent("pending-deletes.json") }

    init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent("buffer.json")
        let decoder = JSONDecoder()
        events = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([AnalyticsEnvelope].self, from: $0) } ?? []
        events = Array(events.suffix(Self.capacity))
        pendingDeletes = (try? Data(contentsOf: directory.appendingPathComponent("pending-deletes.json")))
            .flatMap { try? decoder.decode([PendingAnalyticsDelete].self, from: $0) } ?? []
    }

    static func defaultDirectory() -> URL {
        WorkStore.applicationSupportDirectory().appendingPathComponent("analytics", isDirectory: true)
    }

    func append(_ envelope: AnalyticsEnvelope) {
        events.append(envelope)
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
        write(events, to: bufferURL)
    }

    func queueDelete(_ id: UUID, at date: Date) {
        guard !pendingDeletes.contains(where: { $0.install == id }) else { return }
        pendingDeletes.append(PendingAnalyticsDelete(install: id, queued: date))
        write(pendingDeletes, to: deletesURL)
    }

    func removePendingDelete(_ id: UUID) {
        pendingDeletes.removeAll { $0.install == id }
        write(pendingDeletes, to: deletesURL)
    }

    func remove(sent: [AnalyticsEnvelope]) {
        var remaining = sent
        events = events.filter { event in
            guard let index = remaining.firstIndex(of: event) else { return true }
            remaining.remove(at: index)
            return false
        }
        write(events, to: bufferURL)
    }

    var installID: UUID? {
        guard let data = try? Data(contentsOf: installURL), let string = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func mintInstallIDIfNeeded() -> UUID {
        if let installID { return installID }
        let id = UUID(); write(Data(id.uuidString.utf8), to: installURL); return id
    }

    func eraseAll() {
        events.removeAll()
        let manager = FileManager.default
        for url in [bufferURL, installURL, ledgerURL] { try? manager.removeItem(at: url) }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch { }
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { }
    }
}
