import XCTest
@testable import MangaCarta

@MainActor
final class AnalyticsConsentTests: XCTestCase {
    func testUndecidedCollectsNothingAnywhere() {
        let store = AnalyticsConsentStore(defaults: makeTestDefaults("analytics-consent"))
        XCTAssertEqual(store.consent, .undecided)
        XCTAssertFalse(store.isCollecting)

        for region in [(nil, nil), ("USA", "US"), ("CHE", "CH"), ("JPN", "US"), ("GBR", "GB")] {
            store.updateRegion(storefrontCountryCode: region.0, localeRegionCode: region.1)
            XCTAssertFalse(store.isCollecting)
        }
        store.accept()
        XCTAssertTrue(store.isCollecting)
        store.decline()
        XCTAssertFalse(store.isCollecting)
    }

    func testExplicitChoiceSurvivesRegionChange() {
        let defaults = makeTestDefaults("analytics-consent")
        let store = AnalyticsConsentStore(defaults: defaults)
        store.accept()
        store.updateRegion(storefrontCountryCode: "USA", localeRegionCode: "US")
        store.updateRegion(storefrontCountryCode: "GBR", localeRegionCode: "GB")
        store.updateRegion(storefrontCountryCode: nil, localeRegionCode: nil)
        XCTAssertEqual(store.consent, .granted)

        store.decline()
        store.updateRegion(storefrontCountryCode: "USA", localeRegionCode: "US")
        store.updateRegion(storefrontCountryCode: "GBR", localeRegionCode: "GB")
        XCTAssertEqual(store.consent, .denied)

        let undecided = AnalyticsConsentStore(defaults: makeTestDefaults("analytics-consent"))
        undecided.updateRegion(storefrontCountryCode: "USA", localeRegionCode: "US")
        XCTAssertFalse(undecided.asksForConsent)
        undecided.updateRegion(storefrontCountryCode: "GBR", localeRegionCode: "GB")
        XCTAssertTrue(undecided.asksForConsent)
        undecided.updateRegion(storefrontCountryCode: nil, localeRegionCode: nil)
        XCTAssertTrue(undecided.asksForConsent)

        let restored = AnalyticsConsentStore(defaults: defaults)
        XCTAssertEqual(restored.consent, .denied)
        XCTAssertEqual(defaults.integer(forKey: AnalyticsConsentStore.noticeVersionKey), 1)
        XCTAssertFalse(restored.shouldShowNotice)
    }

    func testLocaleCannotLoosenAMissingStorefront() {
        for locale in ["US", "CH", "JP", nil] {
            XCTAssertTrue(AnalyticsRegionPolicy.asksForConsent(
                storefrontCountryCode: nil, localeRegionCode: locale
            ))
        }
        XCTAssertTrue(AnalyticsRegionPolicy.asksForConsent(
            storefrontCountryCode: "DEU", localeRegionCode: "US"
        ))
        XCTAssertTrue(AnalyticsRegionPolicy.asksForConsent(
            storefrontCountryCode: "GBR", localeRegionCode: "US"
        ))
    }

    func testRegionTable() {
        let codes = [
            "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR",
            "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK",
            "SI", "ES", "SE", "IS", "LI", "NO", "GB"
        ]
        let alpha3 = [
            "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC",
            "HUN", "IRL", "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK",
            "SVN", "ESP", "SWE", "ISL", "LIE", "NOR", "GBR"
        ]
        for code in codes + alpha3 {
            XCTAssertTrue(AnalyticsRegionPolicy.asksForConsent(
                storefrontCountryCode: code, localeRegionCode: "US"), code
            )
            XCTAssertTrue(AnalyticsRegionPolicy.asksForConsent(
                storefrontCountryCode: code.lowercased(), localeRegionCode: "us"), code
            )
        }
        for code in ["CH", "CHE", "US", "USA", "JP", "JPN", "BR", "CA", "TR", "RU"] {
            XCTAssertFalse(AnalyticsRegionPolicy.asksForConsent(
                storefrontCountryCode: code, localeRegionCode: "US"), code
            )
        }
        XCTAssertTrue(AnalyticsRegionPolicy.asksForConsent(
            storefrontCountryCode: "USA", localeRegionCode: "DE"
        ))
        XCTAssertTrue(AnalyticsRegionPolicy.asksForConsent(
            storefrontCountryCode: "USA", localeRegionCode: "GBR"
        ))
    }

    func testNoticeAndChangeHandler() {
        let defaults = makeTestDefaults("analytics-consent")
        let store = AnalyticsConsentStore(defaults: defaults)
        XCTAssertTrue(store.shouldShowNotice)
        var changes: [(AnalyticsConsent, AnalyticsConsent)] = []
        store.configureConsentChanged { changes.append(($0, $1)) }

        store.accept()
        XCTAssertFalse(store.shouldShowNotice)
        store.accept()
        store.setCollecting(false)
        store.setCollecting(false)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].0, .undecided)
        XCTAssertEqual(changes[0].1, .granted)
        XCTAssertEqual(changes[1].0, .granted)
        XCTAssertEqual(changes[1].1, .denied)

        let decline = AnalyticsConsentStore(defaults: makeTestDefaults("analytics-consent"))
        decline.decline()
        XCTAssertFalse(decline.shouldShowNotice)
        let toggle = AnalyticsConsentStore(defaults: makeTestDefaults("analytics-consent"))
        toggle.setCollecting(true)
        XCTAssertFalse(toggle.shouldShowNotice)
        let suppressed = AnalyticsConsentStore(
            defaults: makeTestDefaults("analytics-consent"), noticeSuppressed: true
        )
        XCTAssertFalse(suppressed.shouldShowNotice)
    }
}
