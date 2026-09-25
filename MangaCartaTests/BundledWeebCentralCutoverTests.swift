//
//  BundledWeebCentralCutoverTests.swift
//  MangaCartaTests
//
//  The WeebCentral package that ADR-0003 Amendment 5 bundled is withdrawn by Amendment 6.
//  Four classes so each clause's mutation can be run alone: retiring the bundled record on
//  devices that installed it, the bare-id identity migration (A5 part 5, still needed for
//  data older than the bundle), reconnecting legacy data by reader choice (Amendment 7), and
//  the structural fact that no package ships in the app.
//

import XCTest
@testable import MangaCarta

// MARK: - Retiring the bundled record (Amendment 6)

@MainActor
final class BundledWeebCentralRetirementTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    private let repositoryID = BundledRepositories.weebCentralRepositoryID
    private var qualifiedID: QualifiedSourceID {
        ExtensionInstaller.qualifiedID(repositoryID: repositoryID, localId: "weebcentral")
    }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledWeebCentralRetirementTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "BundledWeebCentralRetirementTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// The state an Amendment 5 build left behind: the bundled repository, active, with its
    /// WeebCentral Source installed and its script on disk.
    private func seedBundledInstall() throws {
        let store = RepositoryStore(directory: directory)
        try store.writeScript(Data("script".utf8), for: "engine", in: repositoryID)
        try store.commit { snapshot in
            snapshot.repositories[self.repositoryID] = RepositoryRecord(
                id: self.repositoryID, indexURL: URL(string: "https://bundled.invalid/weebcentral/index.json")!,
                name: "WeebCentral", addedAt: .now, lastRefreshedAt: nil, state: .active, format: 1)
            snapshot.sources[self.qualifiedID] = InstalledSourceRecord(
                qualifiedId: self.qualifiedID, repositoryID: self.repositoryID, localId: "weebcentral",
                bundleId: "engine", declaration: .object([:]), state: .registered,
                localAdultElevation: nil, installedAt: .now, updatedAt: .now)
        }
    }

    private func compose() -> (AppComposition, SourceRegistry) {
        let registry = SourceRegistry(sources: [])
        return (AppComposition(defaults: defaults, directory: directory, registry: registry), registry)
    }

    func testComposingRetiresTheBundledRepositoryAndKeepsItsData() throws {
        try seedBundledInstall()
        let works = directory.appendingPathComponent("works.json")
        let saved = Data(#"{"listings":[{"sourceId":"\#(qualifiedID.rawValue)","mangaId":"abc"}]}"#.utf8)
        try saved.write(to: works)

        let (composition, registry) = compose()

        let store = RepositoryStore(directory: directory)
        XCTAssertEqual(store.repository(repositoryID)?.state, .removed)
        XCTAssertEqual(store.source(qualifiedID)?.state, .uninstalled)
        XCTAssertNil(store.scriptData(for: "engine", in: repositoryID))
        XCTAssertNil(registry.source(id: qualifiedID.rawValue))
        XCTAssertNil(composition.extensionStorageError)
        XCTAssertEqual(try Data(contentsOf: works), saved)
    }

    func testRetiringIsInertOnALaterLaunchAndOnADeviceThatNeverHadTheBundle() throws {
        _ = compose()
        XCTAssertNil(RepositoryStore(directory: directory).repository(repositoryID))

        try seedBundledInstall()
        _ = compose()
        let (second, _) = compose()
        XCTAssertNil(second.extensionStorageError)
        XCTAssertEqual(RepositoryStore(directory: directory).repository(repositoryID)?.state, .removed)
    }

    /// Its data waits for the reader (Amendment 7): a lookup must not reach another Source.
    func testALegacyListingIsUnavailableRatherThanSentToTheActiveSource() {
        let registry = SourceRegistry(sources: [UpdatesUITestSource()])
        for legacyID in [LegacySourceID.unattributed, WeebCentralIdentityMigration.qualifiedID] {
            let manga = Manga(id: "abc", sourceId: legacyID, title: "Old", description: "",
                              status: "ongoing", year: nil, coverURL: nil, malId: nil,
                              altTitles: [], contentRating: nil)
            XCTAssertNil(registry.source(for: manga), legacyID)
        }
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

    // Part 5's "before the Source registers": composing the app is what runs it.
    func testComposingTheAppRunsTheMigration() {
        let before = WorkStore(directory: directory)
        let workID = before.mint(from: manga("abc", source: legacy))
        before.flush()

        _ = AppComposition(defaults: defaults, directory: directory,
                           registry: SourceRegistry(sources: [MangaDexSource()]))

        XCTAssertEqual(WorkStore(directory: directory).workId(for: ListingKey(sourceId: qualified, mangaId: "abc")),
                       workID)
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

    // #203: the rewrite must not re-serialize numbers. `0.07000000000000001` came back from a
    // JSONSerialization round trip as `0.070000000000000007`, a different Double, in a real
    // updates.json frontier. Only the id's bytes may change.
    func testTheRewriteChangesOnlyTheIdBytes() throws {
        let original = #"{"z":{"known":[{"value":0.07000000000000001},{"value":84.3}]},"#
            + #""a":{"sourceId":"weebcentral","weebcentral:12":1,"note":"weebcentral:x"}}"#
        let url = directory.appendingPathComponent("updates.json")
        try Data(original.utf8).write(to: url)

        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)

        let expected = original
            .replacingOccurrences(of: #""sourceId":"weebcentral""#, with: #""sourceId":"\#(qualified)""#)
            .replacingOccurrences(of: #""weebcentral:12""#, with: #""\#(qualified):12""#)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected,
                       "numbers, key order and non-key strings stay byte-for-byte")
    }

    func testTheStoredBrowseSourceIsMigrated() {
        defaults.set(legacy, forKey: "source.activeID")
        WeebCentralIdentityMigration.run(directory: directory, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "source.activeID"), qualified)
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

// MARK: - Reconnecting by reader choice (Amendment 7)

@MainActor
final class InstalledSourceIDMigrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let repositoryID = UUID()
    private let localID = "mangadex"
    private var targetID: String {
        ExtensionInstaller.qualifiedID(repositoryID: repositoryID, localId: localID).rawValue
    }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledSourceIDMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "InstalledSourceIDMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func installRecord() throws -> InstalledSourceRecord {
        let store = RepositoryStore(directory: directory)
        let record = InstalledSourceRecord(
            qualifiedId: QualifiedSourceID(rawValue: targetID), repositoryID: repositoryID,
            localId: localID, bundleId: "engine", declaration: .object([:]),
            state: .registered, localAdultElevation: nil, installedAt: .now, updatedAt: .now)
        try store.writeScript(Data("script".utf8), for: "engine", in: repositoryID)
        try store.commit { snapshot in
            snapshot.repositories[repositoryID] = RepositoryRecord(
                id: repositoryID, indexURL: URL(string: "https://example.com/index.json")!,
                name: "Reader repository", addedAt: .now, lastRefreshedAt: nil,
                state: .active, format: 1)
            snapshot.sources[record.qualifiedId] = record
        }
        return record
    }

    func testExplicitBindingRewritesSavedDataAndRetryIsInert() throws {
        let record = try installRecord()
        let work = directory.appendingPathComponent("works.json")
        let original = #"{"listings":[{"sourceId":"mangadex","mangaId":"123","title":"mangadex"}],"value":0.07000000000000001}"#
        try Data(original.utf8).write(to: work)
        defaults.set(Data(#"[{"id":"123","title":"Old","sourceId":null},{"id":"456","title":"Old"}]"#.utf8),
                     forKey: "library.items")
        defaults.set(Data(#"[{"id":"789","title":"History"}]"#.utf8), forKey: "history.entries")
        defaults.set(Data(#"{"mangadex:123":{"malId":7}}"#.utf8), forKey: "entityResolution.cache")
        defaults.set("mangadex", forKey: "source.primaryID")

        InstalledSourceIDMigration.request(legacyID: "mangadex", installed: record, defaults: defaults)
        try InstalledSourceIDMigration.run(directory: directory, defaults: defaults)

        let expected = original.replacingOccurrences(of: #""sourceId":"mangadex""#,
                                                      with: #""sourceId":"\#(targetID)""#)
        XCTAssertEqual(try String(contentsOf: work, encoding: .utf8), expected)
        XCTAssertEqual(defaults.string(forKey: "source.primaryID"), targetID)
        let library = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "library.items"))) as? [[String: Any]])
        XCTAssertEqual(library.compactMap { $0["sourceId"] as? String }, [targetID, targetID])
        let history = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "history.entries"))) as? [[String: Any]])
        XCTAssertEqual(history.first?["sourceId"] as? String, targetID)
        let cache = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "entityResolution.cache"))) as? [String: Any])
        XCTAssertNotNil(cache["\(targetID):123"])
        let once = try Data(contentsOf: work)
        try InstalledSourceIDMigration.run(directory: directory, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: work), once)
    }

    func testAppCompositionAppliesBindingBeforeLoadingWorks() throws {
        let record = try installRecord()
        let manga = Manga(id: "123", sourceId: "mangadex", title: "Old title",
                          description: "", status: "ongoing", year: nil, coverURL: nil,
                          malId: nil, altTitles: [], contentRating: nil)
        let works = WorkStore(directory: directory)
        let workID = works.mint(from: manga)
        works.flush()
        let oldListing = ListingKey(sourceId: "mangadex", mangaId: "123")
        let updates = UpdateStateStore(directory: directory, works: works)
        _ = updates.absorb(workId: workID, listing: oldListing, rawNumbers: ["1"])
        updates.flush()
        SourcePreferenceStore(defaults: defaults).choose(oldListing, for: workID)
        InstalledSourceIDMigration.request(legacyID: "mangadex", installed: record, defaults: defaults)

        let composition = AppComposition(defaults: defaults, directory: directory,
                                         registry: SourceRegistry(sources: [MangaDexSource()]))
        let newListing = ListingKey(sourceId: targetID, mangaId: "123")

        XCTAssertEqual(composition.works.workId(for: newListing), workID)
        XCTAssertNotNil(UpdateStateStore(directory: directory).state(for: workID)?.listings[newListing])
        XCTAssertEqual(SourcePreferenceStore(defaults: defaults).choice(for: workID), newListing)
    }

    func testNoBindingOrMissingInstallLeavesDataDormant() throws {
        let work = directory.appendingPathComponent("works.json")
        let original = Data(#"{"listings":[{"sourceId":"mangadex","mangaId":"123"}]}"#.utf8)
        try original.write(to: work)
        try InstalledSourceIDMigration.run(directory: directory, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: work), original)

        let uninstalled = InstalledSourceRecord(
            qualifiedId: QualifiedSourceID(rawValue: targetID), repositoryID: repositoryID,
            localId: localID, bundleId: "engine", declaration: .object([:]),
            state: .uninstalled, localAdultElevation: nil, installedAt: .now, updatedAt: .now)
        InstalledSourceIDMigration.request(legacyID: "mangadex", installed: uninstalled, defaults: defaults)
        try InstalledSourceIDMigration.run(directory: directory, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: work), original)
    }

    func testCollisionStopsBeforeWritingAnyData() throws {
        let record = try installRecord()
        let work = directory.appendingPathComponent("works.json")
        let original = Data(#"{"listings":[{"sourceId":"mangadex","mangaId":"123"},{"sourceId":"\#(targetID)","mangaId":"123"}]}"#.utf8)
        try original.write(to: work)
        defaults.set("mangadex", forKey: "source.primaryID")
        InstalledSourceIDMigration.request(legacyID: "mangadex", installed: record, defaults: defaults)

        XCTAssertThrowsError(try InstalledSourceIDMigration.run(directory: directory, defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: work), original)
        XCTAssertEqual(defaults.string(forKey: "source.primaryID"), "mangadex")
    }

    /// While the compiled Source still ships, it keeps recording under the old id. A spent
    /// binding must not move that later data on the next launch without being offered.
    func testAppliedBindingIsSpentSoLaterLegacyDataStaysAndIsOfferedAgain() throws {
        let record = try installRecord()
        let work = directory.appendingPathComponent("works.json")
        try Data(#"{"listings":[{"sourceId":"mangadex","mangaId":"123"}]}"#.utf8).write(to: work)
        InstalledSourceIDMigration.request(legacyID: "mangadex", installed: record, defaults: defaults)
        try InstalledSourceIDMigration.run(directory: directory, defaults: defaults)

        let later = Data(#"{"listings":[{"sourceId":"\#(targetID)","mangaId":"123"},{"sourceId":"mangadex","mangaId":"456"}]}"#.utf8)
        try later.write(to: work)
        try InstalledSourceIDMigration.run(directory: directory, defaults: defaults)

        XCTAssertEqual(try Data(contentsOf: work), later)
        XCTAssertTrue(InstalledSourceIDMigration.hasLegacyData("mangadex", directory: directory, defaults: defaults))
    }

    /// A collision cannot resolve itself, so it is reported once rather than on every launch.
    func testCollisionIsReportedOnceAndLaterLaunchesProceed() throws {
        let record = try installRecord()
        let work = directory.appendingPathComponent("works.json")
        let original = Data(#"{"listings":[{"sourceId":"mangadex","mangaId":"123"},{"sourceId":"\#(targetID)","mangaId":"123"}]}"#.utf8)
        try original.write(to: work)
        InstalledSourceIDMigration.request(legacyID: "mangadex", installed: record, defaults: defaults)

        XCTAssertThrowsError(try InstalledSourceIDMigration.run(directory: directory, defaults: defaults))
        XCTAssertNoThrow(try InstalledSourceIDMigration.run(directory: directory, defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: work), original)
    }

    func testUnattributedLibraryCollisionStopsBeforeWriting() throws {
        let record = try installRecord()
        let original = Data("[{\"id\":\"123\"},{\"id\":\"123\",\"sourceId\":\"\(targetID)\"}]".utf8)
        defaults.set(original, forKey: "library.items")
        InstalledSourceIDMigration.request(legacyID: "mangadex", installed: record, defaults: defaults)

        XCTAssertThrowsError(try InstalledSourceIDMigration.run(directory: directory, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: "library.items"), original)
    }

    func testUnrelatedTitleDoesNotOfferReconnectAndEmptyObjectCanGainSourceID() throws {
        defaults.set(Data(#"[{"title":"mangadex","sourceId":"other"}]"#.utf8), forKey: "library.items")
        XCTAssertFalse(InstalledSourceIDMigration.hasLegacyData("mangadex", directory: directory, defaults: defaults))
        let rewritten = try InstalledSourceIDMigration.rewrite(Data("[{}]".utf8),
                                                              oldID: "mangadex", newID: targetID,
                                                              legacyNil: true)
        XCTAssertEqual(String(data: rewritten, encoding: .utf8), "[{\"sourceId\":\"\(targetID)\"}]")
    }

    func testBundledWeebCentralIdentityRewritesOnlySourceFields() throws {
        let oldID = WeebCentralIdentityMigration.qualifiedID
        let newID = "\(UUID().uuidString.lowercased()):weebcentral"
        let original = Data("[{\"sourceId\":\"\(oldID)\",\"title\":\"\(oldID)\",\"value\":0.07000000000000001}]".utf8)
        let rewritten = try InstalledSourceIDMigration.rewrite(original, oldID: oldID, newID: newID)
        XCTAssertEqual(String(data: rewritten, encoding: .utf8),
                       "[{\"sourceId\":\"\(newID)\",\"title\":\"\(oldID)\",\"value\":0.07000000000000001}]")
    }
}

final class BundledWeebCentralStructureTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Amendment 6: no Source package ships inside the app.
    func testNoRepositoryPackageShipsInTheApp() {
        XCTAssertNil(Bundle.main.url(forResource: "index", withExtension: "json",
                                     subdirectory: "BundledRepositories/weebcentral"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent("MangaCarta/Resources/BundledRepositories").path))
    }
}
