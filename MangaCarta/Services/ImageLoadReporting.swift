//
//  ImageLoadReporting.swift
//  MangaCarta
//
//  The seam between the image loader and whatever sends image-load reports
//  (ADR-0003 Amendment 9). `ImageCache` measures and decides what to report; a
//  reporter only sends. Production's sender is `ImageLoadReporter`.
//

import Foundation

/// One network retrieval, in the fixed payload's terms: `url`, `success`, `cached`,
/// `bytes`, `duration` (milliseconds).
struct ImageLoadReport: Sendable, Equatable {
    let url: URL
    /// The retrieval succeeded. A download that then fails to decode is still a success.
    let success: Bool
    /// The response's `X-Cache` started with `HIT`.
    let cached: Bool
    let bytes: Int
    let durationMilliseconds: Int
}

protocol ImageLoadReporting: Sendable {
    /// Must return at once: the image load never waits on a report.
    func report(_ report: ImageLoadReport, to target: ImageLoadReportTarget)
}

/// The default: no reports. Nothing is sent until a real reporter is injected.
struct NoImageLoadReports: ImageLoadReporting {
    func report(_ report: ImageLoadReport, to target: ImageLoadReportTarget) {}
}
