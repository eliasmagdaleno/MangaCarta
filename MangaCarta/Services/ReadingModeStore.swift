//
//  ReadingModeStore.swift
//  MangaCarta
//
//  How each Work is read (ADR-0026). Two tiers: a Work's own mode, else the default.
//
//  UserDefaults rather than a file, for `SourcePreferenceStore`'s reason: small, flat,
//  and needed on the reader's first paint.
//
//  Merges follow `UpdateStateStore.reconcileMerges`' rule — a key belongs to the Work it
//  resolves to, the survivor's own entry wins, an unresolvable key is ignored — applied
//  in two places. Reads are pure, because `ReaderView.body` calls them and publishing
//  from there is a SwiftUI runtime error. Writes re-key the stored map first.
//

import Foundation

@MainActor
final class ReadingModeStore: ObservableObject {

    static let defaultKey = "readingMode"
    static let workModesKey = "reader.workModes"

    private let defaults: UserDefaults
    private let works: WorkStore

    /// Work id (uuidString) → that Work's own mode. Keys may be merged-away ids until the
    /// next write re-keys them.
    @Published private var modes: [String: ReadingMode] = [:]

    /// The mode every Work without its own follows. Keeps the key the reader's old
    /// `@AppStorage` used, so an update changes nobody's mode.
    @Published var defaultMode: ReadingMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Self.defaultKey) }
    }

    init(defaults: UserDefaults = .standard, works: WorkStore) {
        self.defaults = defaults
        self.works = works
        defaultMode = defaults.string(forKey: Self.defaultKey).flatMap(ReadingMode.init(rawValue:))
            ?? .rightToLeft
        if let data = defaults.data(forKey: Self.workModesKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            modes = raw.compactMapValues(ReadingMode.init(rawValue:))
        }
    }

    // MARK: - Reads (pure)

    /// The Work's own mode, or `nil` when it follows the default.
    func mode(for workID: WorkID) -> ReadingMode? {
        guard let target = resolvedKey(workID.raw.uuidString) else { return nil }
        if let own = modes[target] { return own }
        return modes.keys.sorted()
            .first { $0 != target && resolvedKey($0) == target }
            .flatMap { modes[$0] }
    }

    func effectiveMode(for workID: WorkID?) -> ReadingMode {
        workID.flatMap(mode(for:)) ?? defaultMode
    }

    // MARK: - Writes

    func set(_ mode: ReadingMode, for workID: WorkID) {
        var next = rekeyed()
        guard let target = resolvedKey(workID.raw.uuidString) else { return }
        next[target] = mode
        commit(next)
    }

    func clear(for workID: WorkID) {
        var next = rekeyed()
        guard let target = resolvedKey(workID.raw.uuidString) else { return }
        next[target] = nil
        commit(next)
    }

    @discardableResult
    func seed(_ mode: ReadingMode, for workID: WorkID) -> Bool {
        guard self.mode(for: workID) == nil else { return false }
        set(mode, for: workID)
        return true
    }

    // MARK: - Merge resolution

    /// The live Work id a stored key belongs to, or `nil` when it resolves to no Work.
    private func resolvedKey(_ key: String) -> String? {
        guard let uuid = UUID(uuidString: key) else { return nil }
        return works.work(WorkID(raw: uuid))?.id.raw.uuidString
    }

    /// `modes` with every key moved to the Work it resolves to. The survivor's own entry
    /// wins; among several merged-away keys the lexicographically smallest wins, matching
    /// the read path; unresolvable keys are dropped.
    private func rekeyed() -> [String: ReadingMode] {
        var result: [String: ReadingMode] = [:]
        for key in modes.keys.sorted() {
            guard let target = resolvedKey(key), let value = modes[key] else { continue }
            if key == target {
                result[target] = value
            } else if result[target] == nil, modes[target] == nil {
                result[target] = value
            }
        }
        return result
    }

    private func commit(_ next: [String: ReadingMode]) {
        modes = next
        guard let data = try? JSONEncoder().encode(next.mapValues(\.rawValue)) else { return }
        defaults.set(data, forKey: Self.workModesKey)
    }
}
