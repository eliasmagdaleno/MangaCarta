import Foundation

@MainActor
final class AnalyticsEventBuffer {
    static let capacity = 500

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var events: [AnalyticsEnvelope]

    private var bufferURL: URL { directory.appendingPathComponent("buffer.json") }
    private var installURL: URL { directory.appendingPathComponent("install.json") }
    private var ledgerURL: URL { directory.appendingPathComponent("ledger.json") }

    init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent("buffer.json")
        let decoder = JSONDecoder()
        events = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([AnalyticsEnvelope].self, from: $0) } ?? []
        events = Array(events.suffix(Self.capacity))
    }

    static func defaultDirectory() -> URL {
        WorkStore.applicationSupportDirectory().appendingPathComponent("analytics", isDirectory: true)
    }

    func append(_ envelope: AnalyticsEnvelope) {
        events.append(envelope)
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
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
