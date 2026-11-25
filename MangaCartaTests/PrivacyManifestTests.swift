import Foundation
import XCTest
@testable import MangaCarta

final class PrivacyManifestTests: XCTestCase {
    func testAnalyticsEntries() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertTrue((plist["NSPrivacyTrackingDomains"] as? [String] ?? []).isEmpty)

        let types = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        func entry(_ name: String) throws -> [String: Any] {
            let matches = types.filter { $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataType\(name)" }
            XCTAssertEqual(matches.count, 1, name)
            return try XCTUnwrap(matches.first)
        }
        let purpose = "NSPrivacyCollectedDataTypePurpose"
        let device = try entry("DeviceID")
        XCTAssertEqual(device["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(device["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        XCTAssertEqual(device["NSPrivacyCollectedDataTypePurposes"] as? [String], ["\(purpose)Analytics"])
        let interaction = try entry("ProductInteraction")
        XCTAssertEqual(interaction["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(interaction["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        XCTAssertEqual(Set(interaction["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []),
                       ["\(purpose)AppFunctionality", "\(purpose)Analytics"])
    }
}
