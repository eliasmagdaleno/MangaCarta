import Foundation
import XCTest

/// A temporary directory that belongs to one test (#303).
///
/// Unit tests are hosted in the app, so a directory a test creates under `NSTemporaryDirectory()`
/// lands in the app's own `tmp/` — beside the seeded simulator's fixture — and one never removed
/// stays there. On 2026-09-29 the seeded container held ~14,000 of them.
///
/// Every test directory lives in one parent, `tmp/MangaCartaTests/`, as `<prefix>-<UUID>`. The
/// path is not created: the code under test creates what it needs, as it did before. Removal
/// when the test ends is the normal path; the guarantee is the sweep, as in `TestDefaults`: the
/// first `TestDirectory` a test process creates deletes the ones earlier processes left behind
/// (a crashed test, or a helper with no test to tear it down).
///
/// In an `XCTestCase`, use `makeTestDirectory(_:)`, which registers the removal as a teardown
/// block. In Swift Testing, create one and `defer { directory.remove() }`.
struct TestDirectory: Sendable {
    let url: URL

    /// A fresh path, `tmp/MangaCartaTests/<prefix>-<UUID>/`.
    init(_ prefix: String) {
        _ = Self.sweepEarlierRuns
        url = Self.parent.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// The one folder every test directory lives in, so the sweep (and
    /// `scripts/seed-simulator.sh`) can find them without touching anything else in `tmp/`.
    static let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MangaCartaTests", isDirectory: true)

    /// Runs once per process, before its first directory exists. Only entries untouched for ten
    /// minutes go: two test runs can share one simulator, and the other run's live directories
    /// are recent. No test holds a directory that long.
    private static let sweepEarlierRuns: Void = {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-10 * 60)
        let entries = (try? fileManager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }()
}

extension XCTestCase {
    /// A fresh directory path, removed when the current test ends — however it ends. Safe to call
    /// from `setUp()`: a teardown block added there runs after that test.
    func makeTestDirectory(_ prefix: String) -> URL {
        let directory = TestDirectory(prefix)
        addTeardownBlock { directory.remove() }
        return directory.url
    }
}
