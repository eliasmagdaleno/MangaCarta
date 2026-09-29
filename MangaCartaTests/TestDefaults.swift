import Foundation
import XCTest

/// A `UserDefaults` suite that belongs to one test (#296).
///
/// Unit tests are hosted in the app, so every suite a test creates is a plist in the app's own
/// `Library/Preferences` — beside the seeded simulator's fixture — and one never removed stays
/// there for good. Measured on the simulator (iOS 26.5):
///
/// - `removePersistentDomain` empties a suite but leaves its plist on disk;
/// - deleting the plist alone leaves the values readable from cfprefsd's cache;
/// - doing both, as `remove()` does, still loses a race: once the plist has reached disk,
///   cfprefsd can write an emptied copy back *after* the delete. That happened to 20 of 20
///   suites that were synchronized before removal, and to ~290 per full unit run.
///
/// So `remove()` is best effort, and the guarantee is the sweep: every suite is named
/// `MangaCartaTests.<prefix>.<UUID>`, and the first `TestDefaults` a test process creates deletes
/// the ones earlier processes left behind. The litter is bounded by one run instead of growing.
///
/// In an `XCTestCase`, use `makeTestDefaults(_:)`, which registers the removal as a teardown
/// block. In Swift Testing, create one and `defer { suite.remove() }`.
struct TestDefaults: @unchecked Sendable {
    let suiteName: String
    let defaults: UserDefaults

    /// A fresh suite named `MangaCartaTests.<prefix>.<UUID>`.
    init(_ prefix: String) {
        _ = Self.sweepEarlierRuns
        suiteName = "\(Self.namePrefix)\(prefix).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: Self.preferences.appendingPathComponent("\(suiteName).plist"))
    }

    /// Every suite's name starts with this, so the sweep (and `scripts/seed-simulator.sh`) can
    /// find them without touching anything else in `Library/Preferences`.
    static let namePrefix = "MangaCartaTests."

    private static let preferences = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences", isDirectory: true)

    /// Runs once per process, before its first suite exists. Only plists untouched for ten
    /// minutes go: two test runs can share one simulator, and the other run's live suites are
    /// recent. No test holds a suite that long.
    private static let sweepEarlierRuns: Void = {
        let cutoff = Date().addingTimeInterval(-10 * 60)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: preferences, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix(namePrefix) {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }()
}

extension XCTestCase {
    /// A fresh suite, removed when the current test ends — however it ends. Safe to call from
    /// `setUp()`: a teardown block added there runs after that test.
    func makeTestDefaults(_ prefix: String) -> UserDefaults {
        let suite = TestDefaults(prefix)
        addTeardownBlock { suite.remove() }
        return suite.defaults
    }
}
