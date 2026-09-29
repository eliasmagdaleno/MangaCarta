import Foundation
import XCTest

/// A `UserDefaults` suite that belongs to one test and is gone once `remove()` runs (#296).
///
/// Unit tests are hosted in the app, so every suite a test creates is a plist in the app's own
/// `Library/Preferences` — beside the seeded simulator's fixture — and one never removed stays
/// there for good. Removing a suite takes both steps in `remove()`: `removePersistentDomain`
/// empties it but leaves its plist on disk, and deleting the plist alone leaves the values
/// readable from cfprefsd's cache. Both were checked on the simulator (iOS 26.5).
///
/// In an `XCTestCase`, use `makeTestDefaults(_:)`, which registers the removal as a teardown
/// block. In Swift Testing, create one and `defer { suite.remove() }`.
struct TestDefaults: @unchecked Sendable {
    let suiteName: String
    let defaults: UserDefaults

    /// A fresh suite named `<prefix>.<UUID>`.
    init(_ prefix: String) {
        suiteName = "\(prefix).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        let plist = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
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
