import Foundation
import Testing
@testable import MangaCarta

// MARK: - Test doubles

/// A scripted HTTP transport that records every request, so a test can assert on the verb,
/// the headers, and the exact body that went out.
private actor ScriptedAPITransport: MALHTTPTransport {
    enum Step {
        case response(status: Int, body: String, headers: [String: String] = [:])
        case failure(any Error)
        case hang
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var callCount: Int { requests.count }

    func request(at index: Int) -> URLRequest { requests[index] }

    func body(at index: Int) -> String {
        String(bytes: requests[index].httpBody ?? Data(), encoding: .utf8) ?? ""
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case let .response(status, body, headers):
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: status,
                                           httpVersion: nil,
                                           headerFields: headers)!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        case .hang:
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw URLError(.timedOut)
        }
    }
}

/// Answers by the token a request carries rather than by arrival order: 401 for `a0`, 200 for
/// anything else. A script in arrival order breaks when one caller refreshes and retries before
/// another has sent at all — the retry then draws the other caller's scripted 401.
private actor TokenAwareAPITransport: MALHTTPTransport {
    private(set) var staleRequestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isStale = request.value(forHTTPHeaderField: "Authorization") == "Bearer a0"
        if isStale { staleRequestCount += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: isStale ? 401 : 200,
                                       httpVersion: nil, headerFields: nil)!
        let body = isStale ? #"{"error":"invalid_token"}"# : #"{"status":"reading","num_chapters_read":1}"#
        return (Data(body.utf8), response)
    }
}

/// A token endpoint that holds its answer until `gate` returns, so a test can make every
/// caller's 401 land while the one refresh is still in flight.
private actor GatedTokenTransport: MALHTTPTransport {
    private let gate: @Sendable () async throws -> Void
    private(set) var callCount = 0

    init(gate: @escaping @Sendable () async throws -> Void) {
        self.gate = gate
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        try await gate()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(refreshedTokenBody.utf8), response)
    }
}

private let apiConfiguration = MALOAuthConfiguration(
    clientID: "test-client",
    redirectURI: "mangareader://oauth/mal"
)

private let apiNow = Date(timeIntervalSince1970: 1_000_000)

private func storedCredential(access: String, expiresIn: TimeInterval) -> MALStoredCredential {
    MALStoredCredential(tokenType: "Bearer",
                        accessToken: access,
                        refreshToken: "r0",
                        expiresAt: apiNow.addingTimeInterval(expiresIn),
                        malUserID: 42)
}

/// A manager holding a comfortably valid `a0`, whose refresh (if one happens) yields `a1`.
private func makeTokenManager(
    tokenTransport: any MALHTTPTransport,
    credential: MALStoredCredential = storedCredential(access: "a0", expiresIn: 3600)
) throws -> MALTokenManager {
    let store = MALCredentialStore(
        dataStore: MALInMemoryCredentialDataStore(),
        markerStore: MALInMemoryInstallationMarkerStore(marker: "installation-1")
    ) { "installation-1" }
    try store.save(credential)
    return MALTokenManager(
        client: MALTokenClient(configuration: apiConfiguration,
                               transport: tokenTransport,
                               now: { apiNow }),
        store: store,
        now: { apiNow }
    )
}

private func makeClient(
    transport: ScriptedAPITransport,
    tokens: MALTokenManager,
    updateVerb: MALListUpdateVerb = .patch
) -> MALAuthenticatedClient {
    MALAuthenticatedClient(tokens: tokens, transport: transport, updateVerb: updateVerb)
}

private let refreshedTokenBody = """
{"token_type":"Bearer","expires_in":3600,"access_token":"a1","refresh_token":"r1"}
"""

// MARK: - Reads

@Suite("MAL authenticated client reads")
struct MALAuthenticatedClientReadTests {
    @Test("The current user request carries a bearer token and asks for minimal fields")
    func currentUserRequest() async throws {
        let body = #"{"id":42,"name":"elias","picture":"https://cdn.myanimelist.net/u.jpg"}"#
        let transport = ScriptedAPITransport(steps: [.response(status: 200, body: body)])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        let identity = try await client.currentUser()

        #expect(identity == MALUserIdentity(id: 42,
                                            name: "elias",
                                            pictureURL: URL(string: "https://cdn.myanimelist.net/u.jpg")))
        let request = await transport.request(at: 0)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a0")
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://api.myanimelist.net/v2/users/@me"))
        #expect(url.contains("fields=name,picture"))
    }

    @Test("A missing or unusable picture leaves the identity without one")
    func defensivePictureHandling() async throws {
        for pictureJSON in [#""picture":"""#, #""picture":null"#, #""picture":"not a url""#, ""] {
            let fields = ["\"id\":42", "\"name\":\"elias\"", pictureJSON]
                .filter { !$0.isEmpty }
                .joined(separator: ",")
            let transport = ScriptedAPITransport(steps: [.response(status: 200, body: "{\(fields)}")])
            let client = makeClient(transport: transport, tokens: try makeTokenManager(
                tokenTransport: ScriptedAPITransport(steps: [])))

            let identity = try await client.currentUser()

            #expect(identity.id == 42)
            #expect(identity.name == "elias")
            #expect(identity.pictureURL == nil)
        }
    }

    @Test("A list status decodes MAL's snake-cased fields")
    func listStatusDecoding() async throws {
        let body = """
        {"id":7,"my_list_status":{"status":"reading","num_chapters_read":12,\
        "num_volumes_read":1,"is_rereading":false,"updated_at":"2026-08-21T00:00:00+00:00"}}
        """
        let transport = ScriptedAPITransport(steps: [.response(status: 200, body: body)])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        let status = try await client.listStatus(mangaID: 7)

        #expect(status == MALListStatus(status: "reading", numChaptersRead: 12))
        let url = try #require(await transport.request(at: 0).url?.absoluteString)
        #expect(url.hasPrefix("https://api.myanimelist.net/v2/manga/7"))
        #expect(url.contains("fields=my_list_status"))
    }

    @Test("A title absent from the list reads as no status rather than an error")
    func absentListStatus() async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: 200, body: #"{"id":7}"#)])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        #expect(try await client.listStatus(mangaID: 7) == nil)
    }
}

// MARK: - Updates

@Suite("MAL authenticated client updates")
struct MALAuthenticatedClientUpdateTests {
    private let updatedBody = #"{"status":"reading","num_chapters_read":12}"#

    @Test("A progress-only update sends just that field, form encoded")
    func minimalUpdateBody() async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: 200, body: updatedBody)])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        let status = try await client.updateProgress(mangaID: 7,
                                                     update: .init(numChaptersRead: 12))

        #expect(status == MALListStatus(status: "reading", numChaptersRead: 12))
        let request = await transport.request(at: 0)
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a0")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(await transport.body(at: 0) == "num_chapters_read=12")
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://api.myanimelist.net/v2/manga/7/my_list_status")
    }

    @Test("Adding a title sends the status alongside the progress")
    func addingTitleSendsStatus() async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: 200, body: updatedBody)])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        _ = try await client.updateProgress(
            mangaID: 7,
            update: .init(status: "reading", numChaptersRead: 12)
        )

        #expect(await transport.body(at: 0) == "status=reading&num_chapters_read=12")
    }

    @Test("The update verb is configurable, because MAL's reference contradicts itself")
    func configurableUpdateVerb() async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: 200, body: updatedBody)])
        let client = makeClient(transport: transport,
                                tokens: try makeTokenManager(
                                    tokenTransport: ScriptedAPITransport(steps: [])),
                                updateVerb: .put)

        _ = try await client.updateProgress(mangaID: 7, update: .init(numChaptersRead: 12))

        #expect(await transport.request(at: 0).httpMethod == "PUT")
    }
}

// MARK: - Authorization

@Suite("MAL authenticated client authorization")
struct MALAuthenticatedClientAuthorizationTests {
    @Test("One 401 refreshes the token and retries the request once")
    func refreshAndRetryAfter401() async throws {
        let transport = ScriptedAPITransport(steps: [
            .response(status: 401, body: #"{"error":"invalid_token"}"#),
            .response(status: 200, body: #"{"status":"reading","num_chapters_read":12}"#)
        ])
        let tokenTransport = ScriptedAPITransport(steps: [
            .response(status: 200, body: refreshedTokenBody)
        ])
        let client = makeClient(transport: transport,
                                tokens: try makeTokenManager(tokenTransport: tokenTransport))

        let status = try await client.updateProgress(mangaID: 7,
                                                     update: .init(numChaptersRead: 12))

        #expect(status.numChaptersRead == 12)
        #expect(await transport.callCount == 2)
        #expect(await tokenTransport.callCount == 1)
        #expect(await transport.request(at: 0).value(forHTTPHeaderField: "Authorization") == "Bearer a0")
        #expect(await transport.request(at: 1).value(forHTTPHeaderField: "Authorization") == "Bearer a1")
    }

    @Test("Concurrent 401s share one refresh rather than one refresh each")
    func concurrent401sJoinOneRefresh() async throws {
        let transport = TokenAwareAPITransport()
        // The refresh answers only once both callers' `a0` requests have come back 401, so the
        // second caller always meets the refresh in flight. The deadline turns a regression
        // that never sends the second request into a failure rather than a hung run.
        let tokenTransport = GatedTokenTransport {
            let deadline = ContinuousClock.now + .seconds(5)
            while await transport.staleRequestCount < 2 {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let tokens = try makeTokenManager(tokenTransport: tokenTransport)
        let client = MALAuthenticatedClient(tokens: tokens, transport: transport, updateVerb: .patch)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in [7, 8] {
                group.addTask {
                    _ = try await client.updateProgress(mangaID: id,
                                                        update: .init(numChaptersRead: 1))
                }
            }
            try await group.waitForAll()
        }

        #expect(await transport.staleRequestCount == 2)
        #expect(await tokenTransport.callCount == 1)
    }

    @Test("A second 401 after the retry requires reauthorization")
    func secondUnauthorizedRequiresReauthorization() async throws {
        let transport = ScriptedAPITransport(steps: [
            .response(status: 401, body: #"{"error":"invalid_token"}"#),
            .response(status: 401, body: #"{"error":"invalid_token"}"#)
        ])
        let tokenTransport = ScriptedAPITransport(steps: [
            .response(status: 200, body: refreshedTokenBody)
        ])
        let client = makeClient(transport: transport,
                                tokens: try makeTokenManager(tokenTransport: tokenTransport))

        await #expect(throws: MALRequestFailure.reauthorizationRequired) {
            try await client.listStatus(mangaID: 7)
        }
        #expect(await transport.callCount == 2)
    }

    @Test("A refresh that itself fails requires reauthorization without a retry")
    func failedRefreshRequiresReauthorization() async throws {
        let transport = ScriptedAPITransport(steps: [
            .response(status: 401, body: #"{"error":"invalid_token"}"#)
        ])
        let tokenTransport = ScriptedAPITransport(steps: [
            .response(status: 400, body: #"{"error":"invalid_grant"}"#)
        ])
        let client = makeClient(transport: transport,
                                tokens: try makeTokenManager(tokenTransport: tokenTransport))

        await #expect(throws: MALRequestFailure.reauthorizationRequired) {
            try await client.listStatus(mangaID: 7)
        }
        #expect(await transport.callCount == 1)
    }

    @Test("A signed-out manager fails the request without reaching the network")
    func signedOutBeforeRequest() async throws {
        let store = MALCredentialStore(
            dataStore: MALInMemoryCredentialDataStore(),
            markerStore: MALInMemoryInstallationMarkerStore(marker: "installation-1")
        ) { "installation-1" }
        let tokens = MALTokenManager(
            client: MALTokenClient(configuration: apiConfiguration,
                                   transport: ScriptedAPITransport(steps: []),
                                   now: { apiNow }),
            store: store,
            now: { apiNow }
        )
        let transport = ScriptedAPITransport(steps: [])
        let client = makeClient(transport: transport, tokens: tokens)

        await #expect(throws: MALRequestFailure.reauthorizationRequired) {
            try await client.listStatus(mangaID: 7)
        }
        #expect(await transport.callCount == 0)
    }
}

// MARK: - Failure classification

@Suite("MAL authenticated client failure classification")
struct MALAuthenticatedClientFailureTests {
    @Test("Offline and timeout errors are transient with no server-supplied delay",
          arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost])
    func networkFailuresAreTransient(code: URLError.Code) async throws {
        let transport = ScriptedAPITransport(steps: [.failure(URLError(code))])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        await #expect(throws: MALRequestFailure.transient(retryAfter: nil)) {
            try await client.listStatus(mangaID: 7)
        }
    }

    @Test("Retryable statuses are transient", arguments: [408, 429, 500, 502, 503])
    func retryableStatusesAreTransient(status: Int) async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: status, body: "{}")])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        await #expect(throws: MALRequestFailure.transient(retryAfter: nil)) {
            try await client.listStatus(mangaID: 7)
        }
    }

    @Test("A valid Retry-After is carried; anything else is ignored",
          arguments: [("120", 120.0), ("0", nil), ("-5", nil), ("soon", nil), ("", nil)] as [(String, Double?)])
    func retryAfterParsing(header: String, expected: Double?) async throws {
        let transport = ScriptedAPITransport(steps: [
            .response(status: 429, body: "{}", headers: ["Retry-After": header])
        ])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        await #expect(throws: MALRequestFailure.transient(retryAfter: expected)) {
            try await client.listStatus(mangaID: 7)
        }
    }

    @Test("400 and 404 are permanent for that title", arguments: [400, 404])
    func permanentItemFailures(status: Int) async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: status, body: "{}")])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        await #expect(throws: MALRequestFailure.permanentItem(status: status)) {
            try await client.listStatus(mangaID: 7)
        }
    }

    @Test("403 blocks the account rather than the item")
    func forbiddenBlocksAccount() async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: 403, body: "{}")])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        await #expect(throws: MALRequestFailure.accountBlocked) {
            try await client.listStatus(mangaID: 7)
        }
    }

    @Test("An undocumented status is unknown, not silently retried as transient")
    func undocumentedStatusIsUnknown() async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: 418, body: "{}")])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        await #expect(throws: MALRequestFailure.unknown(status: 418)) {
            try await client.listStatus(mangaID: 7)
        }
    }

    @Test("A body that does not decode is unknown, whatever the server said")
    func decodingFailureIsUnknown() async throws {
        let transport = ScriptedAPITransport(steps: [.response(status: 200, body: "not json")])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        await #expect(throws: MALRequestFailure.unknown(status: 200)) {
            try await client.listStatus(mangaID: 7)
        }
    }

    @Test("Cancellation is its own outcome and must not count as an attempt")
    func cancellationIsNotAFailure() async throws {
        let transport = ScriptedAPITransport(steps: [.hang])
        let client = makeClient(transport: transport, tokens: try makeTokenManager(
            tokenTransport: ScriptedAPITransport(steps: [])))

        let task = Task { try await client.listStatus(mangaID: 7) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let result = await task.result
        #expect(throws: MALRequestFailure.cancelled) { try result.get() }
    }

    @Test("Failure presentations never carry a raw server body")
    func failurePresentationsAreClean() {
        let failures: [MALRequestFailure] = [.cancelled, .transient(retryAfter: 120),
                                             .reauthorizationRequired, .permanentItem(status: 400),
                                             .accountBlocked, .unknown(status: 418)]
        for failure in failures {
            #expect(failure.errorDescription?.isEmpty == false)
            #expect(failure.errorDescription?.contains("not json") == false)
        }
    }
}
