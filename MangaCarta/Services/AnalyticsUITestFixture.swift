#if DEBUG
import Foundation

enum AnalyticsUITestFixture {
    static var region: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uitest-analytics-region"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func storage() -> (defaults: UserDefaults, directory: URL) {
        let id = ProcessInfo.processInfo.environment["MANGACARTA_UI_TEST_STORAGE_ID"] ?? UUID().uuidString
        let suite = "analytics-ui-test-\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaCarta-AnalyticsUITest-\(id)", isDirectory: true)
        if defaults.bool(forKey: "analytics.uiTest.storageInitialized") == false {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            defaults.set(true, forKey: "analytics.uiTest.storageInitialized")
        }
        return (defaults, directory)
    }
}
#endif
