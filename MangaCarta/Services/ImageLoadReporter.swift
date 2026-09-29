//
//  ImageLoadReporter.swift
//  MangaCarta
//
//  Sends image-load reports (ADR-0003 Amendment 9; design §4). Fire-and-forget:
//  `report` returns at once, a failed send is dropped, and nothing is retried.
//  Sends go through `HostHTTPClient`, so the endpoint passes the host URL policy and
//  gets its own per-Source spacing and 429 pause (Amendment 8).
//

import Foundation
import os

final class ImageLoadReporter: ImageLoadReporting, @unchecked Sendable {
    /// A pause can hold reports for up to five minutes while the reader keeps turning
    /// pages. Past this many in flight for one Source, new reports are dropped: a lost
    /// report costs the operator a sample, and an unbounded queue costs the reader memory.
    static let maximumInFlightPerSource = 64
    private static let log = Logger(subsystem: "Elias-Magdaleno.Manga-Reader",
                                    category: "ImageLoadReporter")

    let rateLimiters: HostRateLimiterRegistry
    private let transport: any HostHTTPTransport
    private let resolver: any HostNameResolving
    private let maximumInFlightPerSource: Int

    private let lock = NSLock()
    private var inFlight: [QualifiedSourceID: Int] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(rateLimiters: HostRateLimiterRegistry,
         transport: any HostHTTPTransport = URLSessionHostHTTPTransport(),
         resolver: any HostNameResolving = SystemHostResolver(),
         maximumInFlightPerSource: Int = ImageLoadReporter.maximumInFlightPerSource) {
        self.rateLimiters = rateLimiters
        self.transport = transport
        self.resolver = resolver
        self.maximumInFlightPerSource = maximumInFlightPerSource
    }

    func report(_ report: ImageLoadReport, to target: ImageLoadReportTarget) {
        guard let origin = HostURLPolicy.canonicalOrigin(for: target.endpoint) else { return }
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        guard inFlight[target.sourceID, default: 0] < maximumInFlightPerSource else { return }
        inFlight[target.sourceID, default: 0] += 1
        tasks[id] = Task.detached(priority: .utility) { [self] in
            await send(report, to: target, origin: origin)
            finish(id, sourceID: target.sourceID)
        }
    }

    /// Test hook: returns once every report started so far has finished.
    func waitUntilIdle() async {
        while true {
            lock.lock()
            let pending = Array(tasks.values)
            lock.unlock()
            guard !pending.isEmpty else { return }
            for task in pending { await task.value }
        }
    }

    private func finish(_ id: UUID, sourceID: QualifiedSourceID) {
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = nil
        inFlight[sourceID, default: 1] -= 1
        if inFlight[sourceID] == 0 { inFlight[sourceID] = nil }
    }

    private func send(_ report: ImageLoadReport, to target: ImageLoadReportTarget,
                      origin: String) async {
        // A fresh jar per report: a report never carries a cookie, not even one an
        // earlier report's response set, and never the jar the engine's HTTP uses.
        let client = HostHTTPClient(sourceID: target.sourceID, allowedOrigins: [origin],
                                    transport: transport, resolver: resolver,
                                    cookies: HostHTTPCookieJar(sourceID: target.sourceID),
                                    rateLimiters: rateLimiters)
        do {
            _ = try await client.request(HostHTTPRequest(
                url: target.endpoint, method: .post,
                headers: ["Content-Type": "application/json"],
                body: .text(Self.payload(report)),
                timeoutClass: .background))
        } catch {
#if DEBUG
            Self.log.debug("Image-load report dropped: \(String(describing: error), privacy: .public)")
#endif
        }
    }

    /// Exactly the five fields MangaDex specifies; `bytes` and `duration` are integers.
    static func payload(_ report: ImageLoadReport) -> String {
        let object: [String: Any] = ["url": report.url.absoluteString,
                                     "success": report.success,
                                     "cached": report.cached,
                                     "bytes": report.bytes,
                                     "duration": report.durationMilliseconds]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(bytes: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
