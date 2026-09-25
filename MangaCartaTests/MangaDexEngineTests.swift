//
//  MangaDexEngineTests.swift
//  MangaCartaTests
//
//  The MangaDex extension engine (no-built-in-Sources slice 5), run exactly as an
//  installed Source runs: `ExtensionSource` → `ExtensionRuntime` → `host.http` →
//  `HostHTTPClient`. Only the transport is fake, and it serves captured MangaDex JSON,
//  so URL policy, redirects, rate limiting and result validation are all the real ones.
//
//  The engine and index under `__Fixtures__/mangadex/` are the copies published to the
//  engines repository; `testIndexPinsThisEngine` keeps the two from drifting.
//

import CryptoKit
import XCTest
@testable import MangaCarta

enum MangaDexFixtures {
    static var directory: URL { FixtureSite.root.appendingPathComponent("mangadex") }

    static let script: String = {
        let url = directory.appendingPathComponent("engine.js")
        guard let data = try? Data(contentsOf: url) else { preconditionFailure("missing \(url.path)") }
        return String(decoding: data, as: UTF8.self)
    }()

    static let index: [String: Any] = {
        let url = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            preconditionFailure("missing or malformed \(url.path)")
        }
        return root
    }()

    static var bundle: [String: Any] {
        ((index["bundles"] as? [[String: Any]])?.first)!
    }

    static let declarationJSON: String = {
        let source = ((bundle["sources"] as? [[String: Any]])?.first)!
        let data = try! JSONSerialization.data(withJSONObject: source)
        return String(decoding: data, as: UTF8.self)
    }()

    static func body(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("api").appendingPathComponent(file))
    }
}

/// Serves captured MangaDex JSON by canonical URL (query order normalized). An unrouted
/// URL is a test bug, so it answers 599 with the URL in the body rather than guessing.
actor MangaDexFixtureTransport: HostHTTPTransport {
    private struct Route { let status: Int; let headers: [String: String]; let file: String? }
    private var routes: [String: Route] = [:]
    private var urls: [String] = []

    func route(_ url: String, to file: String) {
        route(url, status: 200, headers: ["Content-Type": "application/json"], file: file)
    }

    func route(_ url: String, status: Int, headers: [String: String], file: String?) {
        routes[FixtureSite.canonical(url)] = Route(status: status, headers: headers, file: file)
    }

    func requestedURLs() -> [String] { urls }

    func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse {
        let url = request.url!
        let key = FixtureSite.canonical(url.absoluteString)
        urls.append(key)
        guard let route = routes[key] else {
            return HostHTTPTransportResponse(statusCode: 599, url: url, headers: [:],
                                             body: Data("unrouted \(key)".utf8),
                                             connectedPeerAddress: "93.184.216.34")
        }
        let body = try route.file.map(MangaDexFixtures.body) ?? Data()
        return HostHTTPTransportResponse(statusCode: route.status, url: url,
                                         headers: route.headers, body: body,
                                         connectedPeerAddress: "93.184.216.34")
    }
}

private struct PublicResolver: HostNameResolving {
    func addresses(for host: String) async throws -> [String] { ["93.184.216.34"] }
}

/// The production factory's `host.http`, minus the network: real policy, real client.
final class MangaDexFixtureHost: ExtensionSourceHosting {
    let transport = MangaDexFixtureTransport()

    func capabilities(for declaration: SourceDeclaration,
                      operation: SourceOperation,
                      invocationID: UUID) -> [ExtensionHostCapability] {
        let client = HostHTTPClient(sourceID: declaration.qualifiedId,
                                    allowedOrigins: declaration.network.httpOrigins,
                                    transport: transport,
                                    resolver: PublicResolver())
        return [HostHTTPJSCapability(client: client)]
    }
}

@MainActor
final class MangaDexEngineTests: XCTestCase {

    private static let qualifiedID = "6f1d9c2e-4b7a-4c1e-9e3d-2a8b5c7d1f00:mangadex"

    private var lifecycle: SourceLifecycleRegistry!
    private var host: MangaDexFixtureHost!

    override func setUp() {
        super.setUp()
        lifecycle = SourceLifecycleRegistry()
        host = MangaDexFixtureHost()
    }

    private func declaration() throws -> SourceDeclaration {
        try PortFixtures.declaration(MangaDexFixtures.declarationJSON, qualifiedId: Self.qualifiedID)
    }

    private func makeSource() throws -> ExtensionSource {
        let declaration = try declaration()
        try lifecycle.register(declaration)
        return ExtensionSource(declaration: declaration,
                               script: MangaDexFixtures.script,
                               isNSFW: false,
                               lifecycle: lifecycle,
                               host: host)
    }

    func testTheDeclarationValidatesUnderHostAPI12() throws {
        let declaration = try declaration()
        XCTAssertEqual(declaration.network.httpOrigins, ["https://api.mangadex.org"])
        XCTAssertEqual(declaration.network.assetOrigins,
                       ["https://uploads.mangadex.org", "https://*.mangadex.network"])
    }
}
