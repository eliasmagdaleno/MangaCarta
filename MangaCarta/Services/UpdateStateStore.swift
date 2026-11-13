import Foundation

struct ListingCheckState: Codable, Equatable {
    var lastSuccess: Date?
    var lastFailure: Date?
    var consecutiveFailures: Int = 0
    var blockedUntil: Date?
}

struct WorkUpdateState: Codable, Equatable {
    var frontier = ChapterFrontier()
    var hasBaseline = false
    var newlyDiscovered: Set<ChapterOrdinal> = []
    var newestDiscoveryAt: Date?
    var lastSuccessfulCheck: Date?
    var isMuted = false
    var listings: [ListingKey: ListingCheckState] = [:]
}

@MainActor
final class UpdateStateStore: ObservableObject {
    @Published private(set) var states: [WorkID: WorkUpdateState] = [:]
    @Published private(set) var refreshCursor: WorkID?

    private let directory: URL
    private let saveDebounce: TimeInterval
    private let works: WorkStore?
    private var loaded = false
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    private var fileURL: URL { directory.appendingPathComponent("updates.json") }

    init(directory: URL = WorkStore.applicationSupportDirectory(),
         saveDebounce: TimeInterval = 1.0,
         works: WorkStore? = nil) {
        self.directory = directory
        self.saveDebounce = saveDebounce
        self.works = works
        loadIfNeeded()
    }

    func state(for workId: WorkID) -> WorkUpdateState? {
        loadIfNeeded()
        return states[workId]
    }

    func absorb(workId: WorkID,
                listing: ListingKey,
                rawNumbers: [String],
                now: Date = Date()) -> [ChapterOrdinal] {
        loadIfNeeded()
        var state = states[workId] ?? WorkUpdateState()
        var check = state.listings[listing] ?? ListingCheckState()
        let released: [ChapterOrdinal]

        if state.hasBaseline {
            released = state.frontier.absorb(rawNumbers)
            state.newlyDiscovered.formUnion(released)
            if !released.isEmpty { state.newestDiscoveryAt = now }
        } else {
            state.frontier.seed(rawNumbers)
            state.hasBaseline = true
            released = []
        }

        state.lastSuccessfulCheck = now
        check.lastSuccess = now
        check.lastFailure = nil
        check.consecutiveFailures = 0
        check.blockedUntil = nil
        state.listings[listing] = check
        states[workId] = state
        markDirty()
        return released
    }

    func recordFailure(workId: WorkID, listing: ListingKey, now: Date = Date()) {
        loadIfNeeded()
        var state = states[workId] ?? WorkUpdateState()
        var check = state.listings[listing] ?? ListingCheckState()
        check.consecutiveFailures += 1
        check.lastFailure = now
        let multiplier = pow(2.0, Double(check.consecutiveFailures))
        let delay = min(multiplier * UpdateTuning.backoffBase, UpdateTuning.backoffCeiling)
        check.blockedUntil = now.addingTimeInterval(delay)
        state.listings[listing] = check
        states[workId] = state
        markDirty()
    }

    func dropListing(_ listing: ListingKey, from workId: WorkID) {
        loadIfNeeded()
        guard var state = states[workId], state.listings.removeValue(forKey: listing) != nil else { return }
        states[workId] = state; markDirty()
    }

    func clearNewlyDiscovered(workId: WorkID) {
        loadIfNeeded()
        guard var state = states[workId], !state.newlyDiscovered.isEmpty else { return }
        state.newlyDiscovered = []
        states[workId] = state
        markDirty()
    }

    func clearNewlyDiscovered(_ ordinals: Set<ChapterOrdinal>, workId: WorkID) {
        loadIfNeeded()
        guard var state = states[workId] else { return }
        let remaining = state.newlyDiscovered.subtracting(ordinals)
        guard remaining != state.newlyDiscovered else { return }
        state.newlyDiscovered = remaining
        states[workId] = state
        markDirty()
    }

    func setMuted(_ isMuted: Bool, workId: WorkID) {
        loadIfNeeded()
        var state = states[workId] ?? WorkUpdateState()
        guard state.isMuted != isMuted else { return }
        state.isMuted = isMuted
        states[workId] = state
        markDirty()
    }

    @discardableResult
    func forget(workId: WorkID) -> String {
        loadIfNeeded()
        let resolved = works?.work(workId)?.id ?? workId
        states[resolved] = nil
        markDirty()
        return Self.notificationIdentifier(for: resolved)
    }

    static func notificationIdentifier(for workId: WorkID) -> String {
        "work-\(workId.raw.uuidString)"
    }

    func setRefreshCursor(_ workId: WorkID?) {
        loadIfNeeded()
        guard refreshCursor != workId else { return }
        refreshCursor = workId
        markDirty()
    }

    func reconcileMerges(using works: WorkStore) {
        loadIfNeeded()
        var changed = false

        // WorkStore persists aliases and work(_:) follows them, so merge effects are
        // observable without changing that golden-tested store. If aliases are ever
        // pruned, this mechanism dies silently and a pushed merge seam must be revisited.
        for workId in Array(states.keys) {
            guard let resolved = works.work(workId)?.id else {
                states[workId] = nil
                changed = true
                continue
            }
            guard resolved != workId, let losing = states.removeValue(forKey: workId) else { continue }
            states[resolved] = Self.merged(states[resolved] ?? WorkUpdateState(), losing)
            changed = true
        }

        if changed { markDirty() }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        dirty = false
        let payload = UpdateStatePersisted(
            records: states.map { .init(workId: $0.key, state: $0.value) },
            refreshCursor: refreshCursor
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            dirty = true
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(UpdateStatePersisted.self, from: data) else { return }
        states = Dictionary(uniqueKeysWithValues: payload.records.map { ($0.workId, $0.state) })
        refreshCursor = payload.refreshCursor
    }

    private func markDirty() {
        dirty = true
        saveTask?.cancel()
        let delay = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private static func merged(_ first: WorkUpdateState,
                               _ second: WorkUpdateState) -> WorkUpdateState {
        var result = first
        result.frontier.mergeEvidence(from: second.frontier)
        result.hasBaseline = first.hasBaseline || second.hasBaseline
        result.newlyDiscovered.formUnion(second.newlyDiscovered)
        result.newestDiscoveryAt = latest(first.newestDiscoveryAt, second.newestDiscoveryAt)
        result.lastSuccessfulCheck = latest(first.lastSuccessfulCheck, second.lastSuccessfulCheck)
        result.isMuted = first.isMuted || second.isMuted
        for (listing, incoming) in second.listings {
            guard let current = result.listings[listing] else {
                result.listings[listing] = incoming
                continue
            }
            result.listings[listing] = preferred(current, incoming)
        }
        return result
    }

    private static func preferred(_ first: ListingCheckState,
                                  _ second: ListingCheckState) -> ListingCheckState {
        let firstDate = first.lastSuccess ?? .distantPast
        let secondDate = second.lastSuccess ?? .distantPast
        return secondDate > firstDate ? second : first
    }

    private static func latest(_ first: Date?, _ second: Date?) -> Date? {
        [first, second].compactMap { $0 }.max()
    }
}

private struct UpdateStatePersisted: Codable {
    struct Record: Codable {
        let workId: WorkID
        let state: WorkUpdateState
    }
    let records: [Record]
    let refreshCursor: WorkID?
}
