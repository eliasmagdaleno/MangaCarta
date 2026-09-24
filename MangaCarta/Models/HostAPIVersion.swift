//
//  HostAPIVersion.swift
//  MangaCarta
//
//  Host API version identity and range intersection, per the design's "Versions and
//  feature negotiation" section: a declaration carries a half-open range and the host
//  "selects the highest installed version in the intersection". No intersection means
//  the Source is not registered (acceptance criterion 9).
//
//  CONTRACT GAP, decided here: the design shows `"1.0"` and `"2.0"` but never states a
//  grammar for the strings, whether patch components are legal, or how comparison works.
//  This implementation takes the strict reading — exactly MAJOR "." MINOR, decimal, no
//  leading zeros — because the section only ever assigns meaning to two components
//  ("Major versions may remove or change behavior; minor versions are additive").
//  Accepting a third component would mean inventing comparison semantics the contract
//  does not have. Anything outside the grammar is refused rather than guessed at.
//

import Foundation

/// A Host API version. Two components only; see the grammar note above.
struct HostAPIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses the wire form. Returns `nil` for anything outside `MAJOR "." MINOR`.
    init?(parsing string: String) {
        let components = string.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let major = HostAPIVersion.component(components[0]),
              let minor = HostAPIVersion.component(components[1]) else {
            return nil
        }
        self.init(major: major, minor: minor)
    }

    /// One version component: ASCII digits only (so Arabic-Indic digits and `+`/`-` signs
    /// are refused), nonempty, and no leading zero unless the component is exactly `0`.
    private static func component(_ text: Substring) -> Int? {
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        if text.count > 1 && text.hasPrefix("0") { return nil }
        return Int(text)
    }

    var description: String { "\(major).\(minor)" }

    static func < (lhs: HostAPIVersion, rhs: HostAPIVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

/// A declared `{minimum, maximumExclusive}` range. Half-open, and never empty: an empty
/// or inverted range can intersect nothing, so it is refused at construction rather than
/// producing a misleading "no compatible version" report later.
struct HostAPIVersionRange: Equatable, Sendable, CustomStringConvertible {
    let minimum: HostAPIVersion
    let maximumExclusive: HostAPIVersion

    init?(minimum: HostAPIVersion, maximumExclusive: HostAPIVersion) {
        guard minimum < maximumExclusive else { return nil }
        self.minimum = minimum
        self.maximumExclusive = maximumExclusive
    }

    func contains(_ version: HostAPIVersion) -> Bool {
        version >= minimum && version < maximumExclusive
    }

    var description: String { "\(minimum) up to (but not including) \(maximumExclusive)" }
}

/// The Host API versions this build of the app actually implements.
struct HostAPISupport: Equatable, Sendable {
    let installedVersions: [HostAPIVersion]

    init(installedVersions: [HostAPIVersion]) {
        self.installedVersions = installedVersions.sorted()
    }

    /// Host API v1, including additive minor versions 1 and 2.
    static let v1 = HostAPISupport(installedVersions: [HostAPIVersion(major: 1, minor: 0),
                                                       HostAPIVersion(major: 1, minor: 1),
                                                       HostAPIVersion(major: 1, minor: 2)])

    /// "The host selects the highest installed version in the intersection." A declared
    /// minimum above every installed minor therefore has no intersection at all — 1.7 is
    /// not satisfied by an installed 1.0.
    func highestVersion(in range: HostAPIVersionRange) -> HostAPIVersion? {
        installedVersions.filter(range.contains).max()
    }
}
