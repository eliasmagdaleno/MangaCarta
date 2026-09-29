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
import UIKit
import WebKit
import XCTest
@testable import MangaCarta

@Suite("Host HTTP capability")
struct HostHTTPTests {

    @Test("Host HTTP sessions bypass configured system proxies")
    func hostHTTPSessionBypassesSystemProxies() {
        #expect(URLSessionHostHTTPTransport.sessionConfiguration().connectionProxyDictionary?.isEmpty == true)
    }

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

    @Test("URLSession delegate reports the connected peer before completion")
    func realURLSessionReportsPeerMetrics() async throws {
        let server = try LoopbackHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let fetcher = URLSessionDataFetcher(configuration: .ephemeral) { _ in nil }
        let result = try await fetcher.fetch(URLRequest(
            url: try #require(URL(string: "http://127.0.0.1:\(port)/"))))

        #expect(result.connectedPeerAddress != nil)
        #expect(result.resourceFetchType == .networkLoad)
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

    @Test("A private connected peer is refused and no response body is returned")
    func privateConnectedPeerIsRefusedAfterRebinding() async throws {
        let url = try #require(URL(string: "https://allowed.example/start"))
        let resolver = SequencedHostResolver(answers: [["93.184.216.34"], ["10.0.0.5"]])
        let fetcher = FixedHTTPMetricsFetcher(result: URLSessionFetchResult(
            data: Data("secret body".utf8),
            response: HTTPURLResponse(url: url, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!,
            connectedPeerAddress: "10.0.0.5"))
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: URLSessionHostHTTPTransport(fetcher: fetcher),
            resolver: resolver)

        let error = await hostCapabilityError {
            _ = try await client.request(HostHTTPRequest(url: url))
        }

        #expect(error?.code == .policyDenied)
        #expect(error?.message == "the connected destination was non-public")
    }

    @Test("HTTP rejects a response with missing connected peer metrics")
    func missingConnectedPeerIsRejected() async throws {
        let url = try #require(URL(string: "https://allowed.example/start"))
        let fetcher = FixedHTTPMetricsFetcher(result: URLSessionFetchResult(
            data: Data("response".utf8),
            response: HTTPURLResponse(url: url, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!,
            connectedPeerAddress: nil))
        let client = HostHTTPClient(
            sourceID: QualifiedSourceID(rawValue: "repo/source-a"),
            allowedOrigins: ["https://allowed.example"],
            transport: URLSessionHostHTTPTransport(fetcher: fetcher),
            resolver: FixedHostResolver(addresses: ["93.184.216.34"]))

        let error = await hostCapabilityError {
            try await client.request(HostHTTPRequest(url: url))
        }

        #expect(error?.code == .policyDenied)
        #expect(error?.message == "the connected destination was non-public")
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

    @Test("HTTP redirects cannot downgrade to plaintext")
    func httpRedirectIsRejected() async throws {
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(
                statusCode: 302,
                url: try #require(request.url),
                headers: ["Location": "http://allowed.example/plaintext"],
                body: Data())
        }
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
        #expect(await transport.requestedURLs() == ["https://allowed.example/start"])
    }

    @Test("HTTP transport refuses plaintext requests before fetching")
    func httpRequestURLIsRejectedBeforeTransport() async throws {
        let fetcher = FixedHTTPMetricsFetcher(result: URLSessionFetchResult(
            data: Data(),
            response: HTTPURLResponse(url: try #require(URL(string: "http://allowed.example/start")),
                                      statusCode: 200, httpVersion: nil, headerFields: nil)!,
            connectedPeerAddress: "93.184.216.34"))
        let transport = URLSessionHostHTTPTransport(fetcher: fetcher)
        do {
            _ = try await transport.send(URLRequest(
                url: try #require(URL(string: "http://allowed.example/start"))))
            Issue.record("plaintext request unexpectedly reached the fetcher")
        } catch let error as HostCapabilityError {
            #expect(error.code == .policyDenied)
        }
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
        let rateLimiters = HostRateLimiterRegistry()
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
                                     cookies: jar,
                                     rateLimiters: rateLimiters)
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
                                      cookies: jar,
                                      rateLimiters: rateLimiters)
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
                                     cookies: jar,
                                     rateLimiters: rateLimiters)
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

@Suite("Image cache network boundary")
struct ImageCacheNetworkTests {
    private let url = URL(string: "https://a.mangadex.network/page.png")!
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    @Test("Image session bypasses proxies and URLCache")
    func imageSessionConfiguration() {
        let configuration = ImageCache.sessionConfiguration()
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("A private or missing connected peer never reaches image decoding")
    func rejectsUntrustedPeerBeforeDecode() async {
        for peer in ["10.0.0.5", nil] as [String?] {
            let directory = temporaryDirectory()
            let decoder = ImageDecodeProbe()
            let cache = ImageCache(
                directory: directory,
                resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                sessionFetcher: ImageFetchProbe(result: result(peer: peer)),
                decoder: { decoder.decode($0) })

            #expect(await cache.loadImage(for: url) == nil)
            #expect(decoder.count == 0)
            let disk = ImageDiskCache(directory: directory, maxBytes: 1_000_000)
            #expect(await disk.has(ImageCache.key(for: url)) == false)
        }
    }

    @Test("A URLSession cache response is refused despite a public peer")
    func rejectsURLSessionCacheResponse() async {
        let decoder = ImageDecodeProbe()
        let cache = ImageCache(
            directory: temporaryDirectory(),
            resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
            sessionFetcher: ImageFetchProbe(result: result(
                peer: "93.184.216.34", fetchType: .localCache)),
            decoder: { decoder.decode($0) })

        #expect(await cache.loadImage(for: url) == nil)
        #expect(decoder.count == 0)
    }

    @Test("A public peer loads, then ImageCache's disk hit works offline")
    func publicPeerAndOfflineDiskHit() async {
        let directory = temporaryDirectory()
        let firstFetcher = ImageFetchProbe(result: result(peer: "93.184.216.34"))
        let online = ImageCache(directory: directory,
                                resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                                sessionFetcher: firstFetcher)
        #expect(await online.loadImage(for: url) != nil)
        #expect(await firstFetcher.count == 1)

        let offlineFetcher = ImageFetchProbe(result: result(peer: nil))
        let offline = ImageCache(directory: directory,
                                 resolver: FixedHostResolver(addresses: []),
                                 sessionFetcher: offlineFetcher)
        #expect(await offline.loadImage(for: url) != nil)
        #expect(await offlineFetcher.count == 0)
    }

    @Test("The real URLSession peer metric blocks a rebound loopback image")
    func realURLSessionLoopbackPeerNeverDecodes() async throws {
        let server = try LoopbackHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let decoder = ImageDecodeProbe()
        let fetcher = OriginalImageURLFetcher(
            real: LoopbackRedirectingFetcher(
                real: URLSessionDataFetcher(
                    configuration: ImageCache.sessionConfiguration(),
                    redirectHandler: URLSessionDataFetcher.httpsOnlyRedirectHandler),
                port: port))
        let observed = try await fetchRetryingLostConnection(fetcher, URLRequest(url: url),
                                                             server: server)
        #expect(observed.response.url == url)
        let peer = try #require(observed.connectedPeerAddress)
        #expect(!HostIPAddress.isPublic(peer))
        let cache = ImageCache(
            directory: temporaryDirectory(),
            resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
            sessionFetcher: fetcher,
            decoder: { decoder.decode($0) })

        #expect(await cache.loadImage(for: url) == nil)
        #expect(decoder.count == 0)
    }

    private func result(peer: String?,
                        fetchType: URLSessionResourceFetchType = .networkLoad) -> URLSessionFetchResult {
        URLSessionFetchResult(
            data: png,
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            connectedPeerAddress: peer,
            resourceFetchType: fetchType)
    }
}

// MARK: - Image-load reports (ADR-0003 Amendment 9, design §3)

@Suite("Image-load reports from ImageCache")
struct ImageLoadReportCacheTests {
    private let url = URL(string: "https://a1.mangadex.network/data/hash/1.png")!
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private let target = ImageLoadReportTarget(
        sourceID: QualifiedSourceID(rawValue: "repo:mangadex"),
        endpoint: URL(string: "https://api.mangadex.network/report")!,
        origins: ["https://*.mangadex.network"])

    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoadReportCache-\(UUID().uuidString)")
    }

    private func sessionResult(xCache: String?, status: Int = 200) -> URLSessionFetchResult {
        URLSessionFetchResult(
            data: png,
            response: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                      headerFields: xCache.map { ["X-Cache": $0] })!,
            connectedPeerAddress: "93.184.216.34",
            resourceFetchType: .networkLoad)
    }

    private func sessionCache(xCache: String?, reporter: RecordingImageLoadReporter,
                              directory: URL? = nil,
                              uptime: SteppingUptime = SteppingUptime([10, 10.25])) -> ImageCache {
        ImageCache(directory: directory ?? self.directory(),
                   resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                   sessionFetcher: ImageFetchProbe(result: sessionResult(xCache: xCache)),
                   reporter: reporter,
                   uptime: { uptime.next() })
    }

    @Test("a covered network load reports url, success, bytes, duration and the X-Cache hit")
    func coveredLoadIsReported() async {
        let reporter = RecordingImageLoadReporter()
        let cache = sessionCache(xCache: "HIT from node", reporter: reporter)
        #expect(await cache.loadImage(for: url, reportTarget: target) != nil)
        #expect(reporter.reports == [
            .init(report: ImageLoadReport(url: url, success: true, cached: true,
                                          bytes: png.count, durationMilliseconds: 250),
                  target: target)
        ])
    }

    @Test("only an X-Cache value starting with HIT counts as cached", arguments: [
        ("hit", true), ("HIT-edge", true), ("MISS", false), ("x-hit", false)
    ])
    func xCacheHitPrefix(value: String, cached: Bool) async {
        let reporter = RecordingImageLoadReporter()
        _ = await sessionCache(xCache: value, reporter: reporter).loadImage(for: url, reportTarget: target)
        #expect(reporter.reports.map(\.report.cached) == [cached])
    }

    @Test("no X-Cache header reports cached false")
    func missingXCacheIsNotCached() async {
        let reporter = RecordingImageLoadReporter()
        _ = await sessionCache(xCache: nil, reporter: reporter).loadImage(for: url, reportTarget: target)
        #expect(reporter.reports.map(\.report.cached) == [false])
    }

    @Test("a disk hit downloads nothing and reports nothing")
    func diskHitIsNotReported() async {
        let shared = directory()
        let first = RecordingImageLoadReporter()
        _ = await sessionCache(xCache: nil, reporter: first, directory: shared)
            .loadImage(for: url, reportTarget: target)
        let second = RecordingImageLoadReporter()
        #expect(await sessionCache(xCache: nil, reporter: second, directory: shared)
            .loadImage(for: url, reportTarget: target) != nil)
        #expect(first.reports.count == 1)
        #expect(second.reports.isEmpty)
    }

    @Test("no target, or a URL the target does not cover, reports nothing")
    func uncoveredLoadsAreNotReported() async {
        let reporter = RecordingImageLoadReporter()
        _ = await sessionCache(xCache: nil, reporter: reporter).loadImage(for: url)
        let uncovered = ImageLoadReportTarget(sourceID: target.sourceID, endpoint: target.endpoint,
                                              origins: ["https://uploads.mangadex.org"])
        _ = await sessionCache(xCache: nil, reporter: reporter).loadImage(for: url, reportTarget: uncovered)
        #expect(reporter.reports.isEmpty)
    }

    @Test("a URL the destination policy refuses is never attempted and never reported")
    func policyRefusalIsNotReported() async {
        let reporter = RecordingImageLoadReporter()
        let cache = ImageCache(directory: directory(),
                               resolver: FixedHostResolver(addresses: ["10.0.0.5"]),
                               sessionFetcher: ImageFetchProbe(result: sessionResult(xCache: nil)),
                               reporter: reporter)
        #expect(await cache.loadImage(for: url, reportTarget: target) == nil)
        #expect(reporter.reports.isEmpty)
    }

    @Test("a private connected peer is the host's refusal, not a node failure")
    func peerRefusalIsNotReported() async {
        let reporter = RecordingImageLoadReporter()
        let result = URLSessionFetchResult(data: png,
                                           response: HTTPURLResponse(url: url, statusCode: 200,
                                                                     httpVersion: nil, headerFields: nil)!,
                                           connectedPeerAddress: "10.0.0.5",
                                           resourceFetchType: .networkLoad)
        let cache = ImageCache(directory: directory(),
                               resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                               sessionFetcher: ImageFetchProbe(result: result),
                               reporter: reporter)
        #expect(await cache.loadImage(for: url, reportTarget: target) == nil)
        #expect(reporter.reports.isEmpty)
    }

    @Test("every attempt is reported: a throttled attempt fails, the retry succeeds")
    func eachAttemptIsReported() async {
        let reporter = RecordingImageLoadReporter()
        let counter = FetchProbe()
        let png = self.png
        let cache = ImageCache(directory: directory(), retryBaseDelay: 0, maxImageRetries: 2,
                               resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                               fetcher: { _ in
                                   await counter.bump()
                                   if await counter.count == 1 { throw ImageFetchError.rateLimited }
                                   return png
                               },
                               reporter: reporter,
                               uptime: { SteppingUptime.shared.next() })
        #expect(await cache.loadImage(for: url, reportTarget: target) != nil)
        #expect(reporter.reports.map(\.report.success) == [false, true])
        #expect(reporter.reports.map(\.report.bytes) == [0, png.count])
    }

    @Test("a cancelled load says nothing about the node and is not reported")
    func cancellationIsNotReported() async {
        let reporter = RecordingImageLoadReporter()
        let cache = ImageCache(directory: directory(),
                               resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                               fetcher: { _ in throw URLError(.cancelled) },
                               reporter: reporter)
        #expect(await cache.loadImage(for: url, reportTarget: target) == nil)
        let cancelled = ImageCache(directory: directory(),
                                   resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                                   fetcher: { _ in throw CancellationError() },
                                   reporter: reporter)
        #expect(await cancelled.loadImage(for: url, reportTarget: target) == nil)
        #expect(reporter.reports.isEmpty)
    }

    @Test("a download that fails to decode still reports a successful retrieval")
    func decodeFailureKeepsSuccess() async {
        let reporter = RecordingImageLoadReporter()
        let png = self.png
        let cache = ImageCache(directory: directory(),
                               resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                               fetcher: { _ in png },
                               reporter: reporter,
                               decoder: { _ in nil })
        #expect(await cache.loadImage(for: url, reportTarget: target) == nil)
        #expect(reporter.reports.map(\.report.success) == [true])
    }

    @Test("prefetch passes the target to every load")
    func prefetchReports() async {
        let reporter = RecordingImageLoadReporter()
        let png = self.png
        let cache = ImageCache(directory: directory(),
                               resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                               fetcher: { _ in png },
                               reporter: reporter)
        let urls = (1...3).map { URL(string: "https://a1.mangadex.network/data/hash/\($0).png")! }
        await cache.prefetchAwaitable(urls, maxConcurrent: 2, reportTarget: target)
        #expect(Set(reporter.reports.map(\.report.url)) == Set(urls))
    }
}

@Suite("Image-load reporter")
struct ImageLoadReporterTests {
    private let target = ImageLoadReportTarget(
        sourceID: QualifiedSourceID(rawValue: "repo:mangadex"),
        endpoint: URL(string: "https://api.mangadex.network/report")!,
        origins: ["https://*.mangadex.network"])
    private let report = ImageLoadReport(url: URL(string: "https://a1.mangadex.network/data/h/1.png")!,
                                         success: true, cached: false, bytes: 123,
                                         durationMilliseconds: 250)

    private func reporter(_ transport: ReportTransport,
                          registry: HostRateLimiterRegistry = HostRateLimiterRegistry(),
                          cap: Int = ImageLoadReporter.maximumInFlightPerSource) -> ImageLoadReporter {
        ImageLoadReporter(rateLimiters: registry, transport: transport,
                          resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                          maximumInFlightPerSource: cap)
    }

    @Test("a report is a JSON POST of exactly the five fields to the endpoint")
    func payloadIsFixed() async throws {
        let transport = ReportTransport()
        let reporter = reporter(transport)
        reporter.report(report, to: target)
        await reporter.waitUntilIdle()

        let request = try #require(await transport.requests().first)
        #expect(request.url == target.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["url", "success", "cached", "bytes", "duration"])
        #expect(json["url"] as? String == "https://a1.mangadex.network/data/h/1.png")
        #expect(json["success"] as? Bool == true)
        #expect(json["cached"] as? Bool == false)
        #expect(json["bytes"] as? Int == 123)
        #expect(json["duration"] as? Int == 250)
    }

    @Test("reports never carry cookies, even after the endpoint sets one")
    func noCookies() async throws {
        let transport = ReportTransport(headers: ["Set-Cookie": "session=abc; Path=/; Secure"])
        let reporter = reporter(transport)
        reporter.report(report, to: target)
        await reporter.waitUntilIdle()
        reporter.report(report, to: target)
        await reporter.waitUntilIdle()
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    @Test("a 429 from the endpoint pauses later reports (ADR-0003 Amendment 8)")
    func endpointRateLimitPausesReports() async {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1, rules: [],
                                                clock: FixedRateLimiterClock(), sleeper: sleeper)
        let transport = ReportTransport(firstStatus: 429, headers: ["Retry-After": "30"])
        let reporter = reporter(transport, registry: registry)
        reporter.report(report, to: target)
        await reporter.waitUntilIdle()
        reporter.report(report, to: target)
        await reporter.waitUntilIdle()
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate) == [0, 30])
    }

    @Test("a transport failure is dropped, never retried, and the next report still goes")
    func failuresAreDropped() async {
        let transport = ReportTransport(failFirst: true)
        let reporter = reporter(transport)
        reporter.report(report, to: target)
        await reporter.waitUntilIdle()
        reporter.report(report, to: target)
        await reporter.waitUntilIdle()
        #expect(await transport.requests().count == 2)
    }

    @Test("past the per-Source cap new reports are dropped; other Sources are unaffected")
    func backlogIsCappedPerSource() async {
        let transport = ReportTransport(gated: true)
        let reporter = reporter(transport, cap: 2)
        let other = ImageLoadReportTarget(sourceID: QualifiedSourceID(rawValue: "repo:other"),
                                          endpoint: target.endpoint, origins: target.origins)
        for _ in 0..<3 { reporter.report(report, to: target) }
        reporter.report(report, to: other)
        await transport.waitForRequests(3)
        await transport.open()
        await reporter.waitUntilIdle()
        #expect(await transport.requests().count == 3)
    }
}

/// Records every request; can fail the first send, answer the first with a status, or hold
/// every send until `open()`.
private actor ReportTransport: HostHTTPTransport {
    private let firstStatus: Int
    private let headers: [String: String]
    private let failFirst: Bool
    private var gated: Bool
    private var recorded: [URLRequest] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var countWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init(firstStatus: Int = 200, headers: [String: String] = [:],
         failFirst: Bool = false, gated: Bool = false) {
        self.firstStatus = firstStatus
        self.headers = headers
        self.failFirst = failFirst
        self.gated = gated
    }

    func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse {
        recorded.append(request)
        let index = recorded.count
        if let waiter = countWaiter, recorded.count >= waiter.count {
            countWaiter = nil
            waiter.continuation.resume()
        }
        if gated { await withCheckedContinuation { held.append($0) } }
        if failFirst && index == 1 { throw URLError(.notConnectedToInternet) }
        return HostHTTPTransportResponse(statusCode: index == 1 ? firstStatus : 200,
                                         url: request.url!, headers: headers, body: Data(),
                                         connectedPeerAddress: "93.184.216.34")
    }

    func requests() -> [URLRequest] { recorded }

    /// Returns once `count` requests arrived, or after five seconds, so a reporter that
    /// never sends fails the test's assertion instead of hanging the suite.
    func waitForRequests(_ count: Int) async {
        guard recorded.count < count else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.expireCountWaiter()
        }
        await withCheckedContinuation { countWaiter = (count, $0) }
        timeout.cancel()
    }

    private func expireCountWaiter() {
        countWaiter?.continuation.resume()
        countWaiter = nil
    }

    func open() {
        gated = false
        held.forEach { $0.resume() }
        held = []
    }
}

private final class RecordingImageLoadReporter: ImageLoadReporting, @unchecked Sendable {
    struct Entry: Equatable {
        let report: ImageLoadReport
        let target: ImageLoadReportTarget
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    var reports: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func report(_ report: ImageLoadReport, to target: ImageLoadReportTarget) {
        lock.lock()
        entries.append(Entry(report: report, target: target))
        lock.unlock()
    }
}

/// Hands out fixed uptime readings in order, then repeats the last one.
private final class SteppingUptime: @unchecked Sendable {
    static let shared = SteppingUptime([0])
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(_ values: [TimeInterval]) { self.values = values }

    func next() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
    }
}

private actor ImageFetchProbe: URLSessionDataFetching {
    let result: URLSessionFetchResult
    private(set) var count = 0

    init(result: URLSessionFetchResult) { self.result = result }

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult {
        count += 1
        return result
    }
}

private final class ImageDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func decode(_ data: Data) -> UIImage? {
        lock.lock()
        calls += 1
        lock.unlock()
        return UIImage(data: data)
    }
}

private actor FetchProbe {
    private(set) var count = 0

    func bump() { count += 1 }
}

struct PublicImageResolver: HostNameResolving {
    func addresses(for host: String) async throws -> [String] { ["93.184.216.34"] }
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
    /// What the server saw, in order. Read on `queue`; printed when a fetch loses its
    /// connection, so a rare flake says whether this side accepted, read, and answered.
    private var log: [String] = []

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
            let endpoint = connection.endpoint
            self.log.append("accepted \(endpoint)")
            connection.stateUpdateHandler = { [weak self] state in
                self?.log.append("\(endpoint) \(state)")
            }
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

    func events() -> [String] {
        queue.sync { log }
    }

    private func respond(_ connection: NWConnection) {
        let body = "ok"
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n\(body)"
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            self?.log.append("received \(data?.count ?? 0) bytes, complete \(isComplete), error \(String(describing: error))")
            connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
                self?.log.append("sent, error \(String(describing: error))")
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
                                         body: Data("ok".utf8),
                                         connectedPeerAddress: "93.184.216.34")
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
        let response = try handler(request, urls.count)
        return HostHTTPTransportResponse(statusCode: response.statusCode,
                                         url: response.url,
                                         headers: response.headers,
                                         body: response.body,
                                         connectedPeerAddress: response.connectedPeerAddress
                                            ?? "93.184.216.34")
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

/// `realURLSessionLoopbackPeerNeverDecodes` lost its loopback connection once (-1005, 2026-09-28,
/// one failure in a full run), and thousands of fetches under stress would not reproduce it.
/// URLSession already makes three connection attempts before it reports -1005, so that failure
/// means three were lost in a row (or one mid-response). The fetch only sets up that test's
/// subject, so a lost connection is retried once — and what the server saw is printed, so the
/// next occurrence shows whether this side accepted, read and answered.
private func fetchRetryingLostConnection(_ fetcher: some URLSessionDataFetching,
                                         _ request: URLRequest,
                                         server: LoopbackHTTPServer) async throws -> URLSessionFetchResult {
    do {
        return try await fetcher.fetch(request)
    } catch let error as URLError where error.code == .networkConnectionLost {
        print("[loopback-flake] \(error); server saw: \(server.events())")
        return try await fetcher.fetch(request)
    }
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

@Suite("Host rate limiting")
struct HostRateLimiterTests {
    @Test("concurrent reservations share a Source and origin budget")
    func concurrentReservationsAreSpaced() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1,
                                                rules: [],
                                                clock: FixedRateLimiterClock(),
                                                sleeper: sleeper)
        let source = QualifiedSourceID(rawValue: "repo/source")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try? await registry.reserve(sourceID: source,
                                                origin: "https://example.com",
                                                path: "/search")
                }
            }
        }
        let dates = (await sleeper.dates()).sorted()
        #expect(dates.count == 3)
        #expect(dates[1].timeIntervalSince(dates[0]) == 1)
        #expect(dates[2].timeIntervalSince(dates[1]) == 1)
    }

    @Test("different Sources and origins have independent budgets")
    func independentKeysDoNotBlockEachOther() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1, rules: [],
                                                clock: FixedRateLimiterClock(), sleeper: sleeper)
        async let one = registry.reserve(sourceID: QualifiedSourceID(rawValue: "a"),
                                         origin: "https://example.com", path: "/")
        async let two = registry.reserve(sourceID: QualifiedSourceID(rawValue: "b"),
                                         origin: "https://example.com", path: "/")
        async let three = registry.reserve(sourceID: QualifiedSourceID(rawValue: "a"),
                                           origin: "https://other.example", path: "/")
        _ = try await (one, two, three)
        let dates = await sleeper.dates()
        #expect(dates.count == 3)
        #expect(dates.allSatisfy { $0 == Date(timeIntervalSinceReferenceDate: 0) })
    }

    @Test("matching path rules add a second budget")
    func pathRuleIsAppliedAlongsideOriginRule() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1,
                                                rules: [HostRateLimitRule(origin: "https://api.example.com",
                                                                          pathPrefix: "/slow",
                                                                          requestsPerMinute: 30)],
                                                clock: FixedRateLimiterClock(), sleeper: sleeper)
        let source = QualifiedSourceID(rawValue: "a")
        try await registry.reserve(sourceID: source, origin: "https://api.example.com", path: "/slow/1")
        try await registry.reserve(sourceID: source, origin: "https://api.example.com", path: "/slow/2")
        try await registry.reserve(sourceID: source, origin: "https://api.example.com", path: "/other")
        let dates = (await sleeper.dates()).sorted()
        #expect(dates.count == 5)
        #expect(dates.map(\.timeIntervalSinceReferenceDate) == [0, 0, 1, 2, 2])
    }

    @Test("HostHTTP clients for one Source share the registry budget")
    func clientsShareSourceBudget() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1, rules: [],
                                                clock: FixedRateLimiterClock(), sleeper: sleeper)
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 200, url: request.url!,
                                      headers: [:], body: Data("ok".utf8))
        }
        let source = QualifiedSourceID(rawValue: "repo/source")
        let clientA = HostHTTPClient(sourceID: source, allowedOrigins: ["https://example.com"],
                                     transport: transport, resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                                     rateLimiters: registry)
        let clientB = HostHTTPClient(sourceID: source, allowedOrigins: ["https://example.com"],
                                     transport: transport, resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                                     rateLimiters: registry)
        async let one = clientA.request(HostHTTPRequest(url: URL(string: "https://example.com/a")!))
        async let two = clientB.request(HostHTTPRequest(url: URL(string: "https://example.com/b")!))
        _ = try await (one, two)
        #expect((await sleeper.dates()).sorted().map(\.timeIntervalSinceReferenceDate) == [0, 1])
    }

    @MainActor
    @Test("the production host factory retains one shared registry")
    func factorySharesRegistry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostRateLimiterFactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = HostRateLimiterRegistry()
        let factory = try ExtensionHostCapabilityFactory(
            directory: directory,
            transport: ScriptedHostHTTPTransport { request, _ in
                HostHTTPTransportResponse(statusCode: 200, url: request.url!, headers: [:], body: Data())
            },
            resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
            browserManager: ExtensionBrowserManager(resolver: FixedHostResolver(addresses: ["93.184.216.34"])),
            diagnosticBuffer: HostDiagnosticBuffer(),
            rateLimiters: registry)
        #expect(factory.rateLimiters === registry)
    }

    @Test("the default MangaDex path rule is 40 requests per minute")
    func defaultRulesAreMangaDexSpecific() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(clock: FixedRateLimiterClock(), sleeper: sleeper)
        let source = QualifiedSourceID(rawValue: "a")
        try await registry.reserve(sourceID: source, origin: "https://api.mangadex.org", path: "/at-home/server/1")
        try await registry.reserve(sourceID: source, origin: "https://api.mangadex.org", path: "/at-home/server/2")
        try await registry.reserve(sourceID: source, origin: "https://api.mangadex.org", path: "/manga")
        #expect((await sleeper.dates()).sorted().map(\.timeIntervalSinceReferenceDate) == [0, 0, 0.2, 0.4, 1.5])
    }

    @Test("cancelling a waiter releases its final reservation")
    func cancellationReleasesSlot() async throws {
        let sleeper = BlockingRateLimiterSleeper()
        let limiter = RateLimiter(minimumInterval: 1, clock: FixedRateLimiterClock(), sleeper: sleeper)
        _ = try await limiter.acquire()
        let waiting = Task { try await limiter.acquire() }
        await sleeper.waitForSecondSleep()
        waiting.cancel()
        _ = try? await waiting.value
        _ = try await limiter.acquire()
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate) == [0, 1, 1])
    }

    @Test("a cancelled middle slot is reused without moving a later reservation")
    func middleCancellationReleasesSlot() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let limiter = RateLimiter(minimumInterval: 1, clock: FixedRateLimiterClock(), sleeper: sleeper)
        _ = try await limiter.acquire()
        let middle = try await limiter.acquire()
        _ = try await limiter.acquire()
        await middle.cancel()
        _ = try await limiter.acquire()
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate) == [0, 1, 2, 1])
    }

    @Test("a pause delays the next reservation until it ends")
    func pauseDelaysNextReservation() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let limiter = RateLimiter(minimumInterval: 1, clock: FixedRateLimiterClock(), sleeper: sleeper)
        _ = try await limiter.acquire()
        await limiter.pause(until: Date(timeIntervalSinceReferenceDate: 30))
        _ = try await limiter.acquire()
        _ = try await limiter.acquire()
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate) == [0, 30, 31])
    }

    @Test("a released slot inside a pause is not reused")
    func pauseDropsReleasedSlots() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let limiter = RateLimiter(minimumInterval: 1, clock: FixedRateLimiterClock(), sleeper: sleeper)
        _ = try await limiter.acquire()
        let middle = try await limiter.acquire()
        _ = try await limiter.acquire()
        await middle.cancel()
        await limiter.pause(until: Date(timeIntervalSinceReferenceDate: 30))
        _ = try await limiter.acquire()
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate) == [0, 1, 2, 30])
    }

    @Test("waiters asleep when a pause begins re-reserve spaced slots after it")
    func sleepingWaitersRespacedAfterPause() async throws {
        let sleeper = GatedRateLimiterSleeper(blocking: [Date(timeIntervalSinceReferenceDate: 1),
                                                         Date(timeIntervalSinceReferenceDate: 2)])
        let limiter = RateLimiter(minimumInterval: 1, clock: FixedRateLimiterClock(), sleeper: sleeper)
        _ = try await limiter.acquire()
        let first = Task { try await limiter.acquire() }
        let second = Task { try await limiter.acquire() }
        await sleeper.waitForBlockedSleepers(2)
        await limiter.pause(until: Date(timeIntervalSinceReferenceDate: 30))
        await sleeper.open()
        _ = try await first.value
        _ = try await second.value
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate).sorted() == [0, 1, 2, 30, 31])
    }

    @Test("a registry pause holds one Source's origin, not other Sources")
    func registryPauseIsScopedToSourceAndOrigin() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1,
                                                rules: [HostRateLimitRule(origin: "https://api.example.com",
                                                                          pathPrefix: "/slow",
                                                                          requestsPerMinute: 60)],
                                                clock: FixedRateLimiterClock(), sleeper: sleeper)
        let paused = QualifiedSourceID(rawValue: "a")
        try await registry.reserve(sourceID: paused, origin: "https://api.example.com", path: "/slow/1")
        await registry.pause(sourceID: paused, origin: "https://api.example.com", retryAfter: .delay(30))
        try await registry.reserve(sourceID: paused, origin: "https://api.example.com", path: "/slow/2")
        try await registry.reserve(sourceID: QualifiedSourceID(rawValue: "b"),
                                   origin: "https://api.example.com", path: "/other")
        // a: path 0, origin 0; a again: path 30, origin 30; b: origin 0.
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate) == [0, 0, 30, 30, 0])
    }

    @Test("a registry pause honours an instant and is capped at five minutes")
    func registryPauseInstantAndCap() async throws {
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1, rules: [],
                                                clock: FixedRateLimiterClock(), sleeper: sleeper)
        let instant = QualifiedSourceID(rawValue: "instant")
        let capped = QualifiedSourceID(rawValue: "capped")
        await registry.pause(sourceID: instant, origin: "https://example.com",
                             retryAfter: .instant(Date(timeIntervalSinceReferenceDate: 45)))
        await registry.pause(sourceID: capped, origin: "https://example.com", retryAfter: .delay(3600))
        try await registry.reserve(sourceID: instant, origin: "https://example.com", path: "/")
        try await registry.reserve(sourceID: capped, origin: "https://example.com", path: "/")
        #expect((await sleeper.dates()).map(\.timeIntervalSinceReferenceDate) == [45, 300])
    }

    @Test("Retry-After values parse as seconds, epoch instants and HTTP dates")
    func retryAfterParsing() {
        #expect(HostRetryAfter(headerValue: "45") == .delay(45))
        #expect(HostRetryAfter(headerValue: "1800000020") ==
                    .instant(Date(timeIntervalSince1970: 1_800_000_020)))
        #expect(HostRetryAfter(headerValue: "Wed, 21 Oct 2015 07:28:00 GMT") ==
                    .instant(Date(timeIntervalSince1970: 1_445_412_480)))
        #expect(HostRetryAfter(headerValue: "-5") == nil)
        #expect(HostRetryAfter(headerValue: "soon") == nil)
    }

    @Test("a 429 pauses the Source's origin until X-RateLimit-Retry-After")
    func tooManyRequestsPausesOrigin() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1, rules: [],
                                                clock: FixedRateLimiterClock(date: now), sleeper: sleeper)
        let transport = ScriptedHostHTTPTransport { request, index in
            HostHTTPTransportResponse(statusCode: index == 1 ? 429 : 200, url: request.url!,
                                      headers: ["X-RateLimit-Retry-After": "1800000020"],
                                      body: Data("ok".utf8))
        }
        let client = HostHTTPClient(sourceID: QualifiedSourceID(rawValue: "repo/source"),
                                    allowedOrigins: ["https://example.com"], transport: transport,
                                    resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                                    rateLimiters: registry)
        let limited = try await client.request(HostHTTPRequest(url: URL(string: "https://example.com/a")!))
        _ = try await client.request(HostHTTPRequest(url: URL(string: "https://example.com/b")!))
        _ = try await client.request(HostHTTPRequest(url: URL(string: "https://example.com/c")!))
        #expect(limited.status == 429)
        #expect((await sleeper.dates()).map { $0.timeIntervalSince(now) } == [0, 20, 21])
    }

    @Test("only a 429 pauses; other statuses with rate-limit headers do not")
    func nonTooManyRequestsDoesNotPause() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sleeper = RecordingRateLimiterSleeper()
        let registry = HostRateLimiterRegistry(defaultInterval: 1, rules: [],
                                                clock: FixedRateLimiterClock(date: now), sleeper: sleeper)
        let transport = ScriptedHostHTTPTransport { request, _ in
            HostHTTPTransportResponse(statusCode: 503, url: request.url!,
                                      headers: ["Retry-After": "45",
                                                "X-RateLimit-Retry-After": "1800000060"],
                                      body: Data())
        }
        let client = HostHTTPClient(sourceID: QualifiedSourceID(rawValue: "repo/source"),
                                    allowedOrigins: ["https://example.com"], transport: transport,
                                    resolver: FixedHostResolver(addresses: ["93.184.216.34"]),
                                    rateLimiters: registry)
        _ = try await client.request(HostHTTPRequest(url: URL(string: "https://example.com/a")!))
        _ = try await client.request(HostHTTPRequest(url: URL(string: "https://example.com/b")!))
        #expect((await sleeper.dates()).map { $0.timeIntervalSince(now) } == [0, 1])
    }
}

private struct FixedRateLimiterClock: RateLimiterClock {
    var date = Date(timeIntervalSinceReferenceDate: 0)
    func now() -> Date { date }
}

private actor RecordingRateLimiterSleeper: RateLimiterSleeper {
    private var recorded: [Date] = []

    func sleep(until date: Date) async throws {
        try Task.checkCancellation()
        recorded.append(date)
    }

    func dates() -> [Date] { recorded }
}

/// Holds sleeps for the listed dates until `open()`; every other sleep returns at once.
private actor GatedRateLimiterSleeper: RateLimiterSleeper {
    private let blocking: Set<Date>
    private var recorded: [Date] = []
    private var isOpen = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var countWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init(blocking: Set<Date>) { self.blocking = blocking }

    func sleep(until date: Date) async throws {
        recorded.append(date)
        guard blocking.contains(date), !isOpen else { return }
        await withCheckedContinuation { continuation in
            blocked.append(continuation)
            if let waiter = countWaiter, blocked.count >= waiter.count {
                countWaiter = nil
                waiter.continuation.resume()
            }
        }
    }

    func waitForBlockedSleepers(_ count: Int) async {
        guard blocked.count < count else { return }
        await withCheckedContinuation { countWaiter = (count, $0) }
    }

    func open() {
        isOpen = true
        blocked.forEach { $0.resume() }
        blocked = []
    }

    func dates() -> [Date] { recorded }
}

private actor BlockingRateLimiterSleeper: RateLimiterSleeper {
    private var recorded: [Date] = []
    private var secondSleepWaiter: CheckedContinuation<Void, Never>?

    func waitForSecondSleep() async {
        guard recorded.count < 2 else { return }
        await withCheckedContinuation { secondSleepWaiter = $0 }
    }

    func sleep(until date: Date) async throws {
        recorded.append(date)
        if recorded.count == 2 {
            secondSleepWaiter?.resume()
            secondSleepWaiter = nil
        }
        if recorded.count == 2 {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    func dates() -> [Date] { recorded }
}
/// Keep the public image URL in the synthetic response so only the real peer metric
/// can reject the loopback fetch in ImageCache's integration test.
private struct OriginalImageURLFetcher: URLSessionDataFetching {
    let real: any URLSessionDataFetching

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult {
        let result = try await real.fetch(request)
        guard let url = request.url, let http = result.response as? HTTPURLResponse,
              let response = HTTPURLResponse(url: url, statusCode: http.statusCode,
                                             httpVersion: nil, headerFields: nil) else {
            return result
        }
        return URLSessionFetchResult(data: result.data, response: response,
                                     connectedPeerAddress: result.connectedPeerAddress,
                                     resourceFetchType: result.resourceFetchType)
    }
}
