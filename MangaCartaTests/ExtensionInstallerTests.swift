//
//  ExtensionInstallerTests.swift
//  MangaCartaTests
//
//  Phase 4 acceptance criteria 3, 4, 5 and 6 — and the behavioural half of 2 — against
//  `ExtensionInstaller` over a real `RepositoryStore`, a real `SourceLifecycleRegistry`,
//  the app's real pin store, Work store and `host.storage` repository, with only the
//  network faked. The repository format design's "Repository identity", "Operations" and
//  "What the installer persists" sections are what each test is checked against.
//
//  Every fixture declaration goes through `SourceDeclarationValidator` from JSON, because
//  since #161 there is no other way to obtain one.
//

import CryptoKit
import XCTest
@testable import MangaCarta

// MARK: - Fakes

/// The network, scripted per URL. Mutated only from the main thread by the test.
final class FakeRepositoryTransport: RepositoryTransport, @unchecked Sendable {
    var indexes: [URL: RepositoryIndexFetchOutcome] = [:]
    var scripts: [URL: Data] = [:]
    var indexFetches: [URL] = []
    var scriptFetches: [URL] = []

    struct Unreachable: Error {}

    func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome {
        indexFetches.append(url)
        guard let outcome = indexes[url] else { throw Unreachable() }
        return outcome
    }

    func fetchScript(at url: URL) async throws -> Data {
        scriptFetches.append(url)
        guard let data = scripts[url] else { throw Unreachable() }
        return data
    }
}

private final class StubRepositoryURLProtocol: URLProtocol {
    static var responses: [String: (Int, Data, [String: String])] = [:]
    static var shouldFail = false
    static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURLs.append(request.url?.absoluteString ?? "<missing>")
        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url, let (status, data, headers) = Self.responses[url.absoluteString],
              let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLSessionRepositoryTransportTests: XCTestCase {
    private let indexURL = URL(string: "https://repo.test/index.json")!
    private let scriptURL = URL(string: "https://repo.test/engine.js")!

    func testRepositorySessionsBypassConfiguredSystemProxies() {
        XCTAssertTrue(URLSessionRepositoryTransport.sessionConfiguration().connectionProxyDictionary?.isEmpty == true)
    }

    /// Every host resolves to a public address unless a test says otherwise.
    private func makeTransport(resolvingTo addresses: [String] = ["93.184.216.34"])
        -> URLSessionRepositoryTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRepositoryURLProtocol.self]
        let realFetcher = URLSessionDataFetcher(configuration: configuration) { _ in nil }
        return URLSessionRepositoryTransport(
            resolver: RepositoryFixedResolver(addresses: addresses),
            fetcher: PublicPeerFetcher(wrapping: realFetcher))
    }

    override func setUp() {
        StubRepositoryURLProtocol.responses = [:]
        StubRepositoryURLProtocol.shouldFail = false
        StubRepositoryURLProtocol.requestedURLs = []
    }

    /// Asserts `operation` is refused by destination policy and that nothing was requested.
    private func assertRefusedBeforeAnyRequest(_ operation: () async throws -> Void,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("expected the destination to be refused", file: file, line: line)
        } catch let error as RepositoryTransportError {
            guard case .destinationRefused = error else {
                return XCTFail("expected destinationRefused, got \(error)", file: file, line: line)
            }
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        } catch {
            XCTFail("expected RepositoryTransportError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(StubRepositoryURLProtocol.requestedURLs, [], file: file, line: line)
    }

    func testPlainHTTPIndexURLIsRefusedBeforeAnyRequest() async {
        let insecure = URL(string: "http://repo.test/index.json")!
        StubRepositoryURLProtocol.responses[insecure.absoluteString] = (200, Data(), [:])
        await assertRefusedBeforeAnyRequest { _ = try await makeTransport().fetchIndex(at: insecure) }
    }

    func testIndexHostResolvingToAPrivateAddressIsRefusedBeforeAnyRequest() async {
        StubRepositoryURLProtocol.responses[indexURL.absoluteString] = (200, Data(), [:])
        let transport = makeTransport(resolvingTo: ["192.168.1.1"])
        await assertRefusedBeforeAnyRequest { _ = try await transport.fetchIndex(at: indexURL) }
    }

    func testIndexWithPrivateConnectedPeerIsRefusedAfterPublicDNS() async throws {
        let bytes = try Data(contentsOf: PortFixtures.packageDirectory.appendingPathComponent("index.json"))
        let fetcher = FixedMetricsFetcher(result: URLSessionFetchResult(
            data: bytes,
            response: HTTPURLResponse(url: indexURL, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!,
            connectedPeerAddress: "10.0.0.5"))
        let transport = URLSessionRepositoryTransport(
            resolver: RepositoryFixedResolver(addresses: ["93.184.216.34"]),
            fetcher: fetcher)

        do {
            _ = try await transport.fetchIndex(at: indexURL)
            XCTFail("private connected peer must be refused")
        } catch let error as RepositoryTransportError {
            guard case .destinationRefused = error else {
                XCTFail("expected destinationRefused, got \(error)")
                return
            }
        }
    }

    func testIndexWithMissingConnectedPeerIsRefused() async throws {
        let bytes = try Data(contentsOf: PortFixtures.packageDirectory.appendingPathComponent("index.json"))
        let fetcher = FixedMetricsFetcher(result: URLSessionFetchResult(
            data: bytes,
            response: HTTPURLResponse(url: indexURL, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!,
            connectedPeerAddress: nil))
        let transport = URLSessionRepositoryTransport(
            resolver: RepositoryFixedResolver(addresses: ["93.184.216.34"]),
            fetcher: fetcher)

        do {
            _ = try await transport.fetchIndex(at: indexURL)
            XCTFail("missing connected peer must be refused")
        } catch let error as RepositoryTransportError {
            guard case .destinationRefused = error else {
                XCTFail("expected destinationRefused, got \(error)")
                return
            }
        }
    }

    func testIndexHostWithAnyNonPublicAddressAmongPublicOnesIsRefused() async {
        StubRepositoryURLProtocol.responses[indexURL.absoluteString] = (200, Data(), [:])
        let transport = makeTransport(resolvingTo: ["93.184.216.34", "127.0.0.1"])
        await assertRefusedBeforeAnyRequest { _ = try await transport.fetchIndex(at: indexURL) }
    }

    func testScriptHostResolvingToLinkLocalIsRefusedBeforeAnyRequest() async {
        StubRepositoryURLProtocol.responses[scriptURL.absoluteString] = (200, Data("x".utf8), [:])
        let transport = makeTransport(resolvingTo: ["169.254.169.254"])
        await assertRefusedBeforeAnyRequest { _ = try await transport.fetchScript(at: scriptURL) }
    }

    func testPlainHTTPScriptURLIsRefusedBeforeAnyRequest() async {
        let insecure = URL(string: "http://repo.test/engine.js")!
        StubRepositoryURLProtocol.responses[insecure.absoluteString] = (200, Data("x".utf8), [:])
        await assertRefusedBeforeAnyRequest { _ = try await makeTransport().fetchScript(at: insecure) }
    }

    func testATemporaryRedirectIsNotFollowed() async throws {
        let target = "https://elsewhere.test/engine.js"
        StubRepositoryURLProtocol.responses[scriptURL.absoluteString] = (302, Data(), ["Location": target])
        StubRepositoryURLProtocol.responses[target] = (200, Data("x".utf8), [:])
        do {
            _ = try await makeTransport().fetchScript(at: scriptURL)
            XCTFail("a redirect must not be followed")
        } catch let error as RepositoryTransportError {
            XCTAssertEqual(error, .httpStatus(302))
        }
        XCTAssertEqual(StubRepositoryURLProtocol.requestedURLs, [scriptURL.absoluteString])
    }

    func testIndexIsParsedAndValidatedBeforeReturning() async throws {
        let fixtureDirectory = PortFixtures.packageDirectory
        let bytes = try Data(contentsOf: fixtureDirectory.appendingPathComponent("index.json"))
        StubRepositoryURLProtocol.responses[indexURL.absoluteString] = (200, bytes, [:])

        let outcome = try await makeTransport().fetchIndex(at: indexURL)
        guard case .index(let index) = outcome else { return XCTFail("expected parsed index") }
        XCTAssertEqual(index.name, "WeebCentral")
        XCTAssertEqual(index.bundles.map(\.id), ["html-selector"])
    }

    func testPermanentIndexRedirectIsReturnedForConfirmation() async throws {
        StubRepositoryURLProtocol.responses[indexURL.absoluteString] =
            (301, Data(), ["Location": "https://new-repo.test/index.json"])

        let outcome = try await makeTransport().fetchIndex(at: indexURL)
        XCTAssertEqual(outcome, .movedPermanently(to: URL(string: "https://new-repo.test/index.json")!))
    }

    func testScriptAtLimitIsAcceptedAndOneByteOverIsRefused() async throws {
        let transport = makeTransport()
        let atLimit = Data(repeating: 0x61, count: RepositoryFormatLimits.maximumScriptBytes)
        StubRepositoryURLProtocol.responses[scriptURL.absoluteString] = (200, atLimit, [:])
        let fetchedAtLimit = try await transport.fetchScript(at: scriptURL)
        XCTAssertEqual(fetchedAtLimit.count, atLimit.count)

        let overLimit = Data(repeating: 0x61, count: RepositoryFormatLimits.maximumScriptBytes + 1)
        StubRepositoryURLProtocol.responses[scriptURL.absoluteString] = (200, overLimit, [:])
        do {
            _ = try await transport.fetchScript(at: scriptURL)
            XCTFail("oversized script must be refused")
        } catch let error as RepositoryTransportError {
            XCTAssertEqual(error, .scriptTooLarge(actualBytes: overLimit.count,
                                                  maximumBytes: RepositoryFormatLimits.maximumScriptBytes))
            XCTAssertTrue(error.localizedDescription.contains("script"))
        }
    }

    func testNetworkFailureHasSentenceWorthyCopy() async throws {
        StubRepositoryURLProtocol.shouldFail = true
        do {
            _ = try await makeTransport().fetchIndex(at: indexURL)
            XCTFail("expected network failure")
        } catch let error as RepositoryTransportError {
            XCTAssertEqual(error.localizedDescription,
                           "Couldn't reach the repository. Check the URL and your connection, then try again.")
        }
    }
}

private struct FixedMetricsFetcher: URLSessionDataFetching {
    let result: URLSessionFetchResult

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult { result }
}

private struct PublicPeerFetcher: URLSessionDataFetching {
    let wrapped: any URLSessionDataFetching

    init(wrapping wrapped: any URLSessionDataFetching) {
        self.wrapped = wrapped
    }

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult {
        let result = try await wrapped.fetch(request)
        return URLSessionFetchResult(data: result.data,
                                     response: result.response,
                                     connectedPeerAddress: result.connectedPeerAddress
                                        ?? "93.184.216.34")
    }
}

private struct RepositoryFixedResolver: HostNameResolving {
    let addresses: [String]

    func addresses(for host: String) async throws -> [String] { addresses }
}

/// Erases the real `host.storage` namespace and records that it did, so a preservation
/// test can prove the installer never called it and an erase test can prove it did.
final class RecordingDataEraser: SourceDataErasing, @unchecked Sendable {
    let storage: HostStorageRepository
    var erased: [QualifiedSourceID] = []

    init(storage: HostStorageRepository) { self.storage = storage }

    func eraseData(for id: QualifiedSourceID) async throws {
        erased.append(id)
        try await storage.eraseUserData(for: id)
    }
}

// MARK: - Tests

@MainActor
final class ExtensionInstallerTests: XCTestCase {

    private var directory: URL!
    private var transport: FakeRepositoryTransport!
    private var storage: HostStorageRepository!
    private var eraser: RecordingDataEraser!
    private var acknowledgements: [AdultInstallAcknowledgement] = []
    private var acknowledgementAnswer = true

    private let urlA = URL(string: "https://a.example.test/index.json")!
    private let urlB = URL(string: "https://b.example.test/index.json")!
    private let scriptURL = URL(string: "https://cdn.example.test/engine/1/engine.js")!
    private let scriptURL2 = URL(string: "https://cdn.example.test/engine/2/engine.js")!
    private let scriptV1 = Data("registerEngine('madara', {}) // v1".utf8)
    private let scriptV2 = Data("registerEngine('madara', {}) // v2".utf8)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionInstallerTests-\(UUID().uuidString)", isDirectory: true)
        transport = FakeRepositoryTransport()
        transport.scripts[scriptURL] = scriptV1
        transport.scripts[scriptURL2] = scriptV2
        storage = try HostStorageRepository(directory: directory)
        eraser = RecordingDataEraser(storage: storage)
        acknowledgements = []
        acknowledgementAnswer = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    private func makeInstaller(
        store: RepositoryStore? = nil,
        registry: SourceLifecycleRegistry? = nil,
        hostAPI: HostAPISupport = .v1,
        updateRule: @escaping (SourceDeclaration, SourceDeclaration) -> SourceDeclarationError?
            = SourceDeclarationValidator.validateUpdate
    ) -> ExtensionInstaller {
        ExtensionInstaller(store: store ?? RepositoryStore(directory: directory),
                           registry: registry ?? SourceLifecycleRegistry(),
                           transport: transport,
                           dataEraser: eraser,
                           hostAPI: hostAPI,
                           acknowledgeAdult: { [weak self] acknowledgement in
                               self?.acknowledgements.append(acknowledgement)
                               return self?.acknowledgementAnswer ?? false
                           },
                           updateRule: updateRule)
    }

    private func declaration(localId: String,
                             name: String = "Example Manga",
                             engine: String = "madara",
                             adult: String = "none",
                             configuration: JSONValue = .object(["baseURL": .string("https://example.test")]),
                             capabilities: [String: Bool] = ["search": true, "popular": true, "detail": true,
                                                             "chapters": true, "pages": true],
                             hostAPI: (String, String) = ("1.0", "2.0")) -> JSONValue {
        .object([
            "localId": .string(localId),
            "name": .string(name),
            "engine": .string(engine),
            "configuration": configuration,
            "adult": .string(adult),
            "capabilities": .object(capabilities.mapValues { .bool($0) }),
            "languages": .object(["mode": .string("fixed"), "values": .array([.string("en")])]),
            "network": .object(["httpOrigins": .array([.string("https://example.test")])]),
            "hostAPI": .object(["minimum": .string(hostAPI.0), "maximumExclusive": .string(hostAPI.1)])
        ])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bundle(id: String = "engine",
                        version: Int = 1,
                        script: URL? = nil,
                        scriptData: Data? = nil,
                        sources: [JSONValue]) -> RepositoryBundle {
        let url = script ?? scriptURL
        return RepositoryBundle(id: id,
                                version: version,
                                scriptURL: url,
                                scriptSHA256: sha256(scriptData ?? transport.scripts[url] ?? Data()),
                                sources: sources.map(served))
    }

    private func served(_ raw: JSONValue) -> RepositorySourceRecord {
        RepositorySourceRecord(rawJSON: raw, localID: raw.objectValue?["localId"]?.stringValue)
    }

    private func index(name: String = "Example Repository", bundles: [RepositoryBundle]) -> RepositoryIndex {
        RepositoryIndex(format: 1, name: name, bundles: bundles)
    }

    private func serve(_ index: RepositoryIndex, at url: URL) {
        transport.indexes[url] = .index(index)
    }

    private func isVersion4(_ uuid: UUID) -> Bool {
        (uuid.uuid.6 >> 4) == 4 && (uuid.uuid.8 >> 6) == 0b10
    }

    /// Adds `urlA` serving one bundle with `site-1`, installs it, returns the ids.
    private func addAndInstallSite1(_ installer: ExtensionInstaller) async throws -> (UUID, QualifiedSourceID) {
        serve(index(bundles: [bundle(sources: [declaration(localId: "site-1")])]), at: urlA)
        let repository = try await installer.addRepository(at: urlA)
        let record = try await installer.install(localId: "site-1", from: repository.id)
        return (repository.id, record.qualifiedId)
    }

    // MARK: - Criterion 2, behavioural half: the registry receives the validator's output

    func testInstallHandsTheRegistryTheValidatorsOutputFromTheRawDeclaration() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let raw = declaration(localId: "site-1", name: "As Served")
        serve(index(bundles: [bundle(sources: [raw])]), at: urlA)

        let repository = try await installer.addRepository(at: urlA)
        XCTAssertNil(registry.state(for: ExtensionInstaller.qualifiedID(repositoryID: repository.id,
                                                                        localId: "site-1")),
                     "adding a repository installs nothing")

        let record = try await installer.install(localId: "site-1", from: repository.id)

        let expected = try SourceDeclarationValidator
            .validate(json: raw, qualifiedId: record.qualifiedId, hostAPI: .v1).get()
        XCTAssertEqual(registry.declaration(for: record.qualifiedId), expected)
        XCTAssertEqual(record.declaration, raw, "the record keeps the declaration as served, not typed")
        XCTAssertEqual(installer.store.scriptData(for: "engine", in: repository.id), scriptV1)
    }

    // MARK: - Criterion 3: identity is minted, survives a URL change, differs per repository

    func testAddMintsAVersion4UUIDThatIsNotDerivedFromTheURL() async throws {
        let installer = makeInstaller()
        serve(index(bundles: []), at: urlA)

        let first = try await installer.addRepository(at: urlA)
        XCTAssertTrue(isVersion4(first.id), "\(first.id) is not a version 4 UUID")
        XCTAssertEqual(first.indexURL, urlA)
        XCTAssertEqual(first.state, .active)
        XCTAssertNil(first.boundKey, "boundKey is reserved and unset in format 1")

        // The same URL, after the reader ended the identity, is a repository the app has
        // not seen: a new mint, not a function of the URL.
        try installer.removeRepository(first.id)
        try await installer.eraseData(forRepository: first.id)
        let again = try await installer.addRepository(at: urlA)
        XCTAssertNotEqual(again.id, first.id)
        XCTAssertTrue(isVersion4(again.id))
    }

    func testQualifiedIDIsTheLowercaseUUIDAColonAndTheLocalId() async throws {
        let installer = makeInstaller()
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        XCTAssertEqual(qualifiedId.rawValue, "\(repositoryID.uuidString.lowercased()):site-1")
    }

    func testChangeRepositoryURLKeepsTheIdentityAndEveryQualifiedID() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        serve(index(name: "Moved", bundles: [bundle(sources: [declaration(localId: "site-1", name: "Renamed")])]),
              at: urlB)

        let outcome = try await installer.changeRepositoryURL(repositoryID, to: urlB)

        guard case .refreshed(let listing) = outcome else { return XCTFail("expected refreshed, got \(outcome)") }
        let record = try XCTUnwrap(installer.store.repository(repositoryID))
        XCTAssertEqual(record.id, repositoryID)
        XCTAssertEqual(record.indexURL, urlB)
        XCTAssertEqual(record.name, "Moved")
        XCTAssertEqual(installer.store.repositories.count, 1, "a move is not a second repository")
        XCTAssertEqual(listing.entry(localId: "site-1")?.declaration?.qualifiedId, qualifiedId,
                       "the listing at the new URL is minted under the existing identity")
        XCTAssertTrue(registry.isActive(qualifiedId))
        XCTAssertEqual(installer.store.source(qualifiedId)?.qualifiedId, qualifiedId)
    }

    func testTwoRepositoriesServingTheSameLocalIdGetDifferentQualifiedIDs() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        serve(index(bundles: [bundle(sources: [declaration(localId: "site-1", name: "A's")])]), at: urlA)
        serve(index(bundles: [bundle(sources: [declaration(localId: "site-1", name: "B's")])]), at: urlB)

        let repositoryA = try await installer.addRepository(at: urlA)
        let repositoryB = try await installer.addRepository(at: urlB)
        XCTAssertNotEqual(repositoryA.id, repositoryB.id, "a second URL is a fork, not a move")

        let installedA = try await installer.install(localId: "site-1", from: repositoryA.id)
        let installedB = try await installer.install(localId: "site-1", from: repositoryB.id)

        XCTAssertNotEqual(installedA.qualifiedId, installedB.qualifiedId)
        XCTAssertEqual(registry.declaration(for: installedA.qualifiedId)?.name, "A's")
        XCTAssertEqual(registry.declaration(for: installedB.qualifiedId)?.name, "B's")

        try installer.disable(installedA.qualifiedId)
        XCTAssertFalse(registry.isActive(installedA.qualifiedId))
        XCTAssertTrue(registry.isActive(installedB.qualifiedId), "repository A's gesture never reaches B's Source")
    }

    func testReAddingARemovedRepositorysURLReconnectsItsIdentityByDefault() async throws {
        let installer = makeInstaller()
        let (repositoryID, _) = try await addAndInstallSite1(installer)
        try installer.removeRepository(repositoryID)

        let reconnected = try await installer.addRepository(at: urlA)
        XCTAssertEqual(reconnected.id, repositoryID, "a change of mind, not a replacement")
        XCTAssertEqual(reconnected.state, .active)

        try installer.removeRepository(repositoryID)
        let asNew = try await installer.addRepository(at: urlA, reconnectRemoved: false)
        XCTAssertNotEqual(asNew.id, repositoryID, "'add as new' is the offered alternative")
    }

    func testAPermanentRedirectAppliesNothingUntilTheReaderConfirms() async throws {
        let installer = makeInstaller()
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        let before = try XCTUnwrap(installer.store.repository(repositoryID))
        transport.indexes[urlA] = .movedPermanently(to: urlB)
        serve(index(name: "At B", bundles: [bundle(sources: [declaration(localId: "site-1")])]), at: urlB)

        let outcome = try await installer.refresh(repositoryID)

        XCTAssertEqual(outcome, .movedPermanently(to: urlB))
        XCTAssertEqual(installer.store.repository(repositoryID), before, "nothing applied before confirmation")
        XCTAssertEqual(installer.listings[repositoryID]?.index.name, "Example Repository")

        let confirmed = try await installer.changeRepositoryURL(repositoryID, to: urlB)
        guard case .refreshed(let listing) = confirmed else { return XCTFail("expected refreshed") }
        XCTAssertEqual(installer.store.repository(repositoryID)?.indexURL, urlB)
        XCTAssertEqual(listing.entry(localId: "site-1")?.declaration?.qualifiedId, qualifiedId)
    }

    // MARK: - Criterion 4: a qualified-id collision is rejected, naming both

    func testAnIndexListingOneLocalIdTwiceIsRejectedNamingBothOccurrences() async throws {
        let installer = makeInstaller()
        serve(index(bundles: [
            bundle(id: "engine-a", sources: [declaration(localId: "site-1"), declaration(localId: "site-2")]),
            bundle(id: "engine-b", sources: [declaration(localId: "site-1")])
        ]), at: urlA)

        do {
            _ = try await installer.addRepository(at: urlA)
            XCTFail("a colliding index must be refused")
        } catch let error as ExtensionInstallError {
            XCTAssertEqual(error, .qualifiedIDCollision(localId: "site-1",
                                                        first: "bundles[0].sources[0]",
                                                        second: "bundles[1].sources[0]"))
            XCTAssertTrue(error.message.contains("bundles[0].sources[0]"))
            XCTAssertTrue(error.message.contains("bundles[1].sources[0]"))
        }
        XCTAssertTrue(installer.store.repositories.isEmpty, "the provisional identity is discarded")
        XCTAssertTrue(installer.listings.isEmpty)
    }

    func testACollisionOnRefreshLeavesThePreviousListingAndRecordInPlace() async throws {
        let installer = makeInstaller()
        let (repositoryID, _) = try await addAndInstallSite1(installer)
        let before = try XCTUnwrap(installer.store.repository(repositoryID))
        let listingBefore = try XCTUnwrap(installer.listings[repositoryID])
        serve(index(name: "Broken", bundles: [
            bundle(sources: [declaration(localId: "site-1"), declaration(localId: "site-1")])
        ]), at: urlA)

        await XCTAssertThrowsErrorAsync(try await installer.refresh(repositoryID)) { error in
            XCTAssertEqual(error as? ExtensionInstallError,
                           .qualifiedIDCollision(localId: "site-1",
                                                 first: "bundles[0].sources[0]",
                                                 second: "bundles[0].sources[1]"))
        }
        XCTAssertEqual(installer.store.repository(repositoryID), before)
        XCTAssertEqual(installer.listings[repositoryID], listingBefore)
    }

    // MARK: - Criterion 5: what an update may change, and a refusal leaves the Source intact

    private func serveUpdatedBundle(at url: URL, declaration: JSONValue) {
        serve(index(bundles: [bundle(version: 2, script: scriptURL2, sources: [declaration])]), at: url)
    }

    func testAnUpdateMayChangeNameEngineConfigurationAndCapabilitiesButNotIdentity() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        let updated = declaration(localId: "site-1",
                                  name: "New Name",
                                  engine: "generic",
                                  configuration: .object(["baseURL": .string("https://moved.example.test")]),
                                  capabilities: ["search": true, "latestUpdates": true, "detail": true,
                                                 "chapters": true, "pages": true, "webURL": true])
        serveUpdatedBundle(at: urlA, declaration: updated)

        guard case .refreshed(let listing) = try await installer.refresh(repositoryID) else {
            return XCTFail("expected a refreshed listing")
        }
        XCTAssertEqual(listing.availableUpdates, ["engine": 2])

        try await installer.updateBundle("engine", in: repositoryID)

        let declaration = try XCTUnwrap(registry.declaration(for: qualifiedId))
        XCTAssertEqual(declaration.qualifiedId, qualifiedId)
        XCTAssertEqual(declaration.localId, "site-1")
        XCTAssertEqual(declaration.name, "New Name")
        XCTAssertEqual(declaration.engine, "generic")
        XCTAssertEqual(declaration.configuration, .object(["baseURL": .string("https://moved.example.test")]))
        XCTAssertTrue(declaration.capabilities.supports(.latestUpdates))
        XCTAssertFalse(declaration.capabilities.supports(.popular))
        XCTAssertTrue(registry.isActive(qualifiedId))

        let record = try XCTUnwrap(installer.store.source(qualifiedId))
        XCTAssertEqual(record.declaration, updated, "the record carries the new declaration as served")
        XCTAssertEqual(installer.store.bundle("engine", in: repositoryID)?.version, 2)
        XCTAssertEqual(installer.store.bundle("engine", in: repositoryID)?.scriptSHA256, sha256(scriptV2))
        XCTAssertEqual(installer.store.scriptData(for: "engine", in: repositoryID), scriptV2)
        XCTAssertEqual(installer.store.sources(in: repositoryID).count, 1, "an update is not a second Source")
    }

    func testAnUpdateRuleRefusalSurfacesAsAFailedUpdateThatLeavesTheSourceIntact() async throws {
        // Honest inputs cannot reach this refusal — the id is minted from the same
        // `localId` the update is matched on — so the rule is injected to prove the
        // surfacing and the atomicity, which is what criterion 5 claims.
        let registry = SourceLifecycleRegistry()
        var refusals = 0
        let installer = makeInstaller(registry: registry) { _, _ in
            refusals += 1
            return .qualifiedIdentityChanged
        }
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        let recordBefore = try XCTUnwrap(installer.store.source(qualifiedId))
        let declarationBefore = try XCTUnwrap(registry.declaration(for: qualifiedId))
        serveUpdatedBundle(at: urlA, declaration: declaration(localId: "site-1", name: "New Name"))
        _ = try await installer.refresh(repositoryID)

        await XCTAssertThrowsErrorAsync(try await installer.updateBundle("engine", in: repositoryID)) { error in
            XCTAssertEqual(error as? ExtensionInstallError,
                           .updateRefused(localId: "site-1", .qualifiedIdentityChanged))
        }

        XCTAssertEqual(refusals, 1)
        XCTAssertEqual(registry.declaration(for: qualifiedId), declarationBefore)
        XCTAssertTrue(registry.isActive(qualifiedId))
        XCTAssertEqual(installer.store.source(qualifiedId), recordBefore)
        XCTAssertEqual(installer.store.bundle("engine", in: repositoryID)?.version, 1)
        XCTAssertEqual(installer.store.scriptData(for: "engine", in: repositoryID), scriptV1)
    }

    func testAnUpdateIsAllOrNothingAcrossEveryInstalledSourceOfTheBundle() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        serve(index(bundles: [bundle(sources: [declaration(localId: "a"), declaration(localId: "b")])]), at: urlA)
        let repository = try await installer.addRepository(at: urlA)
        let installedA = try await installer.install(localId: "a", from: repository.id)
        let installedB = try await installer.install(localId: "b", from: repository.id)

        // The new bundle's `b` no longer validates: its adult class is gone.
        var brokenB = declaration(localId: "b", name: "B v2").objectValue!
        brokenB["adult"] = nil
        serve(index(bundles: [bundle(version: 2, script: scriptURL2,
                                     sources: [declaration(localId: "a", name: "A v2"), .object(brokenB)])]),
              at: urlA)
        _ = try await installer.refresh(repository.id)

        await XCTAssertThrowsErrorAsync(try await installer.updateBundle("engine", in: repository.id)) { error in
            XCTAssertEqual(error as? ExtensionInstallError,
                           .declarationRejected(localId: "b", .missingKey(path: "adult")))
        }

        XCTAssertEqual(registry.declaration(for: installedA.qualifiedId)?.name, "Example Manga",
                       "a sibling that would have validated is not updated on its own")
        XCTAssertEqual(registry.declaration(for: installedB.qualifiedId)?.name, "Example Manga")
        XCTAssertEqual(installer.store.bundle("engine", in: repository.id)?.version, 1)
        XCTAssertEqual(installer.store.scriptData(for: "engine", in: repository.id), scriptV1)
    }

    func testAScriptWhoseDigestDiffersFromTheIndexRefusesTheUpdateNamingBothDigests() async throws {
        let installer = makeInstaller()
        let (repositoryID, _) = try await addAndInstallSite1(installer)
        let lying = RepositoryBundle(id: "engine", version: 2, scriptURL: scriptURL2,
                                     scriptSHA256: sha256(Data("something else".utf8)),
                                     sources: [served(declaration(localId: "site-1"))])
        serve(index(bundles: [lying]), at: urlA)
        _ = try await installer.refresh(repositoryID)

        await XCTAssertThrowsErrorAsync(try await installer.updateBundle("engine", in: repositoryID)) { error in
            XCTAssertEqual(error as? ExtensionInstallError,
                           .scriptDigestMismatch(expected: lying.scriptSHA256, actual: self.sha256(self.scriptV2)))
        }
        XCTAssertEqual(installer.store.bundle("engine", in: repositoryID)?.version, 1)
        XCTAssertEqual(installer.store.scriptData(for: "engine", in: repositoryID), scriptV1)
    }

    func testAnEqualOrLowerBundleVersionIsNotAnUpdate() async throws {
        let installer = makeInstaller()
        let (repositoryID, _) = try await addAndInstallSite1(installer)

        // Same version, republished with different bytes: a diagnostic, not an update.
        serve(index(bundles: [bundle(version: 1, script: scriptURL2, sources: [declaration(localId: "site-1")])]),
              at: urlA)
        guard case .refreshed(let same) = try await installer.refresh(repositoryID) else { return XCTFail("expected a refreshed listing") }
        XCTAssertEqual(same.availableUpdates, [:])
        await XCTAssertThrowsErrorAsync(try await installer.updateBundle("engine", in: repositoryID)) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .noUpdateAvailable(bundleId: "engine"))
        }

        serve(index(bundles: [bundle(version: 0, sources: [declaration(localId: "site-1")])]), at: urlA)
        guard case .refreshed(let lower) = try await installer.refresh(repositoryID) else { return XCTFail("expected a refreshed listing") }
        XCTAssertEqual(lower.availableUpdates, [:], "a lower version is not a downgrade offer")
    }

    func testADisabledSourceStaysDisabledThroughAnUpdate() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        try installer.disable(qualifiedId)
        serveUpdatedBundle(at: urlA, declaration: declaration(localId: "site-1", name: "New Name"))
        _ = try await installer.refresh(repositoryID)

        try await installer.updateBundle("engine", in: repositoryID)

        XCTAssertEqual(registry.state(for: qualifiedId), .disabled)
        XCTAssertEqual(registry.declaration(for: qualifiedId)?.name, "New Name")
        XCTAssertEqual(installer.store.source(qualifiedId)?.state, .disabled)
    }

    func testASourceTheFreshIndexNoLongerListsStaysInstalled() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        serve(index(bundles: [bundle(sources: [declaration(localId: "site-2")])]), at: urlA)

        guard case .refreshed(let listing) = try await installer.refresh(repositoryID) else {
            return XCTFail("expected a refreshed listing")
        }

        XCTAssertEqual(listing.noLongerListed, [qualifiedId])
        XCTAssertTrue(registry.isActive(qualifiedId))
        XCTAssertEqual(installer.store.source(qualifiedId)?.state, .registered)
        XCTAssertEqual(installer.store.scriptData(for: "engine", in: repositoryID), scriptV1,
                       "runnable from its local copy")
    }

    // MARK: - Criterion 6: disable, uninstall and reinstall preserve and reconnect

    func testDisableUninstallAndReinstallPreserveAndReconnectListingsPinsAndStorage() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        let installedAt = try XCTUnwrap(installer.store.source(qualifiedId)?.installedAt)

        // The reader's data, all keyed by the qualified id: a Work whose Listing is this
        // Source's, a per-Work pin on that Listing, and a `host.storage` value.
        let works = WorkStore(directory: directory)
        let manga = Manga(id: "manga-1", sourceId: qualifiedId.rawValue, title: "Title", description: "",
                          status: "ongoing", year: nil, coverURL: nil, malId: nil)
        let workID = works.mint(from: manga)
        let listing = ListingKey(sourceId: qualifiedId.rawValue, mangaId: "manga-1")
        let suite = "ExtensionInstallerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SourcePreferenceStore(defaults: defaults)
        preferences.choose(listing, for: workID)
        try await HostStorage(sourceID: qualifiedId, repository: storage).set("cursor", value: .int(7))

        func assertPreserved(_ phase: String) async throws {
            XCTAssertEqual(works.work(workID)?.listings, [listing], "Listing lost after \(phase)")
            XCTAssertEqual(preferences.choice(for: workID), listing, "pin lost after \(phase)")
            let stored = try await HostStorage(sourceID: qualifiedId, repository: storage).get("cursor")
            XCTAssertEqual(stored, .int(7), "storage lost after \(phase)")
            XCTAssertTrue(eraser.erased.isEmpty, "nothing here may erase")
        }

        try installer.disable(qualifiedId)
        XCTAssertEqual(registry.state(for: qualifiedId), .disabled)
        XCTAssertEqual(installer.store.source(qualifiedId)?.state, .disabled)
        try await assertPreserved("disable")

        try installer.enable(qualifiedId)
        XCTAssertTrue(registry.isActive(qualifiedId))
        try await assertPreserved("enable")

        try installer.uninstall(qualifiedId)
        XCTAssertEqual(registry.state(for: qualifiedId), .uninstalled)
        XCTAssertEqual(installer.store.source(qualifiedId)?.state, .uninstalled, "the record is retained")
        try await assertPreserved("uninstall")

        // Reinstall is an install against a Source whose record still exists.
        let reinstalled = try await installer.install(localId: "site-1", from: repositoryID)
        XCTAssertEqual(reinstalled.qualifiedId, qualifiedId, "the same identity, so everything reconnects")
        XCTAssertEqual(reinstalled.installedAt, installedAt)
        XCTAssertTrue(registry.isActive(qualifiedId))
        XCTAssertEqual(installer.store.sources(in: repositoryID).count, 1)
        try await assertPreserved("reinstall")
    }

    func testDisablePersistFailureLeavesRegistryRegistered() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (_, qualifiedId) = try await addAndInstallSite1(installer)
        let recordBefore = try XCTUnwrap(installer.store.source(qualifiedId))
        try makeStoreCommitFailing()

        await XCTAssertThrowsErrorAsync(try installer.disable(qualifiedId)) { error in
            guard case .persistence = error as? ExtensionInstallError else {
                return XCTFail("expected persistence failure, got \(error)")
            }
        }

        XCTAssertTrue(registry.isActive(qualifiedId))
        XCTAssertEqual(installer.store.source(qualifiedId), recordBefore)
    }

    func testRemoveRepositoryPersistFailureLeavesRegistryAndRecordsUnchanged() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        let repositoryBefore = try XCTUnwrap(installer.store.repository(repositoryID))
        let sourceBefore = try XCTUnwrap(installer.store.source(qualifiedId))
        try makeStoreCommitFailing()

        await XCTAssertThrowsErrorAsync(try installer.removeRepository(repositoryID)) { error in
            guard case .persistence = error as? ExtensionInstallError else {
                return XCTFail("expected persistence failure, got \(error)")
            }
        }

        XCTAssertTrue(registry.isActive(qualifiedId))
        XCTAssertEqual(installer.store.repository(repositoryID), repositoryBefore)
        XCTAssertEqual(installer.store.source(qualifiedId), sourceBefore)
    }

    func testCorruptRepositoryFileIsQuarantinedAndCommitRefusesToOverwriteIt() throws {
        let original = Data("{ definitely not valid JSON".utf8)
        let repositoryFile = directory.appendingPathComponent("repositories.json")
        try original.write(to: repositoryFile)
        let store = RepositoryStore(directory: directory)

        XCTAssertThrowsError(try store.commit { _ in }) { error in
            XCTAssertEqual(error as? RepositoryStore.StoreError, .unreadable)
        }

        let quarantined = try FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("repositories.json.corrupt-") }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(quarantined)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repositoryFile.path),
                       "the original corrupt path must not be replaced by an empty snapshot")
    }

    func testEraseDataIsTheOnlyPathThatRemovesStorageAndTheRecordAndItNeedsAnUninstall() async throws {
        let installer = makeInstaller()
        let (_, qualifiedId) = try await addAndInstallSite1(installer)
        try await HostStorage(sourceID: qualifiedId, repository: storage).set("cursor", value: .int(7))

        await XCTAssertThrowsErrorAsync(try await installer.eraseData(for: qualifiedId)) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .sourceStillInstalled(qualifiedId))
        }
        XCTAssertTrue(eraser.erased.isEmpty)

        try installer.uninstall(qualifiedId)
        try await installer.eraseData(for: qualifiedId)

        XCTAssertEqual(eraser.erased, [qualifiedId])
        let stored = try await HostStorage(sourceID: qualifiedId, repository: storage).get("cursor")
        XCTAssertNil(stored)
        XCTAssertNil(installer.store.source(qualifiedId), "the record and its binding are gone")
    }

    private func makeStoreCommitFailing() throws {
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
    }

    func testInstalledStateSurvivesRelaunchAndIsReconnectedFromTheRawDeclaration() async throws {
        let (repositoryID, qualifiedId): (UUID, QualifiedSourceID)
        do {
            let installer = makeInstaller()
            (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
            try installer.disable(qualifiedId)
        }

        // A second launch: a fresh store read from disk, a fresh registry.
        let registry = SourceLifecycleRegistry()
        let relaunched = makeInstaller(store: RepositoryStore(directory: directory), registry: registry)
        XCTAssertNil(registry.state(for: qualifiedId), "nothing is registered before restore")

        relaunched.restoreInstalledSources()

        XCTAssertEqual(registry.state(for: qualifiedId), .disabled)
        XCTAssertEqual(registry.declaration(for: qualifiedId)?.localId, "site-1")
        XCTAssertEqual(relaunched.store.repository(repositoryID)?.indexURL, urlA)
        XCTAssertEqual(relaunched.store.bundle("engine", in: repositoryID)?.version, 1)
        XCTAssertEqual(relaunched.store.scriptData(for: "engine", in: repositoryID), scriptV1)
        XCTAssertTrue(relaunched.launchRefusals.isEmpty)
    }

    func testAStoredDeclarationTheHostNoLongerAcceptsIsRefusedAtLaunchNotUninstalled() async throws {
        let qualifiedId: QualifiedSourceID
        do {
            let installer = makeInstaller()
            (_, qualifiedId) = try await addAndInstallSite1(installer)
        }

        // The app updated and retired Host API 1.x: the stored bytes are re-validated
        // under the new rules and refused with the validator's own sentence.
        let registry = SourceLifecycleRegistry()
        let retired = HostAPISupport(installedVersions: [HostAPIVersion(major: 3, minor: 0)])
        let relaunched = makeInstaller(store: RepositoryStore(directory: directory),
                                       registry: registry,
                                       hostAPI: retired)

        relaunched.restoreInstalledSources()

        guard case .incompatibleHostAPI = relaunched.launchRefusals[qualifiedId] else {
            return XCTFail("expected incompatibleHostAPI, got \(String(describing: relaunched.launchRefusals[qualifiedId]))")
        }
        XCTAssertNil(registry.state(for: qualifiedId), "a refused Source is not registered")
        XCTAssertEqual(relaunched.store.source(qualifiedId)?.state, .registered,
                       "and it is not uninstalled on the app's behalf")
        XCTAssertNil(relaunched.effectiveAdultClassification(for: qualifiedId), "unknown, never none")
    }

    func testRemovingARepositoryUninstallsAndRetainsAndAReAddReconnects() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        try await HostStorage(sourceID: qualifiedId, repository: storage).set("cursor", value: .int(7))

        try installer.removeRepository(repositoryID)

        XCTAssertEqual(installer.store.repository(repositoryID)?.state, .removed, "the record and UUID persist")
        XCTAssertEqual(registry.state(for: qualifiedId), .uninstalled)
        XCTAssertEqual(installer.store.source(qualifiedId)?.state, .uninstalled, "retained")
        XCTAssertNil(installer.store.bundle("engine", in: repositoryID))
        XCTAssertNil(installer.store.scriptData(for: "engine", in: repositoryID), "scripts are not the reader's data")
        XCTAssertTrue(eraser.erased.isEmpty)
        await XCTAssertThrowsErrorAsync(try await installer.refresh(repositoryID)) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .repositoryRemoved(repositoryID))
        }

        let reAdded = try await installer.addRepository(at: urlA)
        XCTAssertEqual(reAdded.id, repositoryID)
        let reinstalled = try await installer.install(localId: "site-1", from: repositoryID)
        XCTAssertEqual(reinstalled.qualifiedId, qualifiedId)
        XCTAssertTrue(registry.isActive(qualifiedId))
        let stored = try await HostStorage(sourceID: qualifiedId, repository: storage).get("cursor")
        XCTAssertEqual(stored, .int(7))

        // Erasing a removed repository ends the identity for good.
        try installer.removeRepository(repositoryID)
        try await installer.eraseData(forRepository: repositoryID)
        XCTAssertEqual(eraser.erased, [qualifiedId])
        XCTAssertNil(installer.store.repository(repositoryID))
        XCTAssertNil(installer.store.source(qualifiedId))
    }

    // MARK: - Adult Sources (§7)

    func testAMixedSourceNeedsAnAcknowledgementAndDecliningPersistsNothing() async throws {
        let registry = SourceLifecycleRegistry()
        let installer = makeInstaller(registry: registry)
        serve(index(name: "Repo", bundles: [bundle(sources: [declaration(localId: "site-1", name: "Mixed",
                                                                          adult: "mixed")])]), at: urlA)
        let repository = try await installer.addRepository(at: urlA)
        let qualifiedId = ExtensionInstaller.qualifiedID(repositoryID: repository.id, localId: "site-1")

        acknowledgementAnswer = false
        await XCTAssertThrowsErrorAsync(try await installer.install(localId: "site-1", from: repository.id)) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .adultAcknowledgementDeclined(localId: "site-1"))
        }
        XCTAssertEqual(acknowledgements, [AdultInstallAcknowledgement(sourceName: "Mixed",
                                                                      repositoryName: "Repo",
                                                                      classification: .mixed)])
        XCTAssertNil(installer.store.source(qualifiedId))
        XCTAssertNil(installer.store.bundle("engine", in: repository.id))
        XCTAssertNil(installer.store.scriptData(for: "engine", in: repository.id))
        XCTAssertNil(registry.state(for: qualifiedId))

        acknowledgementAnswer = true
        _ = try await installer.install(localId: "site-1", from: repository.id)
        XCTAssertTrue(registry.isActive(qualifiedId))
        XCTAssertEqual(installer.effectiveAdultClassification(for: qualifiedId), .mixed)
    }

    func testTreatAsAdultElevatesANoneSourceAndAnUpdateNeverLowersIt() async throws {
        let installer = makeInstaller()
        let (repositoryID, qualifiedId) = try await addAndInstallSite1(installer)
        XCTAssertEqual(installer.effectiveAdultClassification(for: qualifiedId), AdultClassification.none)
        XCTAssertTrue(acknowledgements.isEmpty, "a `none` Source asks nothing")

        try installer.treatAsAdult(qualifiedId)
        XCTAssertEqual(installer.effectiveAdultClassification(for: qualifiedId), .mixed)

        serveUpdatedBundle(at: urlA, declaration: declaration(localId: "site-1", adult: "none"))
        _ = try await installer.refresh(repositoryID)
        try await installer.updateBundle("engine", in: repositoryID)
        XCTAssertEqual(installer.effectiveAdultClassification(for: qualifiedId), .mixed)

        try installer.clearAdultElevation(qualifiedId)
        XCTAssertEqual(installer.effectiveAdultClassification(for: qualifiedId), AdultClassification.none)
    }

    // MARK: - Add and install edges

    func testAddingTheSameURLTwiceIsRefused() async throws {
        let installer = makeInstaller()
        serve(index(bundles: []), at: urlA)
        let first = try await installer.addRepository(at: urlA)
        await XCTAssertThrowsErrorAsync(try await installer.addRepository(at: urlA)) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .repositoryAlreadyAdded(first.id, self.urlA))
        }
        XCTAssertEqual(installer.store.repositories.count, 1)
    }

    func testADeclarationTheValidatorRefusesIsListedAsNotInstallableWithoutHidingItsNeighbours() async throws {
        let installer = makeInstaller()
        let tooNew = declaration(localId: "future", hostAPI: ("9.0", "10.0"))
        serve(index(bundles: [bundle(sources: [tooNew, declaration(localId: "site-1")])]), at: urlA)

        let repository = try await installer.addRepository(at: urlA)

        let listing = try XCTUnwrap(installer.listings[repository.id])
        guard case .failure(.incompatibleHostAPI) = listing.entry(localId: "future")?.outcome else {
            return XCTFail("expected incompatibleHostAPI for 'future'")
        }
        XCTAssertNotNil(listing.entry(localId: "site-1")?.declaration)
        await XCTAssertThrowsErrorAsync(try await installer.install(localId: "future", from: repository.id)) { error in
            guard case .declarationRejected("future", .incompatibleHostAPI)? = error as? ExtensionInstallError else {
                return XCTFail("unexpected \(error)")
            }
        }
        _ = try await installer.install(localId: "site-1", from: repository.id)
    }

    func testTwoSourcesFromOneBundleShareOneScriptFile() async throws {
        let installer = makeInstaller()
        serve(index(bundles: [bundle(sources: [declaration(localId: "a"), declaration(localId: "b")])]), at: urlA)
        let repository = try await installer.addRepository(at: urlA)
        _ = try await installer.install(localId: "a", from: repository.id)
        _ = try await installer.install(localId: "b", from: repository.id)

        XCTAssertEqual(installer.store.sources(in: repository.id).map(\.bundleId), ["engine", "engine"])
        let folder = installer.store.scriptFileURL(for: "engine", in: repository.id).deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["engine.js"])
    }
}

// MARK: - Async assertion

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath,
                                  line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

@MainActor
final class BundledRepositoryTransportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = PortFixtures.packageDirectory
        try FileManager.default.copyItem(at: package.appendingPathComponent("index.json"),
                                         to: directory.appendingPathComponent("index.json"))
        try FileManager.default.copyItem(at: package.appendingPathComponent("engine.js"),
                                         to: directory.appendingPathComponent("engine.js"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBundledIndexValidatesAndScriptDigestMatches() async throws {
        let transport = BundledRepositoryTransport(resourceDirectory: directory)
        guard case .index(let index) = try await transport.fetchIndex(at: BundledRepositories.weebCentralURL) else {
            return XCTFail("bundled index must be local")
        }
        let script = try await transport.fetchScript(at: BundledRepositories.weebCentralURL)
        XCTAssertEqual(index.bundles.first?.scriptSHA256,
                       SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined())
    }

    func testBundledAdultDeclarationIsRejected() async throws {
        let url = directory.appendingPathComponent("index.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var bundles = try XCTUnwrap(object["bundles"] as? [[String: Any]])
        var sources = try XCTUnwrap(bundles[0]["sources"] as? [[String: Any]])
        sources[0]["adult"] = "adultOnly"
        bundles[0]["sources"] = sources
        object["bundles"] = bundles
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let transport = BundledRepositoryTransport(resourceDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await transport.fetchIndex(at: BundledRepositories.weebCentralURL)) { error in
            XCTAssertEqual(error as? BundledRepositoryTransport.Error,
                           .adultSource("weebcentral"))
        }
    }
}
