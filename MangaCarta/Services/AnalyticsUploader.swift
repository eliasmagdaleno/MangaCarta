import Foundation

@MainActor
final class AnalyticsUploader {
    static let batchSize = 100
    static let minimumInterval: TimeInterval = 15 * 60
    static let maximumBackoff: TimeInterval = 24 * 60 * 60
    static let deleteLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let buffer: AnalyticsEventBuffer
    private let consent: AnalyticsConsentStore
    private let transport: any AnalyticsTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private let bufferChanged: () -> Void
    private var operation: Task<Void, Never>?
    private let nextKey = "analytics.nextUploadAfter"
    private let backoffKey = "analytics.uploadBackoff"

    init(buffer: AnalyticsEventBuffer, consent: AnalyticsConsentStore, transport: any AnalyticsTransport,
         defaults: UserDefaults, now: @escaping () -> Date = Date.init,
         bufferChanged: @escaping () -> Void = {}) {
        self.buffer = buffer
        self.consent = consent
        self.transport = transport
        self.defaults = defaults
        self.now = now
        self.bufferChanged = bufferChanged
    }

    func sendPendingDeletes() async {
        let previous = operation
        let current = Task { @MainActor in
            await previous?.value
            await self.performPendingDeletes()
        }
        operation = current
        await current.value
    }

    func drainIfDue() async {
        let previous = operation
        let current = Task { @MainActor in
            await previous?.value
            await self.performDrain()
        }
        operation = current
        await current.value
    }

    private func performPendingDeletes() async {
        for pending in buffer.pendingDeletes {
            if now().timeIntervalSince(pending.queued) > Self.deleteLifetime {
                buffer.removePendingDelete(pending.install)
                continue
            }
            switch await transport.deleteInstall(pending.install) {
            case .accepted, .rejected: buffer.removePendingDelete(pending.install)
            case .retry: continue
            }
        }
    }

    private func performDrain() async {
        await performPendingDeletes()
        guard consent.isCollecting, now() >= (defaults.object(forKey: nextKey) as? Date ?? .distantPast) else { return }
        var retried = false
        while consent.isCollecting {
            let batch = Array(buffer.events.prefix(Self.batchSize))
            guard !batch.isEmpty else { break }
            let payload = Batch(v: AnalyticsEnvelope.schemaVersion, events: batch)
            let result: AnalyticsUploadResult
            do { result = await transport.sendBatch(try JSONEncoder().encode(payload)) }
            catch { result = .retry }
            switch result {
            case .accepted, .rejected:
                buffer.remove(sent: batch)
                bufferChanged()
            case .retry:
                retried = true
                let backoff = defaults.double(forKey: backoffKey).nonzero ?? Self.minimumInterval
                defaults.set(now().addingTimeInterval(backoff), forKey: nextKey)
                defaults.set(min(backoff * 2, Self.maximumBackoff), forKey: backoffKey)
                return
            }
            if !consent.isCollecting { break }
        }
        if !retried {
            defaults.set(now().addingTimeInterval(Self.minimumInterval), forKey: nextKey)
            defaults.set(Self.minimumInterval, forKey: backoffKey)
        }
    }

    private struct Batch: Encodable { let v: Int; let events: [AnalyticsEnvelope] }
}

private extension Double {
    var nonzero: Double? { self > 0 ? self : nil }
}
