//
//  ExtensionSourceTests.swift
//  MangaCartaTests
//
//  Phase 4 acceptance criteria 8 and 9: an installed Source is a `MangaSource`.
//
//  Two suites. `ExtensionSourceTests` proves the adapter itself — every `MangaSource`
//  method reaches `ExtensionRuntime` and comes back as the app's domain types, with the
//  qualified id stamped by the host and not by the engine — against the same captured
//  WeebCentral HTML the S6 port ran on, so "serves search, detail, chapters and pages"
//  is checked field for field against the compiled Source. `InstalledSourceRegistrationTests`
//  proves the wiring: a Source the installer registers appears in `SourceRegistry`, and
//  its disappearance reaches the picker, fulfillment ranking (ADR-0004) and adult gating
//  without losing the reader's Listings, pins or history.
//
//  Every declaration goes through `SourceDeclarationValidator` from JSON (#161).
//

import CryptoKit
import XCTest
@testable import MangaCarta

// MARK: - Fakes

/// A host whose only capability is `host.browser` over captured HTML. What the
/// production factory does, minus the network.
final class FixtureSourceHost: ExtensionSourceHosting {
    let browser: FixtureBrowser
    private(set) var invocations: [(SourceOperation, UUID)] = []

    init(site: FixtureSite) {
        browser = FixtureBrowser(site: site)
    }

    func capabilities(for declaration: SourceDeclaration,
                      operation: SourceOperation,
                      invocationID: UUID) -> [ExtensionHostCapability] {
        invocations.append((operation, invocationID))
        return [HostBrowserJSCapability(extractor: browser)]
    }
}

/// A built-in stand-in for MangaDex: registered under MangaDex's id so the ranking's
/// default preference applies, serving a fixed chapter list so it can be counted.
private struct BuiltInStubSource: MangaSource {
    let id: String
    var name: String { id }
    let chapterNumbers: [String]

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] { [] }
    func popular(limit: Int, offset: Int) async throws -> [Manga] { [] }
    func mangaDetail(id: String) async throws -> MangaDetail {
        MangaDetail(description: "", authors: [], tags: [], contentRating: nil)
    }
    func chapters(mangaId: String) async throws -> [Chapter] {
        chapterNumbers.map { Chapter(id: "\(mangaId)-\($0)", number: $0, title: nil) }
    }
    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] { [] }
}

// MARK: - The adapter

@MainActor
final class ExtensionSourceTests: XCTestCase {

    private static let qualifiedID = "6f1d9c2e-4b7a-4c1e-9e3d-2a8b5c7d1f00:weebcentral"

    private var lifecycle: SourceLifecycleRegistry!
    private var host: FixtureSourceHost!

    override func setUp() {
        super.setUp()
        lifecycle = SourceLifecycleRegistry()
        host = FixtureSourceHost(site: PortFixtures.weebCentralSite)
    }

    /// The WeebCentral declaration under a repository-qualified id, registered, backed by
    /// the shipped theme engine — exactly what the registrar builds after an install.
    private func weebCentral() throws -> ExtensionSource {
        let declaration = try PortFixtures.declaration(PortFixtures.weebCentralJSON,
                                                       qualifiedId: Self.qualifiedID)
        try lifecycle.register(declaration)
        return ExtensionSource(declaration: declaration,
                               script: PortFixtures.bundleScript,
                               isNSFW: false,
                               lifecycle: lifecycle,
                               host: host)
    }

    // MARK: Criterion 8, clause "with sourceId stamped"

    /// Host API design, "Envelope and value rules": the host stamps the Listing, and an
    /// engine that writes its own `sourceId` changes nothing.
    func testTheHostStampsTheQualifiedIdAndTheEngineCannotOverrideIt() async throws {
        let source = try echoSource()

        let results = try await source.search(title: "x", limit: 3, offset: 0)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceId, Self.echoID)
        XCTAssertEqual(results.first?.id, "cursor=null;limit=3;query=x",
                       "the runtime received the request the adapter built")
    }

    // MARK: Offset paging over a cursor contract

    /// `MangaSource` pages by offset; the Host API pages by opaque cursor. The adapter
    /// remembers the cursor each page handed back, keyed by the offset it leads to, so
    /// the sequential scroll `PagedMangaLoader` performs lands on consecutive pages.
    func testSequentialOffsetsFollowTheCursorsThePreviousPagesReturned() async throws {
        let source = try echoSource()

        let first = try await source.popular(limit: 5, offset: 0)
        let second = try await source.popular(limit: 5, offset: 5)
        let third = try await source.popular(limit: 5, offset: 10)

        XCTAssertEqual(first.map(\.id), ["cursor=null;limit=5"])
        XCTAssertEqual(second.map(\.id), ["cursor=5;limit=5"])
        XCTAssertEqual(third.map(\.id), ["cursor=10;limit=5"])
    }

    /// An offset the adapter has no cursor for is reached by walking from the last one it
    /// does have, never by guessing a cursor's shape.
    func testAnUnseenOffsetIsReachedByWalkingForwardFromTheLastKnownCursor() async throws {
        let source = try echoSource()

        let page = try await source.popular(limit: 5, offset: 15)

        XCTAssertEqual(page.map(\.id), ["cursor=15;limit=5"])
    }

    /// The page that says `exhausted: true` is the last page, items and all; every
    /// offset past it is empty without the engine being asked.
    func testAnExhaustedFeedReturnsNoMoreItems() async throws {
        let source = try echoSource(exhaustAt: 5)

        let first = try await source.popular(limit: 5, offset: 0)
        let last = try await source.popular(limit: 5, offset: 5)
        let next = try await source.popular(limit: 5, offset: 10)
        let far = try await source.popular(limit: 5, offset: 25)

        XCTAssertEqual(first.map(\.id), ["cursor=null;limit=5"])
        XCTAssertEqual(last.map(\.id), ["cursor=5;limit=5"], "the exhausted page still carries its items")
        XCTAssertEqual(next, [], "the page after it is empty")
        XCTAssertEqual(far, [], "and so is every page beyond it")
        XCTAssertEqual(host.invocations.count, 2, "nothing past the exhausted page was ever fetched")
    }

    // MARK: Declared capabilities and errors

    func testAnUndeclaredFeedIsUnsupportedRatherThanInvoked() async throws {
        let source = try echoSource()   // declares no `newTitles`

        do {
            _ = try await source.newTitles(limit: 5, offset: 0)
            XCTFail("expected SourceError.unsupported")
        } catch let error as SourceError {
            guard case .unsupported("newTitles") = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(host.invocations.isEmpty, "an undeclared operation never reaches the runtime")
    }

    /// The design's "Errors and partial success": the engine's `message` is diagnostic
    /// and never shown verbatim; the reader sees the host's sentence for the code.
    func testAnEngineFailureSurfacesAsHostCopyNotTheEnginesMessage() async throws {
        let source = try echoSource(failWith: "network", message: "socket 0xdeadbeef reset")

        do {
            _ = try await source.search(title: "x", limit: 3, offset: 0)
            XCTFail("expected ExtensionSourceError")
        } catch let error as ExtensionSourceError {
            XCTAssertEqual(error, .invocation(.network))
            let copy = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(copy.contains("0xdeadbeef"))
            XCTAssertFalse(copy.isEmpty)
        }
    }

    // MARK: Criterion 9, clause "degrades to unavailable"

    /// A Source instance a detail page is still holding — adopted before the reader
    /// uninstalled — fails as unavailable (design §11) rather than running an engine the
    /// registry no longer routes to. The browser sees no request.
    func testAnUninstalledSourceFailsAsUnavailableWithoutInvokingTheEngine() async throws {
        let source = try weebCentral()
        _ = try await source.chapters(mangaId: PortFixtures.weebSeriesID)
        let requestsBefore = host.browser.requestedURLs.count

        try lifecycle.uninstall(source.declaration.qualifiedId)

        do {
            _ = try await source.chapters(mangaId: PortFixtures.weebSeriesID)
            XCTFail("expected ExtensionSourceError.unavailable")
        } catch let error as ExtensionSourceError {
            XCTAssertEqual(error, .unavailable(name: "WeebCentral"))
        }
        XCTAssertEqual(host.browser.requestedURLs.count, requestsBefore)
        XCTAssertEqual(host.invocations.count, 1)
    }

    func testADisabledSourceFailsAsUnavailableToo() async throws {
        let source = try weebCentral()
        try lifecycle.disable(source.declaration.qualifiedId)

        do {
            _ = try await source.search(title: "berserk", limit: 8, offset: 0)
            XCTFail("expected ExtensionSourceError.unavailable")
        } catch let error as ExtensionSourceError {
            XCTAssertEqual(error, .unavailable(name: "WeebCentral"))
        }
    }

    func testReinstallingReconnectsTheSameInstance() async throws {
        let source = try weebCentral()
        try lifecycle.uninstall(source.declaration.qualifiedId)
        try lifecycle.reinstall(source.declaration)

        let chapters = try await source.chapters(mangaId: PortFixtures.weebSeriesID)

        XCTAssertFalse(chapters.isEmpty)
    }

    // MARK: Presentation

    func testRailPresentationComesFromTheDeclaration() throws {
        let source = try weebCentral()

        // No feed titles are declared, so the host's own apply; the eyebrows are the
        // declaration's; no badge is declared, which the design reads as `none`; and no
        // prefetch hint means the host default.
        XCTAssertEqual(source.homeRailTitles, ["Popular", "Recently Updated", "Newly Added"])
        XCTAssertEqual(source.homeRailEyebrows, ["By popularity", "New chapters", "Just added"])
        XCTAssertFalse(source.latestRailShowsNewBadge)
        XCTAssertEqual(source.imagePrefetchConcurrency, 5)
        XCTAssertEqual(source.id, Self.qualifiedID)
        XCTAssertEqual(source.name, "WeebCentral")
    }

    func testInstalledSourceReturnsItsDeclaredWebURL() async throws {
        let source = try weebCentral()
        let url = try await source.webURL(forManga: PortFixtures.weebSeriesID)
        XCTAssertEqual(url?.absoluteString,
                       "https://weebcentral.com/series/\(PortFixtures.weebSeriesID)")
        XCTAssertEqual(host.invocations.map(\.0), [.webURL])
    }

    // MARK: An engine that echoes its request

    private static let echoID = "6f1d9c2e-4b7a-4c1e-9e3d-2a8b5c7d1f00:echo"

    /// Listings whose id is the request the engine received, so every test above can read
    /// what the adapter sent without a DOM. Cursors are decimal offsets, the shape the
    /// shipped theme engine uses too, but the adapter never assumes that.
    private func echoSource(exhaustAt: Int? = nil,
                            failWith code: String? = nil,
                            message: String = "") throws -> ExtensionSource {
        let script = """
        registerEngine("echo", {
          invoke: function (operation, request, context) {
            \(code.map { "return { ok: false, error: { code: \"\($0)\", message: \"\(message)\" } };" } ?? "")
            var cursor = request.cursor === null || request.cursor === undefined ? "null" : request.cursor;
            var id = "cursor=" + cursor + ";limit=" + request.limit;
            if (request.query !== undefined) { id += ";query=" + request.query; }
            var offset = cursor === "null" ? 0 : parseInt(cursor, 10);
            var exhausted = \(exhaustAt.map(String.init) ?? "null");
            var done = exhausted !== null && offset >= exhausted;
            return { ok: true, value: {
              items: [{ id: id, title: "Echo", sourceId: "evil" }],
              nextCursor: done ? null : String(offset + request.limit),
              exhausted: done
            } };
          }
        });
        """
        let declaration = try PortFixtures.declaration("""
        {
          "localId": "echo",
          "name": "Echo",
          "engine": "echo",
          "adult": "none",
          "capabilities": { "search": true, "popular": true, "detail": true,
                            "chapters": true, "pages": true },
          "languages": { "mode": "fixed", "values": ["en"] },
          "network": { "httpOrigins": [], "browserOrigins": [], "assetOrigins": [] },
          "hostAPI": { "minimum": "1.0", "maximumExclusive": "2.0" },
          "configuration": {}
        }
        """, qualifiedId: Self.echoID)
        try lifecycle.register(declaration)
        return ExtensionSource(declaration: declaration,
                               script: script,
                               isNSFW: false,
                               lifecycle: lifecycle,
                               host: host)
    }
}

// MARK: - Registration

@MainActor
final class InstalledSourceRegistrationTests: XCTestCase {

    private var directory: URL!
    private var transport: FakeRepositoryTransport!
    private var storage: HostStorageRepository!
    private var store: RepositoryStore!
    private var lifecycle: SourceLifecycleRegistry!
    private var installer: ExtensionInstaller!
    private var registry: SourceRegistry!
    private var host: FixtureSourceHost!
    private var registrar: ExtensionSourceRegistrar!
    private var savedActiveSourceID: Any?

    private let indexURL = URL(string: "https://repo.example.test/index.json")!
    private let scriptURL = URL(string: "https://repo.example.test/engine.js")!
    private var script: Data { Data(PortFixtures.bundleScript.utf8) }

    override func setUp() async throws {
        savedActiveSourceID = UserDefaults.standard.object(forKey: "source.activeID")
        UserDefaults.standard.removeObject(forKey: "source.activeID")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledSourceRegistrationTests-\(UUID().uuidString)",
                                    isDirectory: true)
        transport = FakeRepositoryTransport()
        transport.scripts[scriptURL] = script
        storage = try HostStorageRepository(directory: directory)
        store = RepositoryStore(directory: directory)
        lifecycle = SourceLifecycleRegistry()
        installer = ExtensionInstaller(store: store,
                                       registry: lifecycle,
                                       transport: transport,
                                       dataEraser: RecordingDataEraser(storage: storage),
                                       acknowledgeAdult: { _ in true })
        registry = SourceRegistry(sources: [BuiltInStubSource(id: MangaDexSource.sourceID,
                                                              chapterNumbers: ["1", "2"])])
        host = FixtureSourceHost(site: PortFixtures.weebCentralSite)
        registrar = ExtensionSourceRegistrar(store: store, lifecycle: lifecycle,
                                             host: host, registry: registry)
    }

    override func tearDown() async throws {
        if let savedActiveSourceID {
            UserDefaults.standard.set(savedActiveSourceID, forKey: "source.activeID")
        } else {
            UserDefaults.standard.removeObject(forKey: "source.activeID")
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    private func serveWeebCentral(adult: String = "none") throws {
        // Mutate the parsed document, not its text: the fixture JSON is re-serialized from
        // the bundled index and its whitespace is not something a test should depend on.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(PortFixtures.weebCentralJSON.utf8)) as? [String: Any])
        object["adult"] = adult
        let raw = try JSONValue(parsing: JSONSerialization.data(withJSONObject: object))
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        let bundle = RepositoryBundle(id: "html-selector", version: 1,
                                      scriptURL: scriptURL, scriptSHA256: digest,
                                      sources: [RepositorySourceRecord(rawJSON: raw,
                                                                       localID: "weebcentral")])
        transport.indexes[indexURL] = .index(RepositoryIndex(format: 1, name: "Test Repository",
                                                             bundles: [bundle]))
    }

    @discardableResult
    private func installWeebCentral(adult: String = "none") async throws -> QualifiedSourceID {
        try serveWeebCentral(adult: adult)
        let repository = try await installer.addRepository(at: indexURL)
        return try await installer.install(localId: "weebcentral", from: repository.id).qualifiedId
    }

    // MARK: Criterion 8, clause "an installed Source appears in SourceRegistry"

    func testAnInstalledSourceAppearsInTheRegistryAndAnUninstalledOneLeaves() async throws {
        try serveWeebCentral()
        let repository = try await installer.addRepository(at: indexURL)
        let expectedID = ExtensionInstaller.qualifiedID(repositoryID: repository.id,
                                                        localId: "weebcentral")
        XCTAssertNil(registry.source(id: expectedID.rawValue), "adding a repository registers nothing")

        let installed = try await installer.install(localId: "weebcentral", from: repository.id)

        let source = try XCTUnwrap(registry.source(id: installed.qualifiedId.rawValue))
        XCTAssertEqual(source.name, "WeebCentral")
        XCTAssertEqual(registry.sources.map(\.id), [MangaDexSource.sourceID, installed.qualifiedId.rawValue],
                       "built-ins first, then installed Sources; nothing substituted")

        try installer.uninstall(installed.qualifiedId)
        XCTAssertNil(registry.source(id: installed.qualifiedId.rawValue))
        XCTAssertEqual(registry.sources.map(\.id), [MangaDexSource.sourceID])
    }

    func testDisablingRemovesTheSourceAndEnablingRestoresIt() async throws {
        let id = try await installWeebCentral()

        try installer.disable(id)
        XCTAssertNil(registry.source(id: id.rawValue))

        try installer.enable(id)
        XCTAssertNotNil(registry.source(id: id.rawValue))
    }

    // MARK: Criterion 8, clause "is selectable as the browse source"

    func testAnInstalledSourceIsSelectableAsTheBrowseSource() async throws {
        let id = try await installWeebCentral()

        XCTAssertTrue(registry.visibleSources(includeAdult: false).contains { $0.id == id.rawValue },
                      "the picker offers it")
        registry.activeSourceID = id.rawValue
        XCTAssertEqual(registry.active.id, id.rawValue)

        // Uninstalling the browse source moves browsing off it rather than leaving the
        // picker pointed at a Source that is no longer there.
        try installer.uninstall(id)
        XCTAssertEqual(registry.activeSourceID, MangaDexSource.sourceID)
        XCTAssertEqual(registry.active.id, MangaDexSource.sourceID)
    }

    // MARK: Criterion 8, clause "serves … through ExtensionRuntime" — through the registry

    func testTheRegisteredSourceServesSearchAndStampsItsQualifiedId() async throws {
        let id = try await installWeebCentral()
        let source = try XCTUnwrap(registry.source(id: id.rawValue))

        let results = try await source.search(title: "berserk", limit: 8, offset: 0)

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.sourceId == id.rawValue })
        XCTAssertEqual(host.invocations.map(\.0), [.search])
    }

    // MARK: Criterion 8, clause "so that source(for:) routes back to it"

    func testAMangaFromTheInstalledSourceRoutesBackToIt() async throws {
        let id = try await installWeebCentral()
        let source = try XCTUnwrap(registry.source(id: id.rawValue))
        let results = try await source.search(title: "berserk", limit: 8, offset: 0)
        let manga = try XCTUnwrap(results.first)

        XCTAssertEqual(registry.source(for: manga)?.id, id.rawValue)
        XCTAssertEqual(registry.sourceForRefresh(sourceId: manga.sourceId).id, id.rawValue)
    }

    // MARK: Adult gating reaches installed Sources

    func testAMixedSourceIsGatedBehindTheAdultToggle() async throws {
        XCTAssertFalse(registry.hasAdultSource)
        let id = try await installWeebCentral(adult: "mixed")
        registrar.sync(store.snapshot)
        await Task.yield()

        XCTAssertTrue(registry.hasAdultSource, "the toggle has something to gate")
        XCTAssertFalse(registry.visibleSources(includeAdult: false).contains { $0.id == id.rawValue })
        XCTAssertTrue(registry.visibleSources(includeAdult: true).contains { $0.id == id.rawValue })

        registry.activeSourceID = id.rawValue
        registry.enforceAdultGating(includeAdult: false)
        XCTAssertEqual(registry.activeSourceID, MangaDexSource.sourceID)
    }

    /// "Treat as adult" (design §6.9) changes the record, not the lifecycle registry;
    /// the gate has to follow the record.
    func testTreatAsAdultElevatesANoneSourceIntoTheGate() async throws {
        let id = try await installWeebCentral()
        XCTAssertFalse(registry.hasAdultSource)

        try installer.treatAsAdult(id)
        XCTAssertTrue(registry.hasAdultSource)
        XCTAssertFalse(registry.visibleSources(includeAdult: false).contains { $0.id == id.rawValue })

        try installer.clearAdultElevation(id)
        XCTAssertFalse(registry.hasAdultSource)
    }

    // MARK: Launch

    /// The installed set is restored from the store at launch, re-validated from the raw
    /// declaration, and served — and a stored declaration the host refuses is not.
    func testInstalledSourcesAreRestoredAtLaunchFromTheStore() async throws {
        let id = try await installWeebCentral()

        let relaunchedStore = RepositoryStore(directory: directory)
        let relaunchedLifecycle = SourceLifecycleRegistry()
        let relaunchedInstaller = ExtensionInstaller(store: relaunchedStore,
                                                     registry: relaunchedLifecycle,
                                                     transport: transport,
                                                     dataEraser: RecordingDataEraser(storage: storage),
                                                     acknowledgeAdult: { _ in true })
        let relaunchedRegistry = SourceRegistry(sources: [BuiltInStubSource(id: MangaDexSource.sourceID,
                                                                            chapterNumbers: [])])
        relaunchedInstaller.restoreInstalledSources()
        _ = ExtensionSourceRegistrar(store: relaunchedStore, lifecycle: relaunchedLifecycle,
                                     host: host, registry: relaunchedRegistry)

        let restored = try XCTUnwrap(relaunchedRegistry.source(id: id.rawValue))
        let chapters = try await restored.chapters(mangaId: PortFixtures.weebSeriesID)
        XCTAssertFalse(chapters.isEmpty, "served from the script the store kept")
    }

    func testASourceRefusedAtLaunchIsNotServed() async throws {
        let id = try await installWeebCentral()

        let relaunchedStore = RepositoryStore(directory: directory)
        let relaunchedLifecycle = SourceLifecycleRegistry()
        // A host that retired Host API 1.x refuses the stored declaration.
        let relaunchedInstaller = ExtensionInstaller(
            store: relaunchedStore, registry: relaunchedLifecycle, transport: transport,
            dataEraser: RecordingDataEraser(storage: storage),
            hostAPI: HostAPISupport(installedVersions: [HostAPIVersion(major: 2, minor: 0)]),
            acknowledgeAdult: { _ in true })
        let relaunchedRegistry = SourceRegistry(sources: [BuiltInStubSource(id: MangaDexSource.sourceID,
                                                                            chapterNumbers: [])])
        relaunchedInstaller.restoreInstalledSources()
        _ = ExtensionSourceRegistrar(store: relaunchedStore, lifecycle: relaunchedLifecycle,
                                     host: host, registry: relaunchedRegistry)

        XCTAssertNotNil(relaunchedInstaller.launchRefusals[id])
        XCTAssertNil(relaunchedRegistry.source(id: id.rawValue))
    }

    /// The production graph does the same wiring: `AppComposition` restores installed
    /// Sources into the registry it owns — the one views take from the environment.
    func testAppCompositionRestoresInstalledSourcesIntoItsRegistry() async throws {
        let id = try await installWeebCentral()
        let suite = "InstalledSourceRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let composition = AppComposition(defaults: defaults, directory: directory,
                                         registry: SourceRegistry(sources: [BuiltInStubSource(
                                            id: MangaDexSource.sourceID, chapterNumbers: [])]))

        XCTAssertNotNil(composition.registry.source(id: id.rawValue))
        let extensions = try XCTUnwrap(composition.extensions)
        XCTAssertTrue(extensions.installer.launchRefusals.isEmpty)

        try extensions.installer.uninstall(id)
        XCTAssertNil(composition.registry.source(id: id.rawValue))
    }

    // MARK: Criterion 9

    /// A Work with two Listings — the installed Source's and MangaDex's — ranked by
    /// chapter count so the installed one wins (ADR-0004). Returns the Work and the two
    /// keys.
    private func workWithTwoListings(installed id: QualifiedSourceID,
                                     counts: ListingCountCache,
                                     works: WorkStore) -> (WorkID, ListingKey, ListingKey) {
        let extensionManga = Manga(id: PortFixtures.weebSeriesID, sourceId: id.rawValue,
                                   title: "Berserk", description: "", status: "ongoing",
                                   year: nil, coverURL: nil, malId: 2)
        let mangadexManga = Manga(id: "md-berserk", sourceId: MangaDexSource.sourceID,
                                  title: "Berserk", description: "", status: "ongoing",
                                  year: nil, coverURL: nil, malId: 2)
        let workID = works.mint(from: extensionManga)
        let merged = works.mint(from: mangadexManga)
        XCTAssertEqual(merged, workID, "both Listings share a MAL id, so one Work")
        let extensionKey = ListingKey(extensionManga)
        let mangadexKey = ListingKey(mangadexManga)
        counts.record(40, for: extensionKey)
        counts.record(2, for: mangadexKey)
        return (workID, extensionKey, mangadexKey)
    }

    /// Criterion 9, clauses "without data loss" and "fulfillment ranking chooses another
    /// registered Source where one exists".
    func testUninstallingTheChosenSourceMovesFulfillmentToTheOtherListingAndLosesNothing() async throws {
        let id = try await installWeebCentral()
        let works = WorkStore(directory: directory)
        let counts = ListingCountCache(directory: directory)
        let suite = "InstalledSourceRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SourcePreferenceStore(defaults: defaults)
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry,
                                                 counts: counts, preferences: preferences)
        let (workID, extensionKey, mangadexKey) = workWithTwoListings(installed: id,
                                                                      counts: counts, works: works)
        let history = HistoryStore(defaults: defaults, works: works, chapterCompleted: { _ in })
        history.record(manga: Manga(id: extensionKey.mangaId, sourceId: id.rawValue, title: "Berserk",
                                    description: "", status: "ongoing", year: nil, coverURL: nil,
                                    malId: 2),
                       chapter: Chapter(id: "c1", number: "1", title: nil),
                       position: ReadingPosition(page: 3), pageCount: 10)
        preferences.choose(extensionKey, for: workID)

        XCTAssertEqual(fulfillment.chosenListing(for: workID), extensionKey,
                       "the pinned, better-counted Listing is the one that opens")
        XCTAssertEqual(fulfillment.candidates(for: workID).map(\.key), [extensionKey, mangadexKey])

        try installer.uninstall(id)

        // The ranking chooses the other registered Source.
        XCTAssertEqual(fulfillment.candidates(for: workID).map(\.key), [mangadexKey])
        XCTAssertEqual(fulfillment.chosenListing(for: workID), mangadexKey)

        // Nothing of the reader's is lost: the Listing, the pin, the history entry.
        XCTAssertEqual(Set(works.work(workID)?.listings ?? []), [extensionKey, mangadexKey])
        XCTAssertEqual(preferences.choice(for: workID), extensionKey, "the pin waits for a reinstall")
        XCTAssertEqual(history.entries.first?.chapterId, "c1")
        XCTAssertEqual(store.source(id)?.state, .uninstalled, "the record is retained")

        // Reinstalling reconnects: the pin applies again and the Source is chosen again.
        let repository = try XCTUnwrap(store.repositories.first)
        _ = try await installer.install(localId: "weebcentral", from: repository.id)
        XCTAssertEqual(fulfillment.chosenListing(for: workID), extensionKey)
    }

    /// Criterion 9, clause "where one exists": with no other Listing, nothing is chosen
    /// and nothing is invented.
    func testWithNoOtherListingFulfillmentChoosesNothingRatherThanAnUnregisteredSource() async throws {
        let id = try await installWeebCentral()
        let works = WorkStore(directory: directory)
        let counts = ListingCountCache(directory: directory)
        let suite = "InstalledSourceRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fulfillment = FulfillmentCoordinator(works: works, registry: registry, counts: counts,
                                                 preferences: SourcePreferenceStore(defaults: defaults))
        let manga = Manga(id: PortFixtures.weebSeriesID, sourceId: id.rawValue, title: "Berserk",
                          description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
        let workID = works.mint(from: manga)
        XCTAssertEqual(fulfillment.chosenListing(for: workID), ListingKey(manga))

        try installer.uninstall(id)

        XCTAssertNil(fulfillment.chosenListing(for: workID))
        XCTAssertEqual(fulfillment.candidates(for: workID), [])
        XCTAssertEqual(works.work(workID)?.listings, [ListingKey(manga)], "the Listing is kept")
    }

    /// Criterion 9, clause "degrades to unavailable": the instance a detail page adopted
    /// before the uninstall fails as unavailable, not with a foreign source's error.
    func testTheAdoptedInstanceDegradesToUnavailableAfterUninstall() async throws {
        let id = try await installWeebCentral()
        let manga = Manga(id: PortFixtures.weebSeriesID, sourceId: id.rawValue, title: "Berserk",
                          description: "", status: "ongoing", year: nil, coverURL: nil, malId: nil)
        let vm = MangaDetailViewModel(manga: manga)
        vm.adopt(registry: registry)
        await vm.loadAsync()
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.chapters.isEmpty)

        try installer.uninstall(id)
        await vm.loadAsync()

        XCTAssertEqual(vm.errorMessage, ExtensionSourceError.unavailable(name: "WeebCentral").errorDescription)
    }

    func testInstalledPackageRunsWeebCentralAgainstPinnedPortFixtures() async throws {
        var measurements: [String: Double] = [:]
        func measured<T>(_ operation: String, _ body: () async throws -> T) async rethrows -> T {
            let start = Date()
            let result = try await body()
            measurements[operation] = Date().timeIntervalSince(start) * 1_000
            return result
        }
        let fixtureDirectory = PortFixtures.packageDirectory
        let indexURL = URL(string: "https://fixture.test/index.json")!
        let indexBytes = try Data(contentsOf: fixtureDirectory.appendingPathComponent("index.json"))
        let scriptBytes = try Data(contentsOf: fixtureDirectory.appendingPathComponent("engine.js"))
        let parsed: RepositoryIndex
        switch RepositoryIndexValidator.validate(json: indexBytes, indexURL: indexURL) {
        case .success(let value): parsed = value
        case .failure(let error): throw error
        }
        let scriptURL = parsed.bundles[0].scriptURL
        transport.indexes[indexURL] = .index(parsed)
        transport.scripts[scriptURL] = scriptBytes

        let repository = try await measured("add") { try await installer.addRepository(at: indexURL) }
        _ = try await measured("refresh") { try await installer.refresh(repository.id) }
        let installed = try await measured("install") {
            try await installer.install(localId: "weebcentral", from: repository.id)
        }
        let source = try XCTUnwrap(registry.source(id: installed.qualifiedId.rawValue) as? ExtensionSource)
        XCTAssertEqual(source.script, String(decoding: scriptBytes, as: UTF8.self),
                       "the installed package bytes must supply the engine")
        XCTAssertEqual(source.script, PortFixtures.bundleScript,
                       "the installed package engine is the pinned repository script")
        XCTAssertEqual(source.declaration.name, "WeebCentral",
                       "the installed package declaration must supply its Source")

        let expectedPort = try PortFixtures.weebCentral()
        let expectedSearchPage = try await expectedPort.listings(.search,
                                                                  request: ["query": "berserk", "limit": 8])
        let actualSearch = try await measured("search") {
            try await source.search(title: "berserk", limit: 8, offset: 0)
        }
        XCTAssertEqual(actualSearch.map(\.title), expectedSearchPage.items.map(\.title))

        let expectedDetailValue = try expectedPort.validator.validateDetail(
            try await expectedPort.runtime.invoke(.detail, request: ["listingId": PortFixtures.weebSeriesID])).value.toMangaDetail()
        let actualDetail = try await measured("detail") {
            try await source.mangaDetail(id: PortFixtures.weebSeriesID)
        }
        XCTAssertEqual(actualDetail.description, expectedDetailValue.description)
        XCTAssertEqual(actualDetail.authors, expectedDetailValue.authors)
        XCTAssertEqual(actualDetail.tags.map(\.name), expectedDetailValue.tags.map(\.name))
        XCTAssertEqual(actualDetail.contentRating, expectedDetailValue.contentRating)

        let expectedChapters = try expectedPort.validator.validateChapters(
            try await expectedPort.runtime.invoke(.chapters, request: ["listingId": PortFixtures.weebSeriesID])).value.map { $0.toChapter() }
        let actualChapters = try await measured("chapters") {
            try await source.chapters(mangaId: PortFixtures.weebSeriesID)
        }
        XCTAssertEqual(actualChapters, expectedChapters)

        let expectedPages = try expectedPort.validator.validatePages(
            try await expectedPort.runtime.invoke(.pages, request: ["chapterId": PortFixtures.weebChapterID,
                                                                      "quality": "original"])).value.map(\.url)
        let actualPages = try await measured("pages") {
            try await source.pageURLs(chapterId: PortFixtures.weebChapterID,
                                      preferDataSaver: false)
        }
        XCTAssertEqual(actualPages, expectedPages)

        let fileManager = FileManager.default
        let repositoryBytes = try fileManager.attributesOfItem(
            atPath: directory.appendingPathComponent("repositories.json").path)[.size] as? NSNumber
        let hostStorageURL = directory.appendingPathComponent("extension-storage.json")
        let hostStorageByteCount = fileManager.fileExists(atPath: hostStorageURL.path)
            ? (try fileManager.attributesOfItem(atPath: hostStorageURL.path)[.size] as? NSNumber)?.intValue ?? 0
            : 0
        let scriptPath = store.scriptFileURL(for: installed.bundleId, in: repository.id)
        let packageBytes = try fileManager.attributesOfItem(atPath: scriptPath.path)[.size] as? NSNumber
        let requests = "add=\(transport.indexFetches.prefix(1).count), "
            + "refresh=\(transport.indexFetches.dropFirst().count), "
            + "install=\(transport.scriptFetches.count), search=1, detail=1, chapters=1, pages=1"
        print("S6_BUDGET milliseconds=\(measurements) requests={\(requests)} "
              + "storage.repositories.json=\(repositoryBytes?.intValue ?? -1) "
              + "storage.extension-storage.json=\(hostStorageByteCount) "
              + "package=\(packageBytes?.intValue ?? -1) index=\(indexBytes.count) script=\(scriptBytes.count)")
    }
}
