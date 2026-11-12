import Foundation

enum AnalyticsRegionPolicy {
    private static let consentRegionCodes: Set<String> = [
        "AT", "AUT", "BE", "BEL", "BG", "BGR", "HR", "HRV", "CY", "CYP",
        "CZ", "CZE", "DK", "DNK", "EE", "EST", "FI", "FIN", "FR", "FRA",
        "DE", "DEU", "GR", "GRC", "EL", "HU", "HUN", "IE", "IRL", "IT", "ITA",
        "LV", "LVA", "LT", "LTU", "LU", "LUX", "MT", "MLT", "NL", "NLD",
        "PL", "POL", "PT", "PRT", "RO", "ROU", "SK", "SVK", "SI", "SVN",
        "ES", "ESP", "SE", "SWE", "IS", "ISL", "LI", "LIE", "NO", "NOR",
        "GB", "GBR", "UK"
    ]

    static func asksForConsent(
        storefrontCountryCode: String?,
        localeRegionCode: String?
    ) -> Bool {
        guard let storefrontCountryCode, !storefrontCountryCode.isEmpty else {
            return true
        }

        let storefront = storefrontCountryCode.uppercased()
        let locale = localeRegionCode?.uppercased()
        return consentRegionCodes.contains(storefront) || (locale.map(consentRegionCodes.contains) ?? false)
    }
}
