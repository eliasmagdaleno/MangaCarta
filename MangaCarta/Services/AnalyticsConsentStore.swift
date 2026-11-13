import Combine
import Foundation

enum AnalyticsConsent: String, Codable {
    case undecided
    case granted
    case denied
}

@MainActor
final class AnalyticsConsentStore: ObservableObject {
    static let consentKey = "analytics.consent"
    static let noticeVersionKey = "analytics.noticeVersion"
    static let currentNoticeVersion = 1

    @Published private(set) var consent: AnalyticsConsent
    @Published private(set) var asksForConsent = true
    @Published private(set) var noticeVersion: Int

    private let defaults: UserDefaults
    private let noticeSuppressed: Bool
    private var consentChanged: ((_ old: AnalyticsConsent, _ new: AnalyticsConsent) -> Void)?

    init(defaults: UserDefaults = .standard, noticeSuppressed: Bool = false) {
        self.defaults = defaults
        self.noticeSuppressed = noticeSuppressed
        consent = defaults.string(forKey: Self.consentKey)
            .flatMap(AnalyticsConsent.init(rawValue:)) ?? .undecided
        noticeVersion = defaults.integer(forKey: Self.noticeVersionKey)
    }

    var isCollecting: Bool {
        consent == .granted
    }

    var shouldShowNotice: Bool {
        !noticeSuppressed && noticeVersion < Self.currentNoticeVersion
    }

    func updateRegion(storefrontCountryCode: String?, localeRegionCode: String?) {
        asksForConsent = AnalyticsRegionPolicy.asksForConsent(
            storefrontCountryCode: storefrontCountryCode,
            localeRegionCode: localeRegionCode
        )
    }

    func configureConsentChanged(
        _ handler: @escaping (_ old: AnalyticsConsent, _ new: AnalyticsConsent) -> Void
    ) {
        consentChanged = handler
    }

    func accept() {
        setConsent(.granted)
    }

    func decline() {
        setConsent(.denied)
    }

    func setCollecting(_ on: Bool) {
        setConsent(on ? .granted : .denied)
    }

    private func setConsent(_ newConsent: AnalyticsConsent) {
        let oldConsent = consent
        consent = newConsent
        defaults.set(newConsent.rawValue, forKey: Self.consentKey)
        noticeVersion = Self.currentNoticeVersion
        defaults.set(noticeVersion, forKey: Self.noticeVersionKey)
        if oldConsent != newConsent {
            consentChanged?(oldConsent, newConsent)
        }
    }
}
