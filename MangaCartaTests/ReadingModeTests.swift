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
