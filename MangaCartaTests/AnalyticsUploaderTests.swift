import Foundation
import XCTest
@testable import MangaCarta

@MainActor
final class AnalyticsUploaderTests: XCTestCase {
    func testSuccessRemovesOnlySentEvents() async {
        let f = fixture()
        f.fill(2)
        let newInstall = UUID()
        f.transport.onBatch = { [buffer = f.buffer] in
            // A reset mid-request: the old events go, one is recorded under the new id.
            buffer.eraseAll()
            buffer.append(Self.envelope(install: newInstall, count: 9))
            return .accepted
        }
        // Only one batch may go out, or the new event would be legitimately sent too.
        f.transport.afterBatch = { [consent = f.consent] in consent.decline() }
        await f.uploader.drainIfDue()
        XCTAssertEqual(f.transport.batches.count, 1)
        XCTAssertEqual(f.buffer.events.map(\.install), [newInstall])
        XCTAssertGreaterThan(f.bufferChanges.count, 0)
    }

    func testClientErrorDropsBatch() async {
        let f = fixture()
        f.fill(3)
        f.transport.batchResult = .rejected
        await f.uploader.drainIfDue()
        XCTAssertTrue(f.buffer.events.isEmpty)
        XCTAssertEqual(f.transport.batches.count, 1)
    }

    func testServerErrorAndOfflineKeepEventsAndBackOff() async {
        let f = fixture()
        f.fill(1)
        f.transport.batchResult = .retry
        let minute: TimeInterval = 60
        let waits: [TimeInterval] = [15, 30, 60, 120, 240, 480, 960, 1440, 1440].map { $0 * minute }
        await f.uploader.drainIfDue()
        XCTAssertEqual(f.transport.batches.count, 1)
        for (index, wait) in waits.enumerated() {
            f.clock.advance(wait - 1)
            await f.uploader.drainIfDue()
            XCTAssertEqual(f.transport.batches.count, index + 1, "sent before wait \(index) ended")
            f.clock.advance(1)
            await f.uploader.drainIfDue()
            XCTAssertEqual(f.transport.batches.count, index + 2, "not sent after wait \(index)")
        }
        XCTAssertEqual(f.buffer.events.count, 1)

        // A success resets the backoff to 15 minutes.
        f.clock.advance(1440 * minute)
        f.transport.batchResult = .accepted
        await f.uploader.drainIfDue()
        XCTAssertTrue(f.buffer.events.isEmpty)
        f.fill(1)
        f.transport.batchResult = .retry
        f.clock.advance(15 * minute)
        await f.uploader.drainIfDue()
        let sent = f.transport.batches.count
        f.clock.advance(15 * minute)
        await f.uploader.drainIfDue()
        XCTAssertEqual(f.transport.batches.count, sent + 1)
    }

    func testDrainIsThrottledToFifteenMinutes() async {
        let f = fixture()
        f.fill(1)
        await f.uploader.drainIfDue()
        XCTAssertEqual(f.transport.batches.count, 1)
        f.fill(1)
        f.clock.advance(15 * 60 - 1)
        await f.makeUploader().drainIfDue()
        XCTAssertEqual(f.transport.batches.count, 1)
        f.clock.advance(1)
        await f.makeUploader().drainIfDue()
        XCTAssertEqual(f.transport.batches.count, 2)
    }

    func testBatchesHoldAtMost100Events() async throws {
        let f = fixture()
        f.fill(250)
        await f.uploader.drainIfDue()
        let bodies = try f.transport.batches.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(bodies.map { ($0["events"] as? [Any])?.count }, [100, 100, 50])
        for body in bodies {
            XCTAssertEqual(Set(body.keys), ["v", "events"])
            XCTAssertEqual(body["v"] as? Int, 1)
        }
        let counts = bodies.flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["count"] as? Int } }
        XCTAssertEqual(counts, Array(1...250))
        XCTAssertTrue(f.buffer.events.isEmpty)
    }

    func testConsentRevokedMidDrainStopsFurtherBatches() async {
        let f = fixture()
        f.fill(250)
        f.transport.afterBatch = { [consent = f.consent] in consent.decline() }
        await f.uploader.drainIfDue()
        XCTAssertEqual(f.transport.batches.count, 1)
    }

    func testNothingIsSentWithoutConsent() async {
        let f = fixture()
        f.fill(1)
        f.consent.decline()
        await f.uploader.drainIfDue()
        XCTAssertTrue(f.transport.batches.isEmpty)
        XCTAssertEqual(f.buffer.events.count, 1)
    }

    /// Amendment 4: only a 2xx settles an erasure.
    func testQueuedDeleteIsKeptUntilAccepted() async {
        let f = fixture()
        let id = UUID()
        let other = UUID()
        f.buffer.queueDelete(id, at: f.clock.now)
        f.buffer.queueDelete(other, at: f.clock.now)
        for result in [AnalyticsUploadResult.retry, .rejected] {
            f.transport.deleteResult = result
            await f.uploader.drainIfDue()
            XCTAssertEqual(f.buffer.pendingDeletes.map(\.install), [id, other], "\(result)")
        }
        XCTAssertEqual(f.transport.deletes, [id, other, id, other])
        f.transport.deleteResult = .accepted
        await f.uploader.drainIfDue()
        XCTAssertTrue(f.buffer.pendingDeletes.isEmpty)
        XCTAssertTrue(AnalyticsEventBuffer(directory: f.buffer.directoryURL).pendingDeletes.isEmpty)
    }

    func testOldQueuedDeleteIsStillSent() async {
        let f = fixture()
        let id = UUID()
        f.buffer.queueDelete(id, at: f.clock.now)
        f.clock.advance(400 * 24 * 60 * 60)
        await f.uploader.drainIfDue()
        XCTAssertEqual(f.transport.deletes, [id])
        XCTAssertTrue(f.buffer.pendingDeletes.isEmpty)
    }

    func testPendingDeletesSurviveEraseAndRelaunch() {
        let f = fixture()
        let id = UUID()
        f.buffer.queueDelete(id, at: f.clock.now)
        f.buffer.eraseAll()
        XCTAssertEqual(f.buffer.pendingDeletes.map(\.install), [id])
        XCTAssertEqual(AnalyticsEventBuffer(directory: f.buffer.directoryURL).pendingDeletes.map(\.install), [id])
    }

    /// Through the real composition: turning analytics off sends the delete at once, inside the
    /// batch throttle, with no drain asked for.
    func testDeleteIsSentWhenQueued() async throws {
        let transport = StubAnalyticsTransport()
        let composition = AppComposition(
            defaults: makeTestDefaults("analytics-uploader"),
            directory: makeTestDirectory("analytics-uploader"), analyticsTransport: transport)
        composition.analyticsConsent.accept()
        let id = try XCTUnwrap(composition.analytics.installID)
        await composition.analyticsUploader?.drainIfDue()
        XCTAssertEqual(transport.batches.count, 1)
        let sent = expectation(description: "delete sent")
        transport.afterDelete = { sent.fulfill() }
        composition.analyticsConsent.decline()
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(transport.deletes, [id])
        XCTAssertNil(composition.analytics.installID)
    }

    /// A delete queued while a batch is in flight goes after it, so the batch can't re-create rows.
    func testDeleteWaitsForTheBatchInFlight() async {
        let f = fixture()
        f.fill(1)
        let id = UUID()
        let gate = AsyncStream<Void>.makeStream()
        let started = expectation(description: "batch started")
        f.transport.beforeBatch = {
            started.fulfill()
            for await _ in gate.stream { break }
        }
        let drain = Task { await f.uploader.drainIfDue() }
        await fulfillment(of: [started], timeout: 5)
        f.buffer.queueDelete(id, at: f.clock.now)
        let delete = Task { await f.uploader.sendPendingDeletes() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(f.transport.deletes.isEmpty)
        gate.continuation.yield()
        await drain.value
        await delete.value
        XCTAssertEqual(f.transport.deletes, [id])
    }

    func testUITestLaunchUsesNoOpTransport() {
        func make(_ host: String?, _ arguments: [String] = [], debug: Bool = false) -> URLSessionAnalyticsTransport? {
            AnalyticsTransportSelection.make(host: host, arguments: arguments, isDebug: debug)
        }
        XCTAssertNotNil(make("analytics.example.test"))
        XCTAssertNotNil(make("analytics.example.test", ["-analytics-debug-uploads"], debug: true))
        XCTAssertNil(make("analytics.example.test", debug: true))
        XCTAssertNil(make("analytics.example.test", ["-uitest-zero-sources"]))
        XCTAssertNil(make("analytics.example.test", ["-analytics-debug-uploads", "-uitest-x"], debug: true))
        for host in [nil, "", "  ", "$(ANALYTICS_HOST)", "https://a.test", "a.test/path", "user@a.test"] {
            XCTAssertNil(make(host), host ?? "nil")
        }
    }

    func testPrivacyPolicyURL() {
        XCTAssertEqual(AnalyticsSettingsSection.privacyPolicyURL.absoluteString,
                       "https://eliasmagdaleno.github.io/MangaCarta/privacy/")
    }

    private static func envelope(install: UUID, count: Int) -> AnalyticsEnvelope {
        AnalyticsEnvelope(install: install, date: Date(timeIntervalSince1970: 1_800_000_000), app: "test",
                          event: .forYouShown(count: count))
    }

    @MainActor
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    @MainActor
    private final class Changes { var count = 0 }

    @MainActor
    private struct Fixture {
        let buffer: AnalyticsEventBuffer
        let consent: AnalyticsConsentStore
        let transport: StubAnalyticsTransport
        let clock: Clock
        let bufferChanges: Changes
        let makeUploader: () -> AnalyticsUploader
        let uploader: AnalyticsUploader
        let install = UUID()

        func fill(_ count: Int) {
            for index in 1...count { buffer.append(AnalyticsUploaderTests.envelope(install: install, count: index)) }
        }
    }

    private func fixture() -> Fixture {
        let defaults = makeTestDefaults("analytics-uploader")
        let buffer = AnalyticsEventBuffer(directory: makeTestDirectory("analytics-uploader"))
        let consent = AnalyticsConsentStore(defaults: defaults)
        consent.accept()
        let transport = StubAnalyticsTransport()
        let clock = Clock()
        let changes = Changes()
        let make = {
            AnalyticsUploader(buffer: buffer, consent: consent, transport: transport, defaults: defaults,
                              now: { clock.now }, bufferChanged: { changes.count += 1 })
        }
        return Fixture(buffer: buffer, consent: consent, transport: transport, clock: clock,
                       bufferChanges: changes, makeUploader: make, uploader: make())
    }
}

@MainActor
final class StubAnalyticsTransport: AnalyticsTransport {
    var batches: [Data] = []
    var deletes: [UUID] = []
    var batchResult = AnalyticsUploadResult.accepted
    var deleteResult = AnalyticsUploadResult.accepted
    var beforeBatch: (() async -> Void)?
    var onBatch: (() -> AnalyticsUploadResult)?
    var afterBatch: (() -> Void)?
    var afterDelete: (() -> Void)?

    func sendBatch(_ body: Data) async -> AnalyticsUploadResult {
        batches.append(body)
        await beforeBatch?()
        let result = onBatch?() ?? batchResult
        afterBatch?()
        return result
    }

    func deleteInstall(_ id: UUID) async -> AnalyticsUploadResult {
        deletes.append(id)
        afterDelete?()
        return deleteResult
    }
}

@MainActor
final class URLSessionAnalyticsTransportTests: XCTestCase {
    func testRequestShapesAndStatusMapping() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsStubProtocol.self]
        let cookies = try XCTUnwrap(configuration.httpCookieStorage)
        cookies.setCookie(try XCTUnwrap(HTTPCookie(properties: [
            .domain: "analytics.example.test", .path: "/", .name: "track", .value: "1"
        ])))
        defer { AnalyticsStubProtocol.reset() }
        let transport = URLSessionAnalyticsTransport(host: "analytics.example.test", configuration: configuration)

        let expected: [(Int?, AnalyticsUploadResult)] = [
            (200, .accepted), (204, .accepted), (400, .rejected), (404, .rejected), (413, .rejected),
            (408, .retry), (429, .retry), (500, .retry), (503, .retry), (nil, .retry)
        ]
        let id = UUID()
        for (status, result) in expected {
            AnalyticsStubProtocol.respond(with: status)
            let batch = await transport.sendBatch(Data("{}".utf8))
            XCTAssertEqual(batch, result, "POST \(String(describing: status))")
            let delete = await transport.deleteInstall(id)
            XCTAssertEqual(delete, result, "DELETE \(String(describing: status))")
        }

        let requests = AnalyticsStubProtocol.requests
        let post = try XCTUnwrap(requests.first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.absoluteString, "https://analytics.example.test/v1/events")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let delete = try XCTUnwrap(requests.dropFirst().first)
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(delete.url?.absoluteString, "https://analytics.example.test/v1/installs/\(id.uuidString)")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }
}

private final class AnalyticsStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status: Int?
    private static var seen: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { seen } }
    static func respond(with newStatus: Int?) { lock.withLock { status = newStatus } }
    static func reset() { lock.withLock { status = nil; seen = [] } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let status = Self.lock.withLock { () -> Int? in
            Self.seen.append(request)
            return Self.status
        }
        guard let status, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
