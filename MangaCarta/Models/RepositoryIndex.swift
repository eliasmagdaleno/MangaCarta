//
//  RepositoryIndex.swift
//  MangaCarta
//
//  Format-1 repository index parsing. This is deliberately a data-only boundary:
//  it parses repository and bundle metadata, but it does not execute an engine or
//  turn a declaration into a SourceDeclaration before the installer has minted the
//  repository-qualified identity.
//

import Foundation

/// Why a repository index cannot be offered to the installer. Paths use the JSON
/// document's dotted key notation, with array positions included, so an installer
/// can show the maintainer exactly which value was refused.
enum RepositoryIndexError: Error, Equatable, Sendable {
    case malformedJSON(String)
    case notAnObject(path: String)
    case missingKey(path: String)
    case unknownKey(path: String, key: String)
    case wrongType(path: String, expected: String)
    case invalidFormat(path: String, value: Int)
    case unsupportedFormat(path: String, value: Int)
    case invalidRepositoryName(reason: TextRejectionReason)
    case invalidBundleID(path: String, value: String)
    case duplicateBundleID(id: String, firstPath: String, secondPath: String)
    case invalidBundleVersion(path: String, value: String)
    case invalidScriptURL(path: String, value: String, reason: String)
    case invalidScriptSHA256(path: String, value: String)
    case emptySources(path: String)
    case duplicateLocalID(localID: String, firstPath: String, secondPath: String)
    case exceedsSizeLimit(path: String, actualBytes: Int, maximumBytes: Int)

    enum TextRejectionReason: Equatable, Sendable {
        case empty
        case tooLong
    }
}

extension RepositoryIndexError {

    /// Diagnostic text suitable for an installer report. The path is present in each
    /// structural error, including errors that occur inside an array element.
    var message: String {
        switch self {
        case .malformedJSON(let reason):
            return "The repository index is not valid JSON: " + reason
        case .notAnObject(let path):
            return "Expected a JSON object at " + describe(path) + "."
        case .missingKey(let path):
            return "Required key '" + path + "' is missing."
        case .unknownKey(let path, let key):
            return "Unknown key '" + key + "' at " + describe(path) + "."
        case .wrongType(let path, let expected):
            return "Key '" + path + "' must be " + article(expected) + " " + expected + "."
        case .invalidFormat(let path, let value):
            return "Key '" + path + "' must be a positive integer; got " + String(value) + "."
        case .unsupportedFormat(let path, let value):
            return "Repository format " + String(value) + " at '" + path + "' is not supported by this app."
        case .invalidRepositoryName(let reason):
            return "name " + describe(reason, limit: 80) + "."
        case .invalidBundleID(let path, let value):
            return "Bundle id '" + value + "' at '" + path + "' must be 1-64 characters of lowercase "
                + "ASCII letters, digits, '-' and '.'."
        case .duplicateBundleID(let id, let firstPath, let secondPath):
            return "Bundle id '" + id + "' occurs at both '" + firstPath + "' and '" + secondPath + "'."
        case .invalidBundleVersion(let path, let value):
            return "Bundle version at '" + path + "' must be a safe positive integer; got " + value + "."
        case .invalidScriptURL(let path, let value, let reason):
            return "Script URL '" + value + "' at '" + path + "' is not allowed: " + reason + "."
        case .invalidScriptSHA256(let path, let value):
            return "scriptSHA256 at '" + path + "' must be exactly 64 lowercase hexadecimal "
                + "characters; got '" + value + "'."
        case .emptySources(let path):
            return "Key '" + path + "' must contain at least one Source declaration."
        case .duplicateLocalID(let localID, let firstPath, let secondPath):
            return "localId '" + localID + "' occurs at both '" + firstPath + "' and '" + secondPath + "'."
        case .exceedsSizeLimit(let path, let actualBytes, let maximumBytes):
            return "Payload at '" + path + "' is " + String(actualBytes) + " bytes; the maximum is "
                + String(maximumBytes) + " bytes."
        }
    }

    private func describe(_ path: String) -> String {
        path.isEmpty ? "the index root" : "'" + path + "'"
    }

    private func describe(_ reason: TextRejectionReason, limit: Int) -> String {
        switch reason {
        case .empty: return "must not be empty after trimming"
        case .tooLong: return "must be at most " + String(limit) + " Unicode scalar values"
        }
    }

    private func article(_ noun: String) -> String {
        "aeiou".contains(noun.lowercased().prefix(1)) ? "an" : "a"
    }
}

/// The raw declaration record embedded in a bundle. `localID` is only an index-level
/// duplicate-detection convenience; all declaration semantics remain owned by
/// `SourceDeclarationValidator`.
struct RepositorySourceRecord: Equatable, Sendable {
    let rawJSON: JSONValue
    let localID: String?

    /// The installer supplies the qualified identity only after it has chosen the
    /// repository identity. This is the sole seam from parsed bytes to a typed
    /// SourceDeclaration in this slice.
    func validate(qualifiedId: QualifiedSourceID,
                  hostAPI: HostAPISupport = .v1) -> Result<SourceDeclaration, SourceDeclarationError> {
        SourceDeclarationValidator.validate(json: rawJSON, qualifiedId: qualifiedId, hostAPI: hostAPI)
    }
}

/// Typed metadata for one executable bundle. The script has already been resolved
/// against the index URL, while declarations remain raw records for later identity-
/// aware validation.
struct RepositoryBundle: Equatable, Sendable {
    let id: String
    let version: Int
    let scriptURL: URL
    let scriptSHA256: String
    let sources: [RepositorySourceRecord]
}

/// The accepted format-1 repository document.
struct RepositoryIndex: Equatable, Sendable {
    let format: Int
    let name: String
    let bundles: [RepositoryBundle]
}

/// Conservative format bounds. They are tunables pending the profiling corpus named by
/// the repository format design's "Bounds" section; script bytes use the same value at
/// fetch time, while index bytes are enforced by this parser before JSON decoding.
enum RepositoryFormatLimits {
    static let maximumIndexBytes = 1 * 1_024 * 1_024
    static let maximumScriptBytes = 10 * 1_024 * 1_024
}

/// Pure parser/validator for repository indexes. It never performs I/O or invokes
/// JavaScriptCore. URL destination checks here cover literal private destinations;
/// DNS and redirect checks remain transport policy at install/fetch time.
enum RepositoryIndexValidator {

    private static let topLevelKeys: Set<String> = ["format", "name", "bundles"]
    private static let bundleKeys: Set<String> = ["id", "version", "script", "scriptSHA256", "sources"]
    private static let idPattern = "^[a-z0-9.-]+$"
    private static let maximumSafeInteger = 9_007_199_254_740_991

    static func validate(json: Data,
                         indexURL: URL) -> Result<RepositoryIndex, RepositoryIndexError> {
        guard json.count <= RepositoryFormatLimits.maximumIndexBytes else {
            return .failure(.exceedsSizeLimit(path: "<document>",
                                              actualBytes: json.count,
                                              maximumBytes: RepositoryFormatLimits.maximumIndexBytes))
        }
        let value: JSONValue
        do {
            value = try JSONValue(parsing: json)
        } catch let failure as JSONValue.ParseFailure {
            return .failure(.malformedJSON(failure.reason))
        } catch {
            return .failure(.malformedJSON(error.localizedDescription))
        }
        return validate(json: value, indexURL: indexURL)
    }

    static func validate(json: JSONValue,
                         indexURL: URL) -> Result<RepositoryIndex, RepositoryIndexError> {
        do {
            return .success(try parse(json: json, indexURL: indexURL))
        } catch let error as RepositoryIndexError {
            return .failure(error)
        } catch {
            return .failure(.malformedJSON(error.localizedDescription))
        }
    }

    private static func parse(json: JSONValue, indexURL: URL) throws -> RepositoryIndex {
        guard let root = json.objectValue else {
            throw RepositoryIndexError.notAnObject(path: "")
        }
        try rejectUnknownKeys(in: root, allowed: topLevelKeys, at: "")

        let format = try positiveInteger(root, key: "format", at: "", kind: .format)
        guard format == 1 else {
            throw RepositoryIndexError.unsupportedFormat(path: "format", value: format)
        }
        let name = try repositoryName(root)
        let bundleValues = try array(root, key: "bundles", at: "")
        var bundleIDs: [String: String] = [:]
        var localIDs: [String: String] = [:]
        var bundles: [RepositoryBundle] = []
        bundles.reserveCapacity(bundleValues.count)

        for (index, value) in bundleValues.enumerated() {
            let path = "bundles.\(index)"
            guard let bundle = value.objectValue else {
                throw RepositoryIndexError.wrongType(path: path, expected: "object")
            }
            let parsed = try parseBundle(bundle, path: path, indexURL: indexURL)
            if let firstPath = bundleIDs[parsed.id] {
                throw RepositoryIndexError.duplicateBundleID(id: parsed.id,
                                                             firstPath: firstPath,
                                                             secondPath: "\(path).id")
            }
            bundleIDs[parsed.id] = "\(path).id"

            for (sourceIndex, source) in parsed.sources.enumerated() {
                guard let localID = source.localID else { continue }
                let sourcePath = "\(path).sources.\(sourceIndex).localId"
                if let firstPath = localIDs[localID] {
                    throw RepositoryIndexError.duplicateLocalID(localID: localID,
                                                                firstPath: firstPath,
                                                                secondPath: sourcePath)
                }
                localIDs[localID] = sourcePath
            }
            bundles.append(parsed)
        }

        return RepositoryIndex(format: format, name: name, bundles: bundles)
    }

    private static func parseBundle(_ root: [String: JSONValue],
                                    path: String,
                                    indexURL: URL) throws -> RepositoryBundle {
        try rejectUnknownKeys(in: root, allowed: bundleKeys, at: path)
        let rawID = try string(root, key: "id", at: path)
        guard rawID.count >= 1, rawID.count <= 64,
              rawID.range(of: idPattern, options: .regularExpression) != nil else {
            throw RepositoryIndexError.invalidBundleID(path: "\(path).id", value: rawID)
        }

        let version = try positiveInteger(root, key: "version", at: path, kind: .bundleVersion)
        let rawScript = try string(root, key: "script", at: path)
        let scriptURL = try resolveScript(rawScript, at: "\(path).script", against: indexURL)
        let digest = try string(root, key: "scriptSHA256", at: path)
        guard digest.unicodeScalars.count == 64,
              digest.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw RepositoryIndexError.invalidScriptSHA256(path: "\(path).scriptSHA256", value: digest)
        }

        let sourceValues = try array(root, key: "sources", at: path)
        guard !sourceValues.isEmpty else {
            throw RepositoryIndexError.emptySources(path: "\(path).sources")
        }
        let sources = try sourceValues.enumerated().map { index, value -> RepositorySourceRecord in
            guard value.objectValue != nil else {
                throw RepositoryIndexError.wrongType(path: "\(path).sources.\(index)", expected: "object")
            }
            return RepositorySourceRecord(rawJSON: value,
                                         localID: value.objectValue?["localId"]?.stringValue)
        }
        return RepositoryBundle(id: rawID, version: version, scriptURL: scriptURL,
                                scriptSHA256: digest, sources: sources)
    }

    private enum IntegerKind { case format, bundleVersion }

    private static func positiveInteger(_ dictionary: [String: JSONValue],
                                        key: String,
                                        at parent: String,
                                        kind: IntegerKind) throws -> Int {
        let path = path(parent, key)
        guard let value = dictionary[key] else {
            throw RepositoryIndexError.missingKey(path: path)
        }
        guard case .int(let integer) = value else {
            throw RepositoryIndexError.wrongType(path: path, expected: "integer")
        }
        guard integer >= 1, integer <= maximumSafeInteger else {
            let error: RepositoryIndexError
            switch kind {
            case .format: error = .invalidFormat(path: path, value: integer)
            case .bundleVersion: error = .invalidBundleVersion(path: path, value: String(integer))
            }
            throw error
        }
        return integer
    }

    private static func repositoryName(_ root: [String: JSONValue]) throws -> String {
        let raw = try string(root, key: "name", at: "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RepositoryIndexError.invalidRepositoryName(reason: .empty)
        }
        guard trimmed.unicodeScalars.count <= 80 else {
            throw RepositoryIndexError.invalidRepositoryName(reason: .tooLong)
        }
        return trimmed
    }

    private static func resolveScript(_ raw: String,
                                      at path: String,
                                      against indexURL: URL) throws -> URL {
        guard let indexComponents = URLComponents(url: indexURL, resolvingAgainstBaseURL: false),
              indexComponents.scheme?.lowercased() == "https",
              indexComponents.user == nil,
              indexComponents.password == nil,
              let url = URL(string: raw, relativeTo: indexURL)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw RepositoryIndexError.invalidScriptURL(path: path, value: raw,
                                                        reason: "only absolute HTTPS URLs are allowed")
        }
        if let reason = literalPrivateDestination(host) {
            throw RepositoryIndexError.invalidScriptURL(path: path, value: raw, reason: reason)
        }
        return url
    }

    private static func literalPrivateDestination(_ host: String) -> String? {
        if host == "localhost" || host.hasSuffix(".localhost") {
            return "loopback destinations are not reachable"
        }
        let ipv4 = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        if host.split(separator: ".", omittingEmptySubsequences: false).count == 4, ipv4.count == 4 {
            if let reason = ipv4DestinationReason(ipv4) { return reason }
        }
        let ipv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ipv6.contains(":") {
            if ipv6 == "::1" || ipv6 == "0:0:0:0:0:0:0:1" {
                return "loopback destinations are not reachable"
            }
            if ipv6.hasPrefix("fc") || ipv6.hasPrefix("fd") {
                return "private destinations are not reachable"
            }
            if ipv6.hasPrefix("fe8") || ipv6.hasPrefix("fe9")
                || ipv6.hasPrefix("fea") || ipv6.hasPrefix("feb") {
                return "link-local destinations are not reachable"
            }
        }
        return nil
    }

    private static func ipv4DestinationReason(_ octets: [UInt8]) -> String? {
        switch (octets[0], octets[1]) {
        case (0, _), (127, _): return "loopback destinations are not reachable"
        case (10, _), (172, 16...31), (192, 168): return "private destinations are not reachable"
        case (169, 254): return "link-local destinations are not reachable"
        case (224...239, _): return "multicast destinations are not reachable"
        default: return nil
        }
    }

    private static func path(_ parent: String, _ key: String) -> String {
        parent.isEmpty ? key : "\(parent).\(key)"
    }

    private static func string(_ dictionary: [String: JSONValue],
                               key: String,
                               at parent: String) throws -> String {
        let path = path(parent, key)
        guard let value = dictionary[key] else {
            throw RepositoryIndexError.missingKey(path: path)
        }
        guard let string = value.stringValue else {
            throw RepositoryIndexError.wrongType(path: path, expected: "string")
        }
        return string
    }

    private static func array(_ dictionary: [String: JSONValue],
                              key: String,
                              at parent: String) throws -> [JSONValue] {
        let path = path(parent, key)
        guard let value = dictionary[key] else {
            throw RepositoryIndexError.missingKey(path: path)
        }
        guard let values = value.arrayValue else {
            throw RepositoryIndexError.wrongType(path: path, expected: "array")
        }
        return values
    }

    private static func rejectUnknownKeys(in dictionary: [String: JSONValue],
                                          allowed: Set<String>,
                                          at path: String) throws {
        if let unknown = dictionary.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw RepositoryIndexError.unknownKey(path: path, key: unknown)
        }
    }
}

/// Naming alias for callers that describe this boundary as a parser rather than a
/// validator. Both names refer to the same pure implementation and API.
typealias RepositoryIndexParser = RepositoryIndexValidator
