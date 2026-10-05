import Foundation
import Testing
@testable import MangaCarta

// MARK: - Test doubles

/// A scripted transport. Each `send` pops the next scripted step, so a test states exactly
/// what the network does and how many times it was asked.
private actor ScriptedTokenTransport: MALHTTPTransport {
    enum Step {
        case response(status: Int, body: String)
        case failure(any Error)
        case hang
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var callCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let step = steps.isEmpty ? Step.failure(URLError(.badServerResponse)) : steps.removeFirst()
        switch step {
        case let .response(status, body):
            // A short hop so concurrent callers genuinely overlap rather than resolving inline.
            try await Task.sleep(nanoseconds: 20_000_000)
            let response = HTTPURLResponse(url: MALTokenRequest.endpoint,
                                           statusCode: status,
                                           httpVersion: nil,
                                           headerFields: nil)!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        case .hang:
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw URLError(.timedOut)
        }
    }
}

private func tokenBody(access: String, refresh: String, expiresIn: Int) -> String {
    """
    {"token_type":"Bearer","expires_in":\(expiresIn),\
    "access_token":"\(access)","refresh_token":"\(refresh)"}
    """
}

private let testConfiguration = MALOAuthConfiguration(
    clientID: "test-client",
    redirectURI: "mangareader://oauth/mal"
)

// MARK: - Client

@Suite("MAL token client")
struct MALTokenClientTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("A successful exchange carries the tokens and an expiry computed from the clock")
    func successfulExchange() async throws {
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: 3600))
        ])
        let client = makeClient(transport: transport)

        let credential = try await client.fetch(.refresh(refreshToken: "r0"))

        #expect(credential.accessToken == "a1")
        #expect(credential.refreshToken == "r1")
        #expect(credential.tokenType == "Bearer")
        #expect(credential.expiresAt == now.addingTimeInterval(3600))
    }

    @Test("A non-positive expiry is rejected rather than stored as already dead")
    func nonPositiveExpiry() async {
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: -1))
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: MALTokenError.invalidExpiry) {
            try await client.fetch(.refresh(refreshToken: "r0"))
        }
    }

    @Test("A response missing the replacement refresh token is malformed")
    func missingReplacementField() async {
        let body = #"{"token_type":"Bearer","expires_in":3600,"access_token":"a1"}"#
        let transport = ScriptedTokenTransport(steps: [.response(status: 200, body: body)])
        let client = makeClient(transport: transport)

        await #expect(throws: MALTokenError.malformedResponse) {
            try await client.fetch(.refresh(refreshToken: "r0"))
        }
    }

    @Test("A server error body names the OAuth error code")
    func serverErrorBody() async {
        let body = #"{"error":"invalid_grant","message":"bad refresh token"}"#
        let transport = ScriptedTokenTransport(steps: [.response(status: 400, body: body)])
        let client = makeClient(transport: transport)

        await #expect(throws: MALTokenError.server(status: 400, code: "invalid_grant")) {
            try await client.fetch(.refresh(refreshToken: "r0"))
        }
    }

    @Test("Transport errors surface as a transport failure, not as a malformed response")
    func transportError() async {
        let transport = ScriptedTokenTransport(steps: [.failure(URLError(.notConnectedToInternet))])
        let client = makeClient(transport: transport)

        await #expect(throws: MALTokenError.transportFailure) {
            try await client.fetch(.refresh(refreshToken: "r0"))
        }
    }

    @Test("Cancellation cancels the fetch instead of yielding a token")
    func cancellation() async throws {
        let transport = ScriptedTokenTransport(steps: [.hang])
        let client = makeClient(transport: transport)

        let task = Task { try await client.fetch(.refresh(refreshToken: "r0")) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let result = await task.result
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test("Error presentation never contains a token")
    func errorPresentationIsRedacted() {
        let errors: [MALTokenError] = [.invalidExpiry, .malformedResponse, .transportFailure,
                                       .server(status: 400, code: "invalid_grant"), .signedOut]
        for error in errors {
            #expect(error.localizedDescription.contains("secret") == false)
        }
    }

    private func makeClient(transport: ScriptedTokenTransport) -> MALTokenClient {
        MALTokenClient(configuration: testConfiguration, transport: transport, now: { self.now })
    }
}

// MARK: - Manager

@Suite("MAL token manager")
struct MALTokenManagerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("A comfortably valid token is returned without touching the network")
    func noRefreshWhileValid() async throws {
        let transport = ScriptedTokenTransport(steps: [])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 3600, from: now))
        let manager = makeManager(transport: transport, store: store)

        #expect(try await manager.accessToken() == "a0")
        #expect(await transport.callCount == 0)
    }

    @Test("A token near expiry is refreshed proactively and the new one is persisted")
    func proactiveRefresh() async throws {
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: 3600))
        ])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store)

        #expect(try await manager.accessToken() == "a1")
        #expect(await transport.callCount == 1)

        let saved = try #require(try store.load())
        #expect(saved.accessToken == "a1")
        #expect(saved.refreshToken == "r1")
        #expect(saved.malUserID == 42)
        #expect(saved.expiresAt == now.addingTimeInterval(3600))
    }

    @Test("The retired access token is never handed out again")
    func oldAccessTokenRetirement() async throws {
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: 3600))
        ])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store)

        _ = try await manager.accessToken()
        #expect(try await manager.accessToken() == "a1")
        #expect(await transport.callCount == 1)
    }

    @Test("Concurrent callers share one refresh and receive the same token")
    func singleFlightRefresh() async throws {
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: 3600))
        ])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await manager.accessToken() }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        #expect(tokens == Array(repeating: "a1", count: 10))
        #expect(await transport.callCount == 1)
    }

    @Test("A refresh whose persistence fails keeps the previous record and fails")
    func persistenceFailureKeepsPriorRecord() async throws {
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: 3600))
        ])
        let dataStore = MALInMemoryCredentialDataStore()
        let store = makeStore(dataStore: dataStore)
        let original = credential(access: "a0", refresh: "r0", expiresIn: 60, from: now)
        try store.save(original)
        dataStore.failure = (.replace, MALCredentialStoreError.keychainFailure(status: -36))
        let manager = makeManager(transport: transport, store: store)

        await #expect(throws: (any Error).self) { try await manager.accessToken() }

        dataStore.failure = nil
        #expect(try store.load() == original)
    }

    @Test("A permanently rejected refresh signs the account out")
    func permanentRefreshFailure() async throws {
        let body = #"{"error":"invalid_grant"}"#
        let transport = ScriptedTokenTransport(steps: [.response(status: 400, body: body)])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store)

        await #expect(throws: MALTokenError.server(status: 400, code: "invalid_grant")) {
            try await manager.accessToken()
        }
        #expect(try store.load() == nil)
        await #expect(throws: MALTokenError.signedOut) { try await manager.accessToken() }
    }

    @Test("Invalidation reloads a credential adopted by another owner")
    func invalidationReloadsCredential() async throws {
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 3600, from: now))
        let manager = makeManager(transport: ScriptedTokenTransport(steps: []), store: store)

        #expect(try await manager.accessToken() == "a0")
        try store.save(credential(access: "b0", refresh: "s0", expiresIn: 3600, from: now))
        await manager.invalidate()

        #expect(try await manager.accessToken() == "b0")
    }

    @Test("Invalidation after permanent refresh failure permits a new credential")
    func invalidationAfterPermanentFailureReloadsCredential() async throws {
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 400, body: #"{"error":"invalid_grant"}"#)
        ])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store)

        await #expect(throws: MALTokenError.server(status: 400, code: "invalid_grant")) {
            try await manager.accessToken()
        }
        try store.save(credential(access: "b0", refresh: "s0", expiresIn: 3600, from: now))
        await manager.invalidate()

        #expect(try await manager.accessToken() == "b0")
    }

    @Test("Invalidation drops the cached credential")
    func invalidationSignsOut() async throws {
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 3600, from: now))
        let manager = makeManager(transport: ScriptedTokenTransport(steps: []), store: store)

        _ = try await manager.accessToken()
        try store.delete()
        await manager.invalidate()

        await #expect(throws: MALTokenError.signedOut) { try await manager.accessToken() }
    }

    @Test("An invalidated refresh cannot publish its old credential")
    func invalidatedRefreshCannotPublish() async throws {
        let transport = ScriptedTokenTransport(steps: [.hang])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store)

        let oldRefresh = Task { try await manager.accessToken() }
        while await transport.callCount == 0 {
            await Task.yield()
        }
        await manager.invalidate()
        try store.save(credential(access: "b0", refresh: "s0", expiresIn: 3600, from: now))
        _ = await oldRefresh.result

        #expect(try await manager.accessToken() == "b0")
    }

    @Test("With nothing stored the manager reports signed out")
    func signedOut() async throws {
        let manager = makeManager(transport: ScriptedTokenTransport(steps: []), store: makeStore())

        await #expect(throws: MALTokenError.signedOut) { try await manager.accessToken() }
    }

    // MARK: Helpers

    private func credential(
        access: String,
        refresh: String,
        expiresIn: TimeInterval,
        from date: Date
    ) -> MALStoredCredential {
        MALStoredCredential(tokenType: "Bearer",
                            accessToken: access,
                            refreshToken: refresh,
                            expiresAt: date.addingTimeInterval(expiresIn),
                            malUserID: 42)
    }

    private func makeStore(
        dataStore: MALInMemoryCredentialDataStore = MALInMemoryCredentialDataStore()
    ) -> MALCredentialStore {
        MALCredentialStore(dataStore: dataStore,
                           markerStore: MALInMemoryInstallationMarkerStore(marker: "installation-1")
        ) { "installation-1" }
    }

    private func makeManager(
        transport: ScriptedTokenTransport,
        store: MALCredentialStore,
        refreshDidChange: @escaping @Sendable (Bool) -> Void = { _ in }
    ) -> MALTokenManager {
        MALTokenManager(
            client: MALTokenClient(configuration: testConfiguration,
                                   transport: transport,
                                   now: { self.now }),
            store: store,
            now: { self.now },
            refreshDidChange: refreshDidChange
        )
    }
}

// MARK: - What the account section is told about a refresh

/// The spinner in Settings is driven by these notifications, so what matters is that each
/// real token request produces exactly one `true`/`false` pair — a burst must not stack
/// spinners, and a failed refresh must still clear one.
@Suite("MAL token refresh notifications")
struct MALTokenRefreshNotificationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Ordered, and safe to read from the test after the manager has finished with it.
    private actor Recorder {
        private(set) var events: [Bool] = []
        func record(_ value: Bool) { events.append(value) }
    }

    @Test("A refresh announces its start and its finish, in that order")
    func announcesRefresh() async throws {
        let recorder = Recorder()
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: 3600))
        ])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store, refreshDidChange: { value in
            Task { await recorder.record(value) }
        })

        _ = try await manager.accessToken()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await recorder.events == [true, false])
    }

    @Test("A burst of callers sharing one refresh announces it once")
    func burstAnnouncesOnce() async throws {
        let recorder = Recorder()
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 200, body: tokenBody(access: "a1", refresh: "r1", expiresIn: 3600))
        ])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store, refreshDidChange: { value in
            Task { await recorder.record(value) }
        })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try await manager.accessToken() }
            }
            try await group.waitForAll()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await recorder.events == [true, false])
    }

    @Test("A refresh that fails still announces its finish")
    func failedRefreshStillFinishes() async throws {
        let recorder = Recorder()
        let transport = ScriptedTokenTransport(steps: [
            .response(status: 400, body: #"{"error":"invalid_grant"}"#)
        ])
        let store = makeStore()
        try store.save(credential(access: "a0", refresh: "r0", expiresIn: 60, from: now))
        let manager = makeManager(transport: transport, store: store, refreshDidChange: { value in
            Task { await recorder.record(value) }
        })

        await #expect(throws: (any Error).self) { _ = try await manager.accessToken() }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await recorder.events == [true, false])
    }

    private func credential(
        access: String,
        refresh: String,
        expiresIn: TimeInterval,
        from date: Date
    ) -> MALStoredCredential {
        MALStoredCredential(tokenType: "Bearer",
                            accessToken: access,
                            refreshToken: refresh,
                            expiresAt: date.addingTimeInterval(expiresIn),
                            malUserID: 42)
    }

    private func makeStore() -> MALCredentialStore {
        MALCredentialStore(dataStore: MALInMemoryCredentialDataStore(),
                           markerStore: MALInMemoryInstallationMarkerStore(marker: "installation-1")
        ) { "installation-1" }
    }

    private func makeManager(
        transport: ScriptedTokenTransport,
        store: MALCredentialStore,
        refreshDidChange: @escaping @Sendable (Bool) -> Void
    ) -> MALTokenManager {
        MALTokenManager(
            client: MALTokenClient(configuration: testConfiguration,
                                   transport: transport,
                                   now: { self.now }),
            store: store,
            now: { self.now },
            refreshDidChange: refreshDidChange
        )
    }
}
