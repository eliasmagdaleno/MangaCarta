import Combine
import Foundation
import Testing
@testable import MangaCarta

@MainActor
private struct StoreHarness {
    let suite: TestDefaults
    let directory: TestDirectory
    let works: WorkStore
    let store: ReadingModeStore

    init(_ prefix: String, seedDefaults: (UserDefaults) -> Void = { _ in }) {
        suite = TestDefaults(prefix)
        directory = TestDirectory(prefix)
        seedDefaults(suite.defaults)
        works = WorkStore(directory: directory.url)
        store = ReadingModeStore(defaults: suite.defaults, works: works)
    }

    func mint(_ id: String) -> WorkID {
        works.mint(from: Manga(id: id, sourceId: "src", title: id, description: "",
                               status: "ongoing", year: nil, coverURL: nil, malId: nil))
    }

    /// A second store over the same defaults and Works: what the next launch sees.
    func reopened() -> ReadingModeStore { ReadingModeStore(defaults: suite.defaults, works: works) }

    func remove() { suite.remove(); directory.remove() }
}

@Suite("Reading mode store")
@MainActor
struct ReadingModeStoreTests {
    @Test func ownModeBeatsTheDefaultAndNilUsesTheDefault() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a"), b = h.mint("b")
        h.store.set(.leftToRight, for: a)
        #expect(h.store.effectiveMode(for: a) == .leftToRight)
        #expect(h.store.effectiveMode(for: b) == .rightToLeft)
        #expect(h.store.effectiveMode(for: nil) == .rightToLeft)
        h.store.defaultMode = .vertical
        #expect(h.store.effectiveMode(for: a) == .leftToRight)
        #expect(h.store.effectiveMode(for: b) == .vertical)
    }

    @Test func setClearAndSeed() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a")
        #expect(h.store.seed(.rightToLeft, for: a) == true)
        #expect(h.store.seed(.leftToRight, for: a) == false)
        #expect(h.store.mode(for: a) == .rightToLeft)
        h.store.clear(for: a)
        #expect(h.store.mode(for: a) == nil)
        h.store.set(.rightToLeft, for: a)            // equal to the default, still pinned
        #expect(h.store.mode(for: a) == .rightToLeft)
    }

    @Test func modesPersistAcrossStores() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a")
        h.store.set(.vertical, for: a)
        h.store.defaultMode = .leftToRight
        let next = h.reopened()
        #expect(next.mode(for: a) == .vertical)
        #expect(next.defaultMode == .leftToRight)
        #expect(h.suite.defaults.string(forKey: ReadingModeStore.defaultKey) == "leftToRight")
    }

    @Test func unknownRawValuesAreDropped() throws {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let good = h.mint("good"), bad = h.mint("bad")
        let data = try JSONEncoder().encode([good.raw.uuidString: "vertical", bad.raw.uuidString: "sideways"])
        h.suite.defaults.set(data, forKey: ReadingModeStore.workModesKey)
        let loaded = h.reopened()
        #expect(loaded.mode(for: good) == .vertical)        // the known entry survives
        #expect(loaded.mode(for: bad) == nil)               // the unknown one is dropped

        let garbage = StoreHarness("ReadingModeStore") {
            $0.set(Data("not json".utf8), forKey: ReadingModeStore.workModesKey)
        }
        defer { garbage.remove() }
        let a = garbage.mint("a")
        #expect(garbage.store.mode(for: a) == nil)
        garbage.store.set(.vertical, for: a)
        #expect(garbage.reopened().mode(for: a) == .vertical)
    }

    @Test func existingGlobalValueBecomesTheDefault() {
        let h = StoreHarness("ReadingModeStore") { $0.set("vertical", forKey: "readingMode") }
        defer { h.remove() }
        #expect(h.store.defaultMode == .vertical)
        #expect(h.store.effectiveMode(for: h.mint("a")) == .vertical)
    }

    @Test func mergedAwayModeFollowsTheSurvivor() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        #expect(h.store.mode(for: winner) == .leftToRight)
        #expect(h.store.mode(for: loser) == .leftToRight)   // a stale id resolves too
    }

    @Test func survivorsOwnModeWinsAMerge() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.vertical, for: winner)
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        #expect(h.store.mode(for: winner) == .vertical)
        h.store.set(.vertical, for: winner)                // a write re-keys and drops the loser
        let raw = h.suite.defaults.data(forKey: ReadingModeStore.workModesKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        #expect(raw == [winner.raw.uuidString: "vertical"])
    }

    @Test func aWriteDropsKeysThatResolveToNoWork() throws {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let a = h.mint("a")
        let orphan = UUID().uuidString                      // no Work has this id
        let data = try JSONEncoder().encode([orphan: "vertical"])
        h.suite.defaults.set(data, forKey: ReadingModeStore.workModesKey)
        let loaded = h.reopened()
        loaded.set(.leftToRight, for: a)
        let raw = h.suite.defaults.data(forKey: ReadingModeStore.workModesKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        #expect(raw == [a.raw.uuidString: "leftToRight"])
    }

    @Test func clearOnTheSurvivorAlsoClearsAMergedAwayMode() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        h.store.clear(for: winner)
        #expect(h.store.mode(for: winner) == nil)
        #expect(h.reopened().mode(for: winner) == nil)
    }

    @Test func readAfterMergeDoesNotPublish() {
        let h = StoreHarness("ReadingModeStore"); defer { h.remove() }
        let winner = h.mint("winner"), loser = h.mint("loser")
        h.store.set(.leftToRight, for: loser)
        h.works.merge(loser, into: winner)
        var published = 0
        let sink = h.store.objectWillChange.sink { published += 1 }
        _ = h.store.effectiveMode(for: winner)
        _ = h.store.mode(for: winner)
        sink.cancel()
        #expect(published == 0)
    }
}

@Suite("ComicInfo reading mode")
struct ComicInfoReadingModeTests {
    private func info(_ manga: String?) -> ComicInfo? {
        let field = manga.map { "<Manga>\($0)</Manga>" } ?? ""
        return ComicInfo.parse(Data("<ComicInfo><Series>S</Series>\(field)</ComicInfo>".utf8))
    }

    @Test func mangaValuesMapToModes() {
        #expect(info("YesAndRightToLeft")?.readingMode == .rightToLeft)
        #expect(info("No")?.readingMode == .leftToRight)
        #expect(info("Yes")?.readingMode == nil)
        #expect(info("Unknown")?.readingMode == nil)
        #expect(info(nil)?.readingMode == nil)
        #expect(info("YesAndRightToLeft")?.manga == "YesAndRightToLeft")
    }

    @Test func mangaValueMapsCaseInsensitively() {
        #expect(info(" yesandrighttoleft ")?.readingMode == .rightToLeft)
        #expect(info("NO")?.readingMode == .leftToRight)
    }

    @Test func aRecordStoredBeforeTheFieldStillDecodes() throws {
        let old = Data(#"{"series":"S","genres":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ComicInfo.self, from: old)
        #expect(decoded.series == "S")
        #expect(decoded.manga == nil)
        #expect(decoded.readingMode == nil)
    }
}

@MainActor
private struct SeedingHarness {
    let importer: LocalImportViewModel
    let library: LibraryStore
    let works: WorkStore
    let modes: ReadingModeStore

    init(_ dir: TestDirectory, _ suite: TestDefaults) {
        works = WorkStore(directory: dir.url.appendingPathComponent("works"))
        let store = LocalLibraryStore(root: dir.url.appendingPathComponent("library"))
        let registry = SourceRegistry(sources: [LocalSource(store: store)], defaults: suite.defaults)
        library = LibraryStore(defaults: suite.defaults, works: works, registry: registry)
        modes = ReadingModeStore(defaults: suite.defaults, works: works)
        importer = LocalImportViewModel()
        importer.configure(registry: registry, library: library, works: works, readingModes: modes)
    }
}

@MainActor
private func archive(_ dir: TestDirectory, _ name: String, series: String, manga: String?) throws -> URL {
    try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    let url = dir.url.appendingPathComponent(name)
    let field = manga.map { "<Manga>\($0)</Manga>" } ?? ""
    let xml = "<ComicInfo><Series>\(series)</Series><Number>\(name)</Number>\(field)</ComicInfo>"
    try LocalTestZip.write([("001.png", LocalTestZip.png), ("ComicInfo.xml", Data(xml.utf8))], to: url)
    return url
}

@Suite("Reading mode seeding on import")
@MainActor
struct ReadingModeSeedingTests {
    private func workID(_ works: WorkStore, series: String) -> WorkID? {
        works.workId(for: ListingKey(sourceId: LocalSource.sourceID,
                                     mangaId: LocalSeriesIdentity.seriesID(for: series)))
    }

    @Test func rightToLeftImportSeedsTheWork() async throws {
        let dir = TestDirectory("ReadingModeSeeding"); defer { dir.remove() }
        let suite = TestDefaults("ReadingModeSeeding"); defer { suite.remove() }
        let h = SeedingHarness(dir, suite)
        await h.importer.importFilesAndWait([try archive(dir, "1.cbz", series: "rtl", manga: "YesAndRightToLeft")])
        let id = try #require(workID(h.works, series: "rtl"))
        #expect(h.modes.mode(for: id) == .rightToLeft)
    }

    @Test func laterSeriesFileDoesNotOverwriteSeededMode() async throws {
        let dir = TestDirectory("ReadingModeSeeding"); defer { dir.remove() }
        let suite = TestDefaults("ReadingModeSeeding"); defer { suite.remove() }
        let h = SeedingHarness(dir, suite)
        await h.importer.importFilesAndWait([try archive(dir, "1.cbz", series: "mixed", manga: "YesAndRightToLeft")])
        await h.importer.importFilesAndWait([try archive(dir, "2.cbz", series: "mixed", manga: "No")])
        let id = try #require(workID(h.works, series: "mixed"))
        #expect(h.modes.mode(for: id) == .rightToLeft)
    }

    @Test func importLeavesAnExistingModeAlone() async throws {
        let dir = TestDirectory("ReadingModeSeeding"); defer { dir.remove() }
        let suite = TestDefaults("ReadingModeSeeding"); defer { suite.remove() }
        let h = SeedingHarness(dir, suite)
        await h.importer.importFilesAndWait([try archive(dir, "1.cbz", series: "chosen", manga: nil)])
        let id = try #require(workID(h.works, series: "chosen"))
        #expect(h.modes.mode(for: id) == nil)                 // no Manga field: nothing seeded
        h.modes.set(.vertical, for: id)
        await h.importer.importFilesAndWait([try archive(dir, "2.cbz", series: "chosen", manga: "No")])
        #expect(h.modes.mode(for: id) == .vertical)
    }
}
