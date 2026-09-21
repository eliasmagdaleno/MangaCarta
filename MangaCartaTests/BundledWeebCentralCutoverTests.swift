//
//  BundledWeebCentralCutoverTests.swift
//  MangaCartaTests
//
//  ADR-0003 Amendment 5 and repository format design §12: WeebCentral ships as a bundled
//  package installed through the ordinary installer under a fixed identity; the compiled
//  Source is gone. Three classes so each clause's mutation can be run alone:
//  first launch (A5 parts 1, 3, 4), the identity migration (part 5), and the structural
//  facts the cutover PR promised (one copy of the engine; the Settings predicate).
//

import XCTest
@testable import MangaCarta

// MARK: - First launch, uninstall, app update, adult refusal

@MainActor
final class BundledWeebCentralInstallTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    private let repositoryID = BundledRepositories.weebCentralRepositoryID
    private var qualifiedID: String {
        ExtensionInstaller.qualifiedID(repositoryID: repositoryID, localId: "weebcentral").rawValue
    }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledWeebCentralInstallTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "BundledWeebCentralInstallTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A composition over the real app bundle's package, with its own registry so the
    /// singleton never leaks between tests.
    private func compose() -> (AppComposition, SourceRegistry) {
        let registry = SourceRegistry(sources: [MangaDexSource()])
        let composition = AppComposition(defaults: defaults, directory: directory, registry: registry)
        return (composition, registry)
    }

    // A5 part 1 + part 2: the ordinary installer, the fixed id, MangaDex first.
    func testFirstLaunchInstallsBundledWeebCentralAfterMangaDex() async throws {
        let (composition, registry) = compose()
        XCTAssertEqual(registry.sources.map(\.id), [MangaDexSource.sourceID],
                       "nothing is installed until installBundledSources() is awaited")

        let failure = await composition.extensions?.installBundledSources()

        XCTAssertNil(failure)
        XCTAssertEqual(registry.sources.map(\.id), [MangaDexSource.sourceID, qualifiedID])
        XCTAssertEqual(qualifiedID, "9c6a1c65-2ab0-4b53-8f91-55bdfdeb8e55:weebcentral",
                       "the identity is the compiled-in constant, the same on every device")
        let source = try XCTUnwrap(registry.source(id: qualifiedID) as? ExtensionSource)
        XCTAssertEqual(source.name, "WeebCentral")
        XCTAssertFalse(source.isNSFW)
        XCTAssertNil(registry.source(id: "weebcentral"), "the bare compiled id no longer resolves")
    }

    func testSecondLaunchDoesNotInstallTwice() async throws {
        let (first, _) = compose()
        await first.extensions?.installBundledSources()

        let (second, registry) = compose()
        await second.extensions?.installBundledSources()

        XCTAssertEqual(registry.sources.map(\.id), [MangaDexSource.sourceID, qualifiedID])
        XCTAssertEqual(second.extensions?.repositories.repositories.count, 1)
        XCTAssertEqual(second.extensions?.repositories.sources(in: repositoryID).count, 1)
    }

    // A5 part 4: uninstall is respected across launches; the Source is re-offered, not reinstalled.
    func testAnUninstalledBundledSourceStaysUninstalledAtTheNextLaunchAndIsStillOffered() async throws {
        let (first, _) = compose()
        await first.extensions?.installBundledSources()
        try first.extensions?.installer.uninstall(QualifiedSourceID(rawValue: qualifiedID))

        let (second, registry) = compose()
        let failure = await second.extensions?.installBundledSources()

        XCTAssertNil(failure)
        XCTAssertEqual(registry.sources.map(\.id), [MangaDexSource.sourceID])
        let record = try XCTUnwrap(second.extensions?.repositories.sources(in: repositoryID).first)
        XCTAssertEqual(record.state, .uninstalled)
        let offered = second.extensions?.installer.listings[repositoryID]?.entries.compactMap(\.localId)
        XCTAssertEqual(offered, ["weebcentral"], "the repositories screen can still offer it")
    }

    // A5 part 3 + §12 "Operations": a new bundle version arrives with the app and is
    // offered through refresh, applied only by the reader-confirmed updateBundle.
    func testAnAppUpdateOffersTheNewBundleVersionButAppliesItOnlyThroughUpdateBundle() async throws {
        let package = try copiedPackage()
        let transport = BundledRepositoryTransport(resourceDirectory: package)
        let store = RepositoryStore(directory: directory)
        let installer = ExtensionInstaller(store: store, registry: SourceLifecycleRegistry(),
                                           transport: transport,
                                           dataEraser: RecordingDataEraser(storage: try HostStorageRepository(directory: directory)),
                                           acknowledgeAdult: { _ in false })
        let repository = try await installer.addRepository(at: BundledRepositories.weebCentralURL,
                                                           repositoryID: repositoryID)
        let installed = try await installer.install(localId: "weebcentral", from: repository.id)
        XCTAssertEqual(store.bundle(installed.bundleId, in: repositoryID)?.version, 1)

        try rewriteIndex(in: package) { index in index["bundles"] = (index["bundles"] as! [[String: Any]]).map {
            var b = $0; b["version"] = 2; return b
        } }
        _ = try await installer.refresh(repositoryID)

        XCTAssertEqual(installer.listings[repositoryID]?.availableUpdates[installed.bundleId], 2, "offered")
        XCTAssertEqual(store.bundle(installed.bundleId, in: repositoryID)?.version, 1, "not applied by refresh")

        try await installer.updateBundle(installed.bundleId, in: repositoryID)
        XCTAssertEqual(store.bundle(installed.bundleId, in: repositoryID)?.version, 2)
    }

    // §12 "Adult Sources": a bundled index may declare only none-class Sources.
    func testABundledIndexDeclaringAnAdultSourceIsRefusedWithASentence() async throws {
        let package = try copiedPackage()
        try rewriteIndex(in: package) { index in index["bundles"] = (index["bundles"] as! [[String: Any]]).map {
            var b = $0
            b["sources"] = (b["sources"] as! [[String: Any]]).map { var s = $0; s["adult"] = "mixed"; return s }
            return b
        } }
        let transport = BundledRepositoryTransport(resourceDirectory: package)

        do {
            _ = try await transport.fetchIndex(at: BundledRepositories.weebCentralURL)
            XCTFail("a mixed Source in a bundled index must be refused")
        } catch let error as BundledRepositoryTransport.Error {
            XCTAssertEqual(error, .adultSource("weebcentral"))
            XCTAssertTrue(error.localizedDescription.contains("weebcentral"))
        }
    }

    func testTheBundledScriptDigestIsCheckedLikeAnyOther() async throws {
        let package = try copiedPackage()
        let script = package.appendingPathComponent("engine.js")
        try (try Data(contentsOf: script) + Data("\n// tampered".utf8)).write(to: script)
        let installer = ExtensionInstaller(store: RepositoryStore(directory: directory),
                                           registry: SourceLifecycleRegistry(),
                                           transport: BundledRepositoryTransport(resourceDirectory: package),
                                           dataEraser: RecordingDataEraser(storage: try HostStorageRepository(directory: directory)),
                                           acknowledgeAdult: { _ in false })
        let repository = try await installer.addRepository(at: BundledRepositories.weebCentralURL,
                                                           repositoryID: repositoryID)
        do {
            _ = try await installer.install(localId: "weebcentral", from: repository.id)
            XCTFail("a script whose bytes do not match the index digest must not install")
        } catch let error as ExtensionInstallError {
            if case .scriptDigestMismatch = error {} else { XCTFail("unexpected \(error)") }
        }
    }

    // MARK: helpers

    private func copiedPackage() throws -> URL {
        let copy = directory.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.copyItem(at: PortFixtures.packageDirectory, to: copy)
        return copy
    }

    private func rewriteIndex(in package: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = package.appendingPathComponent("index.json")
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&index)
        try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted]).write(to: url)
    }
}

// MARK: - Identity migration (A5 part 5)

@MainActor
final class WeebCentralIdentityMigrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let legacy = WeebCentralIdentityMigration.legacyID
    private let qualified = WeebCentralIdentityMigration.qualifiedID

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeebCentralIdentityMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "WeebCentralIdentityMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func manga(_ id: String, source: String) -> Manga {
        Manga(id: id, sourceId: source, title: "Berserk", description: "", status: "ongoing",
              year: nil, coverURL: nil, malId: nil, altTitles: [], contentRating: nil)
    }

    func testAWorkMintedFromTheCompiledListingKeepsItsIdAndFollowsTheNewSourceId() throws {
        let before = WorkStore(directory: directory)
        let workID = before.mint(from: manga("abc", source: legacy))
        let untouched = before.mint(from: manga("xyz", source: MangaDexSource.sourceID))
        before.flush()

        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)

        let after = WorkStore(directory: directory)
        XCTAssertEqual(after.workId(for: ListingKey(sourceId: qualified, mangaId: "abc")), workID,
                       "the Work is the identity (ADR-0001); only its Listing's source id moved")
        XCTAssertNil(after.workId(for: ListingKey(sourceId: legacy, mangaId: "abc")))
        XCTAssertEqual(after.workId(for: ListingKey(sourceId: MangaDexSource.sourceID, mangaId: "xyz")), untouched)
    }

    func testDefaultsValuesAndPrefixedDictionaryKeysAreRewritten() throws {
        // A bare value (source.primaryID) and EntityResolutionStore's "<sourceId>:<mangaId>" keys.
        defaults.set(legacy, forKey: "source.primaryID")
        let cache: [String: [String: Int]] = ["\(legacy):123": ["malId": 7], "mangadex:9": ["malId": 8]]
        defaults.set(try JSONEncoder().encode(cache), forKey: "entityResolution.cache")

        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "source.primaryID"), qualified)
        let rewritten = try JSONDecoder().decode([String: [String: Int]].self,
                                                 from: XCTUnwrap(defaults.data(forKey: "entityResolution.cache")))
        XCTAssertEqual(rewritten, ["\(qualified):123": ["malId": 7], "mangadex:9": ["malId": 8]])
    }

    func testASecondRunIsByteForByteInert() throws {
        let store = WorkStore(directory: directory)
        _ = store.mint(from: manga("abc", source: legacy))
        store.flush()
        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)
        let once = try Data(contentsOf: directory.appendingPathComponent("works.json"))

        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("works.json")), once)
    }

    func testAFileWithNoLegacyReferenceIsNotRewritten() throws {
        let store = WorkStore(directory: directory)
        _ = store.mint(from: manga("xyz", source: MangaDexSource.sourceID))
        store.flush()
        let file = directory.appendingPathComponent("works.json")
        let before = try Data(contentsOf: file)

        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)

        XCTAssertEqual(try Data(contentsOf: file), before, "untouched means byte-for-byte, not merely equivalent")
    }
}

// MARK: - Structural facts

final class BundledWeebCentralStructureTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The cutover PR's promise: one copy of the engine script in the repository.
    func testExactlyOneCopyOfTheEngineScriptExists() throws {
        let marker = "registerEngine(\"htmlSelectorTheme\""
        var hits: [String] = []
        for top in ["MangaCarta", "MangaCartaTests", "MangaCartaUITests", "scripts"] {
            let root = repositoryRoot.appendingPathComponent(top)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where ["swift", "js", "json", "md"].contains(url.pathExtension) {
                if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(marker) {
                    hits.append(url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""))
                }
            }
        }
        XCTAssertEqual(hits, ["MangaCarta/Resources/BundledRepositories/weebcentral/engine.js"])
    }

    /// §12: no Remove and no Change URL for a bundled repository — the predicate the screen uses.
    @MainActor
    func testOnlyTheBundledRepositoryIsBundled() {
        let bundled = RepositoryRecord(id: BundledRepositories.weebCentralRepositoryID,
                                       indexURL: BundledRepositories.weebCentralURL, name: "WeebCentral",
                                       addedAt: .now, lastRefreshedAt: nil, state: .active, format: 1)
        let other = RepositoryRecord(id: UUID(), indexURL: URL(string: "https://repo.test/index.json")!,
                                     name: "Other", addedAt: .now, lastRefreshedAt: nil, state: .active, format: 1)
        XCTAssertTrue(RepositorySettingsViewModel.isBundled(bundled))
        XCTAssertFalse(RepositorySettingsViewModel.isBundled(other))
    }
}
