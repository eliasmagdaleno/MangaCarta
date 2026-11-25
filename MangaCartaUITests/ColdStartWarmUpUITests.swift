import XCTest

/// Not a test of the app: CI runs this once, **non-gating**, before the hermetic UI suites so
/// the first real test does not pay a freshly booted simulator's first-launch costs.
///
/// `bootstatus -b` waiting for boot was not enough. With it in place the first test of the run
/// still failed twice on cold runners while every other test passed, both times
/// `AccessibilityAuditUITests` because it sorts first: once at `app.launch()` ("Timed out while
/// acquiring background assertion", #408) and once in its first accessibility audit ("Audit
/// failed to complete in time", #412). So this walks the same two cold paths — the first app
/// launch and the first audit — and asserts nothing about the result.
///
/// It is hermetic (a local-import launch, as the audit suite uses) and costs seconds locally.
final class ColdStartWarmUpUITests: XCTestCase {
    func testWarmUpFirstLaunchAndAccessibilityAudit() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-local-import", "-uitest-import-fixture", "deflated"]
        app.launchEnvironment["MANGACARTA_UI_TEST_STORAGE_ID"] = UUID().uuidString
        app.launchEnvironment["MANGACARTA_UI_FIXTURE_BASE64"] = LocalImportUITests.fixtureBase64
        app.launch()
        _ = app.tabBars.buttons["Library"].waitForExistence(timeout: 60)
        // Findings and timeouts alike are ignored: the audit's findings belong to
        // AccessibilityAuditUITests, and only having run it matters here.
        try? app.performAccessibilityAudit { _ in true }
        app.terminate()
    }
}
