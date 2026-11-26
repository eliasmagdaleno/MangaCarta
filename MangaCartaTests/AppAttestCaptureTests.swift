import CryptoKit
import DeviceCheck
import Foundation
import XCTest

/// Captures one real App Attest attestation and two assertions for the Worker's tests
/// (App Attest design, Amendment 1 item 9). It runs only on a device that supports App Attest,
/// so it is skipped on the simulator and in CI. Run it once on the owner's iPhone from Xcode,
/// then copy the `APP_ATTEST_CAPTURE` line from the console into
/// `server/analytics-worker/test/fixtures/device-capture.json`.
///
/// Everything in the capture is throwaway: a fresh key, and the fixed ids below. It holds no
/// personal data.
///
/// It is also skipped while the build carries no App Attest entitlement. The entitlement is held
/// back until the owner enrolls in the Apple Developer Program: a personal team can't sign it, so
/// adding it earlier would break every device build (App Attest design, Amendment 1).
final class AppAttestCaptureTests: XCTestCase {
    /// 32 fixed bytes standing in for a Worker challenge. The Worker test seeds it as issued.
    static let challengeHex = "4d616e6761436172746120417070417474657374206361707475726520763031"
    /// A fixed analytics id, upper-case as the app spells it. The hash uses it lower-cased.
    static let install = "0A7E57C0-FFEE-4C0D-8A11-C0FFEE000001"
    /// Two fixed v1 bodies, signed byte for byte.
    static let bodies = [
        #"{"v":1,"events":[{"v":1,"install":"0A7E57C0-FFEE-4C0D-8A11-C0FFEE000001","day":"2026-11-25","app":"1.0 (1)","name":"app_active"}]}"#,
        #"{"v":1,"events":[{"v":1,"install":"0A7E57C0-FFEE-4C0D-8A11-C0FFEE000001","day":"2026-11-25","app":"1.0 (1)","name":"search_used"}]}"#,
    ]

    func testCaptureAttestationAndAssertions() async throws {
        let service = DCAppAttestService.shared
        try XCTSkipUnless(service.isSupported, "App Attest is unsupported here (simulator or CI)")
        try XCTSkipUnless(
            Self.provisionedAppAttestEnvironment() == "production",
            "This build has no production App Attest entitlement: enroll in the Apple Developer Program, "
                + "enable App Attest for the App ID, and add com.apple.developer.devicecheck.appattest-environment"
        )

        let challenge = try XCTUnwrap(Data(hex: Self.challengeHex))
        let clientDataHash = Data(SHA256.hash(data: challenge + Data(Self.install.lowercased().utf8)))

        let keyID = try await service.generateKey()
        let attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
        var assertions: [String] = []
        for body in Self.bodies {
            let hash = Data(SHA256.hash(data: Data(body.utf8)))
            assertions.append(try await service.generateAssertion(keyID, clientDataHash: hash).base64EncodedString())
        }

        let capture: [String: Any] = [
            "appID": "V2BG9SHQYS.Elias-Magdaleno.Manga-Reader",
            "challengeHex": Self.challengeHex,
            "install": Self.install,
            "key": keyID,
            "attestation": attestation.base64EncodedString(),
            "bodies": Self.bodies,
            "assertions": assertions,
            "bundleVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let json = try JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys])
        let line = String(decoding: json, as: UTF8.self)
        print("APP_ATTEST_CAPTURE \(line)")
        let attachment = XCTAttachment(string: line)
        attachment.name = "device-capture.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension AppAttestCaptureTests {
    /// The App Attest environment the app's provisioning profile grants, or nil. A device build
    /// carries `embedded.mobileprovision`: a signed envelope around a plain XML property list.
    static func provisionedAppAttestEnvironment(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["com.apple.developer.devicecheck.appattest-environment"] as? String
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
