//
//  HostCapabilityTests.swift
//  MangaCartaTests
//
//  Acceptance criteria 5, 6 (storage), and 11 from the Host API design's
//  "Acceptance criteria for the later runtime" section.
//

import Foundation
import Network
import Testing
import WebKit
import XCTest
@testable import MangaCarta

@Suite("Host HTTP capability")
struct HostHTTPTests {

    @Test("HTTP policies reject wildcard origin patterns")
    func wildcardAssetOriginIsRejectedByHTTPPolicy() async throws {
        let url = try #require(URL(string: "https://a.mangadex.network/page.jpg"))
        let policy = HostURLPolicy(allowedOrigins: ["https://*.mangadex.network"],
                                   resolver: FixedHostResolver(addresses: ["93.184.216.34"]))
        let error = await hostCapabilityError { try await policy.validate(url) }
        #expect(error?.code == .policyDenied)

        let bareWildcard = HostURLPolicy(allowedOrigins: ["*"],
                                         resolver: FixedHostResolver(addresses: ["93.184.216.34"]))
        let bareError = await hostCapabilityError {
            try await bareWildcard.validate(try #require(URL(string: "https://example.com/image.jpg")))
        }
        #expect(bareError?.code == .policyDenied)
    }

    @Test("ImageCache refuses a wildcard-matched URL resolving privately")
    func imageCacheRejectsPrivateWildcardAsset() async throws {
        let probe = FetchProbe()
        let cache = ImageCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
            resolver: FixedHostResolver(addresses: ["10.0.0.5"]),
            fetcher: { _ in await probe.bump(); return Data("not an image".utf8) })
        let url = try #require(URL(string: "https://a.mangadex.network/page.jpg"))
        #expect(await cache.loadImage(for: url) == nil)
        #expect(await probe.count == 0)

        let publicProbe = FetchProbe()
        let publicCache = ImageCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
            resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
            fetcher: { _ in await publicProbe.bump(); return Data("not an image".utf8) })
        let publicURL = try #require(URL(string: "https://a.mangadex.network/page.jpg"))
        #expect(await publicCache.loadImage(for: publicURL) == nil)
        #expect(await publicProbe.count == 1)
    }

    @Test("Connected loopback peers are refused on the real URLSession path")
    func realURLSessionRefusesLoopbackPeer() async throws {
        let server = try LoopbackHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let fetcher = LoopbackRedirectingFetcher(
            real: URLSessionDataFetcher(configuration: .ephemeral) { _ in nil },
            port: port)
        let transport = URLSessionRepositoryTransport(
            resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
            fetcher: fetcher)

        do {
            _ = try await transport.fetchScript(
                at: try #require(URL(string: "https://allowed.example/script.js")))
            Issue.record("loopback response unexpectedly passed the peer check")
        } catch let error as RepositoryTransportError {
            #expect(error == .destinationRefused("the connected destination was non-public"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Host HTTP rejects a loopback peer on the real URLSession path")
    func hostHTTPRealURLSessionRefusesLoopbackPeer() async throws {
        let server = try LoopbackHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let fetcher = LoopbackRedirectingFetcher(
            real: URLSessionDataFetcher(configuration: .ephemeral) { _ in nil },
            port: port)
        let transport = URLSessionHostHTTPTransport(fetcher: fetcher)
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"]))

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(
                url: try #require(URL(string: "https://allowed.example/start"))))
        }

        #expect(error?.code == .policyDenied)
        #expect(error?.message == "the connected destination was non-public")
    }

    @Test("Cancelling a fetch cancels the underlying URLSession task")
    func cancellingFetchCancelsURLSessionTask() async throws {
        let server = try LoopbackHTTPServer(respondsImmediately: false)
        let port = try await server.start()
        defer { server.stop() }
        let fetcher = URLSessionDataFetcher(configuration: .ephemeral) { _ in nil }
        let request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/")))
        let task = Task { try await fetcher.fetch(request) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled fetch unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }

    @Test("HostIPAddress handles mapped, scoped, NAT64, and public addresses")
    func hostIPAddressForms() {
        let cases: [(String, Bool)] = [
            ("fe80::1%en0", false),
            ("::ffff:10.0.0.5", false),
            ("::ffff:127.0.0.1", false),
            ("64:ff9b::a00:5", false),
            ("64:ff9b::808:808", true),
            ("::ffff:8.8.8.8", true),
            ("2001:4860:4860::8888", true),
            ("93.184.216.34", true),
        ]
        for (address, expected) in cases {
            #expect(HostIPAddress.isPublic(address) == expected)
        }
    }

    @Test("HTTP rejects a private connected peer after public DNS")
    func privateConnectedPeerIsRejected() async throws {
        let url = try #require(URL(string: "https://allowed.example/start"))
        let fetcher = FixedHTTPMetricsFetcher(result: URLSessionFetchResult(
            data: Data("private response".utf8),
            response: HTTPURLResponse(url: url, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!,
            connectedPeerAddress: "10.0.0.5"))
        let transport = URLSessionHostHTTPTransport(fetcher: fetcher)
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(url: url))
        }

        #expect(error?.code == .policyDenied)
    }

    @Test("HTTP redirects cannot leave the Source's declared origins")
    func redirectCannotEscapeDeclaredOrigins() async throws {
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(
                statusCode: 302,
                url: try #require(request.url),
                headers: ["Location": "https://escape.example/private"],
                body: Data()
            )
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(
                url: try #require(URL(string: "https://allowed.example/start"))
            ))
        }

        #expect(error?.code == .policyDenied)
        #expect(await transport.requestedURLs() == ["https://allowed.example/start"])
    }

    @Test("Every HTTP redirect hop is resolved again to prevent DNS rebinding")
    func everyRedirectHopIsResolvedAgain() async throws {
        let resolver = SequencedHostResolver(answers: [
            ["93.184.216.34"],
            ["10.0.0.7"]
        ])
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(
                statusCode: 302,
                url: try #require(request.url),
                headers: ["Location": "/second"],
                body: Data()
            )
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: resolver
        )

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(
                url: try #require(URL(string: "https://allowed.example/start"))
            ))
        }

        #expect(error?.code == .policyDenied)
        #expect(await resolver.resolveCount == 2)
        #expect(await transport.requestedURLs() == ["https://allowed.example/start"])
    }

    @Test("HTTP rejects an undeclared effective URL reported by its transport")
    func transportEffectiveURLIsPolicyChecked() async throws {
        let transport = ScriptedHostHTTPTransport { _, _ in
            HostHTTPTransportResponse(
                statusCode: 200,
                url: try #require(URL(string: "https://escape.example/private")),
                headers: [:],
                body: Data("leaked".utf8)
            )
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(
                url: try #require(URL(string: "https://allowed.example/start"))
            ))
        }

        #expect(error?.code == .policyDenied)
        #expect(await transport.requestedURLs() == ["https://allowed.example/start"])
    }

    @Test("HTTP refuses prohibited author headers and never reaches transport")
    func prohibitedHeadersAreRejected() async throws {
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 200,
                                      url: try #require(request.url),
                                      headers: [:],
                                      body: Data())
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        for name in ["Host", "cookie", "AUTHORIZATION", "Proxy-Authorization", "User-Agent"] {
            let error = await hostCapabilityError {
                try await client.request(HostHTTPRequest(
                    url: try #require(URL(string: "https://allowed.example/start")),
                    headers: [name: "reader-secret"]
                ))
            }
            #expect(error?.code == .policyDenied)
        }
        #expect(await transport.requestedURLs().isEmpty)
    }

    @Test("HTTP refuses Referer and Origin values outside declared HTTPS origins")
    func refererAndOriginArePolicyChecked() async throws {
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 200,
                                      url: try #require(request.url),
                                      headers: [:],
                                      body: Data())
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        for name in ["Referer", "Origin"] {
            let error = await hostCapabilityError {
                try await client.request(HostHTTPRequest(
                    url: try #require(URL(string: "https://allowed.example/start")),
                    headers: [name: "https://escape.example/private"]
                ))
            }
            #expect(error?.code == .policyDenied)
        }
        #expect(await transport.requestedURLs().isEmpty)
    }

    @Test("A non-HTTPS destination is refused even at a declared host")
    func plainHTTPIsRefused() async throws {
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 200,
                                      url: try #require(request.url),
                                      headers: [:],
                                      body: Data())
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(
                url: try #require(URL(string: "http://allowed.example/start"))
            ))
        }

        // The host matches a declared origin; only the scheme differs.
        #expect(error?.code == .policyDenied)
        #expect(await transport.requestedURLs().isEmpty)
    }

    @Test("A URL carrying credentials is refused before it reaches transport")
    func urlCredentialsAreRefused() async throws {
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 200,
                                      url: try #require(request.url),
                                      headers: [:],
                                      body: Data())
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(
                url: try #require(URL(string: "https://reader:secret@allowed.example/start"))
            ))
        }

        #expect(error?.code == .policyDenied)
        #expect(await transport.requestedURLs().isEmpty)
    }

    @Test("One Source's HTTP cookies never reach another Source, even from a shared jar")
    func cookiesDoNotCrossSources() async throws {
        let sourceA = QualifiedSourceID(rawValue: "repo/source-a")
        let sourceB = QualifiedSourceID(rawValue: "repo/source-b")
        let jar = HostHTTPCookieJar(sourceID: sourceA)
        let resolver = FixedHostResolver(addresses: ["93.184.216.34"])
        let url = try #require(URL(string: "https://allowed.example/start"))

        let setCookie = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(
                statusCode: 200,
                url: try #require(request.url),
                headers: ["Set-Cookie": "session=secret; Path=/; Secure"],
                body: Data()
            )
        }
        let clientA = HostHTTPClient(sourceID: sourceA,
                                     allowedOrigins: ["https://allowed.example"],
                                     transport: setCookie,
                                     resolver: resolver,
                                     cookies: jar)
        _ = try await clientA.request(HostHTTPRequest(url: url))

        // Source A gets its own cookie back on a second request.
        let echoA = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 200,
                                      url: try #require(request.url),
                                      headers: [:],
                                      body: Data())
        }
        let clientA2 = HostHTTPClient(sourceID: sourceA,
                                      allowedOrigins: ["https://allowed.example"],
                                      transport: echoA,
                                      resolver: resolver,
                                      cookies: jar)
        _ = try await clientA2.request(HostHTTPRequest(url: url))
        #expect(await echoA.sentCookieHeaders() == ["session=secret"])

        // Source B, handed the very same jar, gets nothing.
        let echoB = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 200,
                                      url: try #require(request.url),
                                      headers: [:],
                                      body: Data())
        }
        let clientB = HostHTTPClient(sourceID: sourceB,
                                     allowedOrigins: ["https://allowed.example"],
                                     transport: echoB,
                                     resolver: resolver,
                                     cookies: jar)
        _ = try await clientB.request(HostHTTPRequest(url: url))
        #expect(await echoB.sentCookieHeaders() == [nil])
    }

    @Test("HTTP does not retry statuses and exposes parsed Retry-After")
    func statusesAreReturnedWithoutAutomaticRetry() async throws {
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(
                statusCode: 503,
                url: try #require(request.url),
                headers: ["Retry-After": "45", "Content-Type": "text/plain"],
                body: Data("try later".utf8)
            )
        }
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: transport,
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        let response = try await client.request(HostHTTPRequest(
            url: try #require(URL(string: "https://allowed.example/start"))
        ))

        #expect(response.status == 503)
        #expect(response.retryAfterSeconds == 45)
        #expect(response.body == .text("try later"))
        #expect(await transport.requestedURLs().count == 1)
    }
}

private actor FetchProbe {
    private(set) var count = 0

    func bump() { count += 1 }
}

@Suite("Host browser capability")
struct HostBrowserTests {

    @Test("Browser redirects cannot leave declared browser origins")
    func browserNavigationGuardRejectsCrossOriginRedirect() async throws {
        let guardModule = HostBrowserNavigationGuard(
            allowedOrigins: ["https://allowed.example"],
            resolver: FixedHostResolver(addresses: ["93.184.216.34"])
        )

        let initial = await guardModule.decision(for: try #require(
            URL(string: "https://allowed.example/start")
        ))
        let redirect = await guardModule.decision(for: try #require(
            URL(string: "https://escape.example/private")
        ))

        #expect(initial == .allow)
        guard case .cancel(let error) = redirect else {
            Issue.record("the undeclared redirect was allowed")
            return
        }
        #expect(error.code == .policyDenied)
    }

    @MainActor
    @Test("Production browser stores use the permanent per-Source UUIDv5 partition")
    func browserStoreIsStableAndSourceScoped() async throws {
        let sourceA = QualifiedSourceID(rawValue: "test.repo/browser-a")
        let sourceB = QualifiedSourceID(rawValue: "test.repo/browser-b")
        await ExtensionBrowserStore.removeData(for: sourceA)
        await ExtensionBrowserStore.removeData(for: sourceB)

        let browserA = ExtensionBrowserStore.makeWebView(for: sourceA)
        let browserAAgain = ExtensionBrowserStore.makeWebView(for: sourceA)
        let browserB = ExtensionBrowserStore.makeWebView(for: sourceB)

        #expect(browserA.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(browserA.configuration.websiteDataStore.identifier
                == UUID(uuidString: "94469B13-0190-5D01-90F0-83865BEFAF50"))
        #expect(browserAAgain.configuration.websiteDataStore.identifier
                == browserA.configuration.websiteDataStore.identifier)
        #expect(browserB.configuration.websiteDataStore.identifier
                != browserA.configuration.websiteDataStore.identifier)

        // The production factory has constructed real WKWebViews against both stores;
        // one store operation materialises each eventually-consistent registration
        // before cleanup, per ADR-0003 Amendment 3.
        await ExtensionBrowserStore.warmUp(browserA.configuration.websiteDataStore)
        await ExtensionBrowserStore.warmUp(browserB.configuration.websiteDataStore)
        await ExtensionBrowserStore.removeData(for: sourceA)
        await ExtensionBrowserStore.removeData(for: sourceB)
    }

    @Test("Browser script values cross as structured JSON without author stringification")
    func browserScriptResultIsStructuredCloned() throws {
        let raw: [String: Any] = [
            "title": "Example",
            "flags": [true, NSNull()],
            "count": 3
        ]

        let value = try HostJSONValueConverter.convert(raw)

        #expect(value == .object([
            "title": .string("Example"),
            "flags": .array([.bool(true), .null]),
            "count": .int(3)
        ]))
    }
}

@Suite("Host storage capability")
struct HostStorageTests {

    @Test("Unreadable storage is quarantined and remains unavailable")
    func corruptStorageFileIsQuarantined() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("{ definitely not valid JSON".utf8)
        let storageFile = directory.appendingPathComponent("extension-storage.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: storageFile)

        #expect(throws: (any Error).self) { try HostStorageRepository(directory: directory) }

        let quarantined = try #require(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("extension-storage.json.corrupt-") })
        #expect(try Data(contentsOf: quarantined) == original)
        #expect(!FileManager.default.fileExists(atPath: storageFile.path),
                "the corrupt file is moved aside, not left for the next write to replace")
    }

    @Test("Two configured Sources cannot read or enumerate each other's storage")
    func storageIsNamespacedByQualifiedSourceID() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HostStorageRepository(directory: directory)
        let sourceA = HostStorage(sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
                                  repository: repository)
        let sourceB = HostStorage(sourceID: QualifiedSourceID(rawValue: "repo/source-b"),
                                  repository: repository)

        try await sourceA.set("session", value: .string("only-a"))
        try await sourceB.set("session", value: .string("only-b"))

        #expect(try await sourceA.get("session") == .string("only-a"))
        #expect(try await sourceB.get("session") == .string("only-b"))
        #expect(try await sourceA.keys(prefix: "") == ["session"])
        #expect(try await sourceB.keys(prefix: "") == ["session"])
    }

    @Test("Storage survives repository recreation and only explicit Source erasure removes it")
    func storagePersistsUntilExplicitUserErasure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = QualifiedSourceID(rawValue: "repo/source-a")

        let firstRepository = try HostStorageRepository(directory: directory)
        let first = HostStorage(sourceID: sourceID, repository: firstRepository)
        try await first.set("preference", value: .object(["mode": .string("compact")]))

        let reopenedRepository = try HostStorageRepository(directory: directory)
        let reopened = HostStorage(sourceID: sourceID, repository: reopenedRepository)
        #expect(try await reopened.get("preference")
                == .object(["mode": .string("compact")]))

        try await reopenedRepository.eraseUserData(for: sourceID)
        #expect(try await reopened.get("preference") == nil)
    }
}

@Suite("Host logging capability")
struct HostLoggingTests {

    @Test("A log call carrying prohibited reader and request data stores only redactions")
    func prohibitedDataIsRedacted() async throws {
        let buffer = HostDiagnosticBuffer(maximumEntries: 10)
        let logger = HostLogger(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            operation: .pages,
            invocationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            hostAPIVersion: HostAPIVersion(major: 1, minor: 0),
            buffer: buffer
        )
        let secrets = [
            "needle-search-text", "request-body-secret", "cookie-secret",
            "authorization-secret", "stored-secret", "Private Listing Title",
            "chapter-private-id", "reader-private-id"
        ]

        try await logger.log(level: .warning, event: "request.failed", fields: [
            "url": .string("https://allowed.example/reader/chapter-private-id?query=needle-search-text"),
            "query": .string(secrets[0]),
            "body": .string(secrets[1]),
            "cookie": .string(secrets[2]),
            "headers": .string(secrets[3]),
            "storageValue": .string(secrets[4]),
            "listingTitle": .string(secrets[5]),
            "chapterId": .string(secrets[6]),
            "readerIdentifier": .string(secrets[7]),
            "status": .int(503)
        ])

        let entries = await buffer.export()
        let entry = try #require(entries.first)
        let rendered = String(describing: entry)
        for secret in secrets {
            #expect(!rendered.contains(secret))
        }
        #expect(entry.fields["url"]
                == .string("https://allowed.example/<redacted>/<redacted>"))
        #expect(entry.fields["status"] == .int(503))
        #expect(entry.sourceID == QualifiedSourceID(rawValue: "repo/source-a"))
        #expect(entry.operation == .pages)
    }
}

private func hostCapabilityError(
    _ operation: () async throws -> some Any
) async -> HostCapabilityError? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error as? HostCapabilityError
    }
}

/// Acceptance criterion 7 tests the JavaScript seam, not the typed host services.
/// These first tests intentionally install no adapters: they are the red tracer
/// bullets for the three missing `context.host` capabilities.
final class HostCapabilityBridgeTests: XCTestCase {

    func testAnEngineCanCallHostHTTP() async throws {
        let sourceID = QualifiedSourceID(rawValue: "repo-a:example")
        let transport = BridgeHTTPTransport()
        let client = HostHTTPClient(sourceID: sourceID,
                                    allowedOrigins: ["https://example.test"],
                                    transport: transport,
                                    resolver: BridgeHostResolver())
        let runtime = ExtensionRuntime(
            bundleScript: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              return context.host.http.request({
                url: "https://example.test/api", method: "POST",
                headers: { "Content-Type": "text/plain" }, body: "hello"
              })
                .then(function (response) {
                  return { ok: true, value: { status: response.status } };
                });
            } });
            """,
            declaration: ExtensionRuntimeFixtures.declaration(),
            capabilities: [HostHTTPJSCapability(client: client)])

        let value = try await runtime.invoke(.search, request: [:])
        let object = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(object["status"] as? Int, 200)
        let request = await transport.lastRequest()
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.httpBody, Data("hello".utf8))
    }

    func testAnEngineCanCallHostStorage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangacarta-s1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HostStorageRepository(directory: directory)
        let storage = HostStorage(
            sourceID: QualifiedSourceID(rawValue: "repo-a:example"),
            repository: repository)
        let runtime = ExtensionRuntime(
            bundleScript: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              return context.host.storage.set("answer", 42)
                .then(function () { return context.host.storage.get("answer"); })
                .then(function (value) { return { ok: true, value: { stored: value } }; });
            } });
            """,
            declaration: ExtensionRuntimeFixtures.declaration(),
            capabilities: [HostStorageJSCapability(storage: storage)])

        let value = try await runtime.invoke(.search, request: [:])
        let object = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(object["stored"] as? Int, 42)
        let stored = try await storage.get("answer")
        XCTAssertEqual(stored, .int(42))
    }

    func testAnEngineCanCallHostLog() async throws {
        let buffer = HostDiagnosticBuffer()
        let logger = HostLogger(
            sourceID: QualifiedSourceID(rawValue: "repo-a:example"),
            operation: .search,
            invocationID: UUID(),
            hostAPIVersion: HostAPIVersion(major: 1, minor: 0),
            buffer: buffer)
        let runtime = ExtensionRuntime(
            bundleScript: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              return context.host.log("info", "bridge.probe", { answer: 42 })
                .then(function () { return { ok: true, value: { logged: true } }; });
            } });
            """,
            declaration: ExtensionRuntimeFixtures.declaration(),
            capabilities: [HostLogJSCapability(logger: logger)])

        let value = try await runtime.invoke(.search, request: [:])
        let object = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(object["logged"] as? Bool, true)
        let entries = await buffer.export()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.event, "bridge.probe")
    }

    func testEachCapabilityPreservesHostErrorCodesAcrossTheEngineBoundary() async throws {
        let sourceID = QualifiedSourceID(rawValue: "repo-a:example")
        let client = HostHTTPClient(sourceID: sourceID,
                                    allowedOrigins: ["https://example.test"],
                                    transport: BridgeHTTPTransport(),
                                    resolver: BridgeHostResolver())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mangacarta-s1-errors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HostStorage(sourceID: sourceID,
                                  repository: try HostStorageRepository(directory: directory))
        let logger = HostLogger(sourceID: sourceID,
                                operation: .search,
                                invocationID: UUID(),
                                hostAPIVersion: HostAPIVersion(major: 1, minor: 0),
                                buffer: HostDiagnosticBuffer())
        let runtime = ExtensionRuntime(
            bundleScript: """
            registerEngine("madara", { invoke: function (operation, request, context) {
              var call;
              if (request.kind === "http") {
                call = context.host.http.request({ url: "not a URL" });
              } else if (request.kind === "storage") {
                call = context.host.storage.get(42);
              } else {
                call = context.host.log("nope", "bridge.probe");
              }
              return call.then(function () {
                return { ok: true, value: { code: "missing" } };
              }).catch(function (error) {
                return { ok: true, value: { code: error.hostErrorCode } };
              });
            } });
            """,
            declaration: ExtensionRuntimeFixtures.declaration(),
            capabilities: [HostHTTPJSCapability(client: client),
                           HostStorageJSCapability(storage: storage),
                           HostLogJSCapability(logger: logger)])

        for (kind, expectedCode) in [("http", "policy_denied"),
                                     ("storage", "invalid_request"),
                                     ("log", "invalid_request")] {
            let value = try await runtime.invoke(.search, request: ["kind": kind])
            let object = try XCTUnwrap(value as? [String: Any])
            XCTAssertEqual(object["code"] as? String, expectedCode, kind)
        }
    }
}

private final class LoopbackHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "HostCapabilityTests.loopback")
    private let respondsImmediately: Bool
    private var connections: [NWConnection] = []

    init(respondsImmediately: Bool = true) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.respondsImmediately = respondsImmediately
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            if self.respondsImmediately { self.respond(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func respond(_ connection: NWConnection) {
        let body = "ok"
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n\(body)"
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                self?.connections.removeAll { $0 === connection }
                connection.cancel()
            })
        }
    }
}

private actor BridgeHTTPTransport: HostHTTPTransport {
    private var request: URLRequest?

    func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse {
        self.request = request
        return HostHTTPTransportResponse(statusCode: 200,
                                         url: request.url!,
                                         headers: [:],
                                         body: Data("ok".utf8))
    }

    func lastRequest() -> URLRequest? { request }
}

private struct BridgeHostResolver: HostNameResolving {
    func addresses(for host: String) async throws -> [String] {
        ["93.184.216.34"]
    }
}

/// The three limits that separate this converter from S4's lenient
/// `JSONValue.init?(converting:)`. Until these existed, every one of them could be
/// deleted with the whole suite still green, so the stricter rule was unverified —
/// which is no basis for making it the module-wide one.
@Suite("Host JSON conversion limits")
struct HostJSONValueConverterTests {

    @Test("Nesting deeper than the cap is refused rather than recursed")
    func nestingBeyondTheDepthCapIsRefused() throws {
        var deep: Any = 1
        for _ in 0...HostJSONValueConverter.maximumDepth { deep = [deep] }

        let error = #expect(throws: HostCapabilityError.self) {
            try HostJSONValueConverter.convert(deep)
        }
        #expect(error?.code == .invalidResponse)

        var shallow: Any = 1
        for _ in 1..<HostJSONValueConverter.maximumDepth { shallow = [shallow] }
        #expect(throws: Never.self) { try HostJSONValueConverter.convert(shallow) }
    }

    @Test("An integer past the safe range is refused, not silently widened to a double")
    func integerBeyondTheSafeRangeIsRefused() throws {
        let unsafe = NSNumber(value: Int64(9_007_199_254_740_993))

        let error = #expect(throws: HostCapabilityError.self) {
            try HostJSONValueConverter.convert(unsafe)
        }
        #expect(error?.code == .invalidResponse)

        // The boundary itself still converts, and stays an integer.
        let safe = NSNumber(value: Int64(9_007_199_254_740_991))
        #expect(try HostJSONValueConverter.convert(safe) == .int(9_007_199_254_740_991))

        // The reverse direction refuses it too, so a value cannot re-enter out of range.
        #expect(throws: HostCapabilityError.self) {
            try HostJSONValueConverter.foundationValue(.int(9_007_199_254_740_993))
        }
    }

    @Test("Infinity and NaN are refused in both directions")
    func nonFiniteNumbersAreRefused() throws {
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            let error = #expect(throws: HostCapabilityError.self) {
                try HostJSONValueConverter.convert(NSNumber(value: value))
            }
            #expect(error?.code == .invalidResponse)

            #expect(throws: HostCapabilityError.self) {
                try HostJSONValueConverter.foundationValue(.double(value))
            }
        }
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("HostCapabilityTests-\(UUID().uuidString)", isDirectory: true)
}

private struct FixedHostResolver: HostNameResolving {
    let addresses: [String]

    func addresses(for host: String) async throws -> [String] {
        addresses
    }
}

private actor SequencedHostResolver: HostNameResolving {
    private var answers: [[String]]
    private(set) var resolveCount = 0

    init(answers: [[String]]) {
        self.answers = answers
    }

    func addresses(for host: String) async throws -> [String] {
        resolveCount += 1
        guard !answers.isEmpty else { return [] }
        return answers.removeFirst()
    }
}

private actor ScriptedHostHTTPTransport: HostHTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> HostHTTPTransportResponse

    private let handler: Handler
    private var urls: [String] = []
    private var cookies: [String?] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse {
        urls.append(request.url?.absoluteString ?? "<missing>")
        cookies.append(request.value(forHTTPHeaderField: "Cookie"))
        return try handler(request, urls.count)
    }

    func requestedURLs() -> [String] {
        urls
    }

    func sentCookieHeaders() -> [String?] {
        cookies
    }
}

private struct FixedHTTPMetricsFetcher: URLSessionDataFetching {
    let result: URLSessionFetchResult

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult { result }
}

private struct LoopbackRedirectingFetcher: URLSessionDataFetching {
    let real: any URLSessionDataFetching
    let port: UInt16

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult {
        var loopbackRequest = request
        loopbackRequest.url = URL(string: "http://127.0.0.1:\(port)/")
        return try await real.fetch(loopbackRequest)
    }
}
