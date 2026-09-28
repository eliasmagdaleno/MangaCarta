//
//  ImageLoadReportTarget.swift
//  MangaCarta
//
//  Where, and for which image origins, a Source wants image-load reports
//  (ADR-0003 Amendment 9). The caller of an image load passes it; the loader never
//  guesses a Source from a URL (image-load reports design §2).
//

import Foundation

struct ImageLoadReportTarget: Sendable, Equatable {
    let sourceID: QualifiedSourceID
    let endpoint: URL
    /// `assetOrigins`-syntax patterns, already validated against the declaration.
    let origins: [String]

    /// Whether a load of `url` is one this Source asked to have reported. Uses the image
    /// allow-list's own matcher, so a wildcard means exactly what it means there.
    func covers(_ url: URL) -> Bool {
        guard let origin = HostURLPolicy.canonicalOrigin(for: url) else { return false }
        return origins.contains { ExtensionDomainValidator.originMatches(origin, pattern: $0) }
    }
}
