//
//  SourceDeclarationValidator.swift
//  MangaCarta
//
//  Validates a Source declaration before any Extension code is allowed to exist. The
//  Host API design's "Source declaration", "Entry points", "Versions and feature
//  negotiation", "Language contract", "URL policy", "Adult classification" and
//  "Source-authored presentation" sections own every rule applied here.
//
//  Two rules carry most of the weight and are easy to get backwards:
//
//  * unknown keys are ignored ONLY inside `configuration`, which is the engine's private
//    vocabulary. Everywhere else an unknown key fails installation, so that a misspelled
//    key cannot silently disable a policy the host thinks it is enforcing; and
//  * `adult` is fail-closed. Absent or unrecognized is a rejection, never `none`.
//
//  This file executes nothing. It does not link, import, or name a JavaScript evaluator,
//  and `ManifestValidationCodeFreeTests` is the structural guard that keeps it that way —
//  acceptance criterion 2 ("manifest validation and Source registration execute no
//  Extension code"). Keep the imports at Foundation alone.
//

import Foundation

/// Why a Source declaration was refused. Every case prevents registration: a declaration
/// is all-or-nothing, so unlike an operation *result* there is no partial success and no
/// warning channel here ("Unknown keys in the Host API-owned declaration fail
/// installation").
///
/// This is deliberately not an `ExtensionSchemaError`. That type describes an Extension's
/// *output* violating a wire schema at run time and is fixed to the `invalid_response`
/// code; a declaration is bytes read before any Extension exists, and calling its
/// rejection an invalid response would be wrong in both word and code. The one place the
/// two domains genuinely meet — the stable error-code list — is reused rather than
/// restated: see `hostAPICode`.
enum SourceDeclarationError: Error, Equatable, Sendable {
    case malformedJSON(String)
    case notAnObject(path: String)
    case missingKey(path: String)
    case unknownKey(path: String, key: String)
    case wrongType(path: String, expected: String)
    case invalidLocalID(String)
    case invalidName(reason: TextRejectionReason)
    case invalidEngine(String)
    case invalidAdultClassification(String)
    case unknownExternalIDNamespace(String)
    case duplicateExternalIDNamespace(String)
    case missingRequiredCapabilities([String])
    case noDiscoveryCapability
    case invalidLanguageMode(String)
    case invalidLanguageTag(String)
    case emptyLanguageValues
    case duplicateLanguageTag(String)
    case invalidOrigin(path: String, value: String, reason: String)
    case duplicateOrigin(path: String, value: String)
    case unknownFeedKey(String)
    case presentationForUndeclaredCapability(SourceOperation)
    case invalidPresentationText(path: String, reason: TextRejectionReason)
    case invalidBadge(String)
    case invalidHostAPIVersion(path: String, value: String)
    case emptyHostAPIRange(minimum: String, maximumExclusive: String)
    case incompatibleHostAPI(declared: HostAPIVersionRange, hostSupported: [HostAPIVersion])
    case localIDChanged(from: String, to: String)
    case qualifiedIdentityChanged

    enum TextRejectionReason: Equatable, Sendable {
        case empty
        case tooLong
    }
}

extension SourceDeclarationError {

    /// The stable Host API error code, where one applies.
    ///
    /// The design's error table is the taxonomy for *invocation* outcomes, and exactly
    /// one of its codes describes a registration refusal: `incompatible_version`, "no
    /// Host API range intersection". The remaining rejections happen before there is an
    /// invocation to name, so they carry no code rather than being forced into one that
    /// would mislead a reader about what failed.
    var hostAPICode: ExtensionHostErrorCode? {
        if case .incompatibleHostAPI = self { return .incompatibleVersion }
        return nil
    }

    /// Diagnostic, author- and maintainer-facing text. The host still owns user-facing
    /// copy; this is what goes in a log or an installer report.
    var message: String {
        switch self {
        case .malformedJSON(let reason):
            return "The Source declaration is not valid JSON: \(reason)"
        case .notAnObject(let path):
            return "Expected a JSON object at \(Self.describe(path))."
        case .missingKey(let path):
            return "Required key '\(path)' is missing."
        case .unknownKey(let path, let key):
            return "Unknown key '\(key)' at \(Self.describe(path)). Only 'configuration' "
                + "may carry keys the host does not define."
        case .wrongType(let path, let expected):
            return "Key '\(path)' must be \(Self.article(expected)) \(expected)."
        case .invalidLocalID(let value):
            return "localId '\(value)' must be 1-64 characters of lowercase ASCII letters, "
                + "digits, '-' and '.'."
        case .invalidName(let reason):
            return "name \(Self.describe(reason, limit: SourceDeclarationLimits.nameScalars))."
        case .invalidEngine(let value):
            return "engine '\(value)' must be nonempty and at most "
                + "\(SourceDeclarationLimits.engineScalars) characters."
        case .invalidAdultClassification(let value):
            return "adult classification '\(value)' is not one of none, mixed, adultOnly. "
                + "The classification is required and is never assumed."
        case .unknownExternalIDNamespace(let value):
            return "externalIds namespace '\(value)' is not supported."
        case .duplicateExternalIDNamespace(let value):
            return "externalIds namespace '\(value)' is listed more than once."
        case .missingRequiredCapabilities(let names):
            return "A browsable and readable Source must declare "
                + "\(SourceOperation.requiredForReading.map(\.rawValue).joined(separator: ", "))"
                + "; missing: \(names.joined(separator: ", "))."
        case .noDiscoveryCapability:
            return "A Source must declare at least one of "
                + "\(SourceOperation.discoveryFeeds.map(\.rawValue).joined(separator: ", "))"
                + " for Home discovery."
        case .invalidLanguageMode(let value):
            return "languages.mode '\(value)' is not one of fixed, selectable, mixed."
        case .invalidLanguageTag(let value):
            return "'\(value)' is not a well-formed BCP 47 language tag."
        case .emptyLanguageValues:
            return "languages.values must list at least one language; the host never "
                + "passes a language outside the declaration."
        case .duplicateLanguageTag(let value):
            return "Language '\(value)' is listed more than once."
        case .invalidOrigin(let path, let value, let reason):
            return "\(path) entry '\(value)' is not a usable origin: \(reason)."
        case .duplicateOrigin(let path, let value):
            return "\(path) lists origin '\(value)' more than once."
        case .unknownFeedKey(let key):
            return "'\(key)' is not a feed. Presentation is keyed by "
                + "\(SourceOperation.discoveryFeeds.map(\.rawValue).joined(separator: ", "))."
        case .presentationForUndeclaredCapability(let operation):
            return "presentation declares a '\(operation.rawValue)' feed, but the Source "
                + "does not declare the '\(operation.rawValue)' capability."
        case .invalidPresentationText(let path, let reason):
            return "\(path) \(Self.describe(reason, limit: SourceDeclarationLimits.presentationTextScalars))."
        case .invalidBadge(let value):
            return "Feed badge '\(value)' is not one of none, new."
        case .invalidHostAPIVersion(let path, let value):
            return "\(path) '\(value)' is not a Host API version. Versions are exactly "
                + "MAJOR.MINOR, for example 1.0."
        case .emptyHostAPIRange(let minimum, let maximumExclusive):
            return "hostAPI range \(minimum) up to (but not including) \(maximumExclusive) "
                + "is empty; minimum must be below maximumExclusive."
        case .incompatibleHostAPI(let declared, let supported):
            return "This Source requires Host API \(declared), but this app provides "
                + "\(supported.map(\.description).joined(separator: ", ")). "
                + "Update the app, or install a Source build that supports "
                + "\(supported.map(\.description).joined(separator: " or "))."
        case .localIDChanged(let from, let to):
            return "An update may not change localId ('\(from)' to '\(to)'); a rename "
                + "requires an explicit migration format, which Host API v1 refuses."
        case .qualifiedIdentityChanged:
            return "An update may not change a Source's repository-qualified identity."
        }
    }

    private static func describe(_ path: String) -> String {
        path.isEmpty ? "the declaration root" : "'\(path)'"
    }

    private static func describe(_ reason: TextRejectionReason, limit: Int) -> String {
        switch reason {
        case .empty: return "must not be empty after trimming"
        case .tooLong: return "must be at most \(limit) Unicode scalar values"
        }
    }

    private static func article(_ noun: String) -> String {
        "aeiou".contains(noun.lowercased().prefix(1)) ? "an" : "a"
    }
}

/// Validates Source declarations. Pure, synchronous, and free of any capability to run
/// Extension code.
enum SourceDeclarationValidator {

    private static let topLevelKeys: Set<String> = [
        "localId", "name", "engine", "configuration", "adult",
        "capabilities", "languages", "network", "presentation", "hostAPI", "externalIds"
    ]

    /// Validates the declaration in `json`.
    ///
    /// - Parameter qualifiedId: the repository-qualified Source id, already minted by the
    ///   installer. Validation never derives identity from the declaration's own content.
    static func validate(json: Data,
                         qualifiedId: QualifiedSourceID,
                         hostAPI: HostAPISupport = .v1) -> Result<SourceDeclaration, SourceDeclarationError> {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: json)
        } catch let failure as JSONValue.ParseFailure {
            return .failure(.malformedJSON(failure.reason))
        } catch {
            return .failure(.malformedJSON(error.localizedDescription))
        }
        return validate(json: value, qualifiedId: qualifiedId, hostAPI: hostAPI)
    }

    static func validate(json: JSONValue,
                         qualifiedId: QualifiedSourceID,
                         hostAPI: HostAPISupport = .v1) -> Result<SourceDeclaration, SourceDeclarationError> {
        do {
            return .success(try declaration(from: json, qualifiedId: qualifiedId, hostAPI: hostAPI))
        } catch let error as SourceDeclarationError {
            return .failure(error)
        } catch {
            return .failure(.malformedJSON(error.localizedDescription))
        }
    }

    /// The design's "Identity lifecycle": an update may change name, engine,
    /// configuration and capabilities, but not repository identity or `localId`.
    /// Returns `nil` when the update is allowed.
    static func validateUpdate(from previous: SourceDeclaration,
                               to next: SourceDeclaration) -> SourceDeclarationError? {
        guard previous.qualifiedId == next.qualifiedId else { return .qualifiedIdentityChanged }
        guard previous.localId == next.localId else {
            return .localIDChanged(from: previous.localId, to: next.localId)
        }
        return nil
    }

    // MARK: - Record

    private static func declaration(from json: JSONValue,
                                    qualifiedId: QualifiedSourceID,
                                    hostAPI: HostAPISupport) throws -> SourceDeclaration {
        guard let root = json.objectValue else { throw SourceDeclarationError.notAnObject(path: "") }
        try rejectUnknownKeys(in: root, allowed: topLevelKeys, at: "")

        // Fields are checked in declaration order, then the two invariants that need the
        // whole record: the registration rules, and the version intersection.
        let identifier = try localID(from: root)
        let displayName = try name(from: root)
        let engineName = try engine(from: root)
        let engineConfiguration = try configuration(from: root)
        let classification = try adult(from: root)
        let externalIds = try externalIDs(from: root)
        let declared = try capabilities(from: root)
        let languagePolicy = try languages(from: root)
        let networkPolicy = try network(from: root)
        let presentationRecord = try presentation(from: root, capabilities: declared)
        let range = try hostAPIRange(from: root)

        try checkRegistrationInvariants(declared)
        guard let selected = hostAPI.highestVersion(in: range) else {
            throw SourceDeclarationError.incompatibleHostAPI(declared: range,
                                                             hostSupported: hostAPI.installedVersions)
        }

        return SourceDeclaration(qualifiedId: qualifiedId,
                                 localId: identifier,
                                 name: displayName,
                                 engine: engineName,
                                 configuration: engineConfiguration,
                                 adult: classification,
                                 externalIds: externalIds,
                                 capabilities: declared,
                                 languages: languagePolicy,
                                 network: networkPolicy,
                                 presentation: presentationRecord,
                                 hostAPI: range,
                                 selectedHostAPIVersion: selected)
    }

    // MARK: - Identity and display

    private static func localID(from root: [String: JSONValue]) throws -> String {
        let raw = try string(root, "localId", at: "")
        let scalars = raw.unicodeScalars
        let allowed = scalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122)     // a-z
                || (scalar.value >= 48 && scalar.value <= 57)  // 0-9
                || scalar == "-" || scalar == "."
        }
        guard allowed, SourceDeclarationLimits.localIDLength.contains(scalars.count) else {
            throw SourceDeclarationError.invalidLocalID(raw)
        }
        return raw
    }

    private static func name(from root: [String: JSONValue]) throws -> String {
        let raw = try string(root, "name", at: "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceDeclarationError.invalidName(reason: .empty) }
        guard trimmed.unicodeScalars.count <= SourceDeclarationLimits.nameScalars else {
            throw SourceDeclarationError.invalidName(reason: .tooLong)
        }
        return trimmed
    }

    private static func engine(from root: [String: JSONValue]) throws -> String {
        let raw = try string(root, "engine", at: "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.count <= SourceDeclarationLimits.engineScalars else {
            throw SourceDeclarationError.invalidEngine(raw)
        }
        return trimmed
    }

    /// The engine's private vocabulary. This is the one place unknown keys survive, and
    /// they survive verbatim: nothing here inspects, rewrites, or evaluates the value.
    /// An absent `configuration` means the engine needs none — the only safe reading,
    /// since an empty object cannot disable any host policy.
    private static func configuration(from root: [String: JSONValue]) throws -> JSONValue {
        guard let value = root["configuration"] else { return .object([:]) }
        guard value.objectValue != nil else {
            throw SourceDeclarationError.wrongType(path: "configuration", expected: "object")
        }
        return value
    }

    private static func adult(from root: [String: JSONValue]) throws -> AdultClassification {
        let raw = try string(root, "adult", at: "")
        guard let classification = AdultClassification(rawValue: raw) else {
            throw SourceDeclarationError.invalidAdultClassification(raw)
        }
        return classification
    }

    private static func externalIDs(from root: [String: JSONValue]) throws -> [String] {
        guard let value = root["externalIds"] else { return [] }
        guard let items = value.arrayValue else {
            throw SourceDeclarationError.wrongType(path: "externalIds", expected: "array")
        }
        var namespaces: [String] = []
        for item in items {
            guard let namespace = item.stringValue else {
                throw SourceDeclarationError.wrongType(path: "externalIds", expected: "string")
            }
            guard namespace == "mal" else {
                throw SourceDeclarationError.unknownExternalIDNamespace(namespace)
            }
            guard !namespaces.contains(namespace) else {
                throw SourceDeclarationError.duplicateExternalIDNamespace(namespace)
            }
            namespaces.append(namespace)
        }
        return namespaces
    }

    // MARK: - Capabilities

    private static func capabilities(from root: [String: JSONValue]) throws -> SourceCapabilities {
        let dictionary = try object(root, "capabilities", at: "")
        try rejectUnknownKeys(in: dictionary,
                              allowed: Set(SourceOperation.allCases.map(\.rawValue)),
                              at: "capabilities")

        var enabled: Set<SourceOperation> = []
        for operation in SourceOperation.allCases {
            guard let value = dictionary[operation.rawValue] else { continue }
            guard case .bool(let flag) = value else {
                throw SourceDeclarationError.wrongType(path: "capabilities.\(operation.rawValue)",
                                                       expected: "boolean")
            }
            if flag { enabled.insert(operation) }
        }
        return SourceCapabilities(enabled: enabled)
    }

    /// The design's registration invariants. A declaration failing either is not
    /// registered at all — the host will not schedule or present a half-usable Source.
    private static func checkRegistrationInvariants(_ capabilities: SourceCapabilities) throws {
        let missing = capabilities.missingReadingCapabilities
        guard missing.isEmpty else {
            throw SourceDeclarationError.missingRequiredCapabilities(missing.map(\.rawValue))
        }
        guard capabilities.hasDiscoveryFeed else { throw SourceDeclarationError.noDiscoveryCapability }
    }

    // MARK: - Languages

    private static func languages(from root: [String: JSONValue]) throws -> LanguagePolicy {
        let dictionary = try object(root, "languages", at: "")
        try rejectUnknownKeys(in: dictionary, allowed: ["mode", "values"], at: "languages")

        let modeRaw = try string(dictionary, "mode", at: "languages")
        guard let mode = LanguageMode(rawValue: modeRaw) else {
            throw SourceDeclarationError.invalidLanguageMode(modeRaw)
        }

        let items = try array(dictionary, "values", at: "languages")
        guard !items.isEmpty else { throw SourceDeclarationError.emptyLanguageValues }

        var tags: [String] = []
        for item in items {
            guard let raw = item.stringValue else {
                throw SourceDeclarationError.wrongType(path: "languages.values", expected: "string")
            }
            guard let canonical = BCP47.canonicalized(raw) else {
                throw SourceDeclarationError.invalidLanguageTag(raw)
            }
            guard !tags.contains(canonical) else {
                throw SourceDeclarationError.duplicateLanguageTag(canonical)
            }
            tags.append(canonical)
        }
        return LanguagePolicy(mode: mode, tags: tags)
    }

    // MARK: - Network

    private static func network(from root: [String: JSONValue]) throws -> NetworkPolicy {
        let dictionary = try object(root, "network", at: "")
        try rejectUnknownKeys(in: dictionary,
                              allowed: ["httpOrigins", "browserOrigins", "assetOrigins"],
                              at: "network")
        return NetworkPolicy(httpOrigins: try origins(dictionary, "httpOrigins"),
                             browserOrigins: try origins(dictionary, "browserOrigins"),
                             assetOrigins: try origins(dictionary, "assetOrigins"))
    }

    /// An omitted list denies that role. Silence is never permission here: a Source that
    /// never declared a browser origin cannot reach one.
    private static func origins(_ dictionary: [String: JSONValue], _ key: String) throws -> [String] {
        guard let value = dictionary[key] else { return [] }
        let path = "network.\(key)"
        guard let items = value.arrayValue else {
            throw SourceDeclarationError.wrongType(path: path, expected: "array")
        }

        var canonical: [String] = []
        for item in items {
            guard let raw = item.stringValue else {
                throw SourceDeclarationError.wrongType(path: path, expected: "string")
            }
            switch DeclaredOrigin.canonicalized(raw) {
            case .rejected(let reason):
                throw SourceDeclarationError.invalidOrigin(path: path, value: raw, reason: reason)
            case .canonical(let origin):
                guard !canonical.contains(origin) else {
                    throw SourceDeclarationError.duplicateOrigin(path: path, value: origin)
                }
                canonical.append(origin)
            }
        }
        return canonical
    }

    // MARK: - Presentation

    private static func presentation(from root: [String: JSONValue],
                                     capabilities: SourceCapabilities) throws -> SourcePresentation {
        guard let value = root["presentation"] else { return .empty }
        guard let dictionary = value.objectValue else {
            throw SourceDeclarationError.wrongType(path: "presentation", expected: "object")
        }
        try rejectUnknownKeys(in: dictionary,
                              allowed: ["feeds", "imagePrefetchConcurrency"],
                              at: "presentation")

        return SourcePresentation(feeds: try feeds(dictionary, capabilities: capabilities),
                                  imagePrefetchConcurrencyHint: try prefetchHint(dictionary))
    }

    private static func feeds(_ dictionary: [String: JSONValue],
                              capabilities: SourceCapabilities) throws -> [SourceOperation: FeedPresentation] {
        guard let value = dictionary["feeds"] else { return [:] }
        guard let records = value.objectValue else {
            throw SourceDeclarationError.wrongType(path: "presentation.feeds", expected: "object")
        }

        var feeds: [SourceOperation: FeedPresentation] = [:]
        for key in records.keys.sorted() {
            guard let operation = SourceOperation(rawValue: key),
                  SourceOperation.discoveryFeeds.contains(operation) else {
                throw SourceDeclarationError.unknownFeedKey(key)
            }
            guard capabilities.supports(operation) else {
                throw SourceDeclarationError.presentationForUndeclaredCapability(operation)
            }
            guard let record = records[key] else { continue }
            feeds[operation] = try feed(record, at: "presentation.feeds.\(key)")
        }
        return feeds
    }

    private static func feed(_ value: JSONValue, at path: String) throws -> FeedPresentation {
        guard let dictionary = value.objectValue else {
            throw SourceDeclarationError.wrongType(path: path, expected: "object")
        }
        try rejectUnknownKeys(in: dictionary, allowed: ["title", "eyebrow", "badge"], at: path)

        var badge = FeedBadge.none
        if let raw = dictionary["badge"] {
            guard let text = raw.stringValue else {
                throw SourceDeclarationError.wrongType(path: "\(path).badge", expected: "string")
            }
            guard let parsed = FeedBadge(rawValue: text) else {
                throw SourceDeclarationError.invalidBadge(text)
            }
            badge = parsed
        }

        return FeedPresentation(title: try boundedText(dictionary, "title", at: path),
                                eyebrow: try boundedText(dictionary, "eyebrow", at: path),
                                badge: badge)
    }

    private static func boundedText(_ dictionary: [String: JSONValue],
                                    _ key: String,
                                    at parent: String) throws -> String? {
        guard let value = dictionary[key] else { return nil }
        let path = "\(parent).\(key)"
        guard let raw = value.stringValue else {
            throw SourceDeclarationError.wrongType(path: path, expected: "string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceDeclarationError.invalidPresentationText(path: path, reason: .empty)
        }
        guard trimmed.unicodeScalars.count <= SourceDeclarationLimits.presentationTextScalars else {
            throw SourceDeclarationError.invalidPresentationText(path: path, reason: .tooLong)
        }
        return trimmed
    }

    /// A hint, so an out-of-range value is clamped rather than refused. Only a value that
    /// is not an integer at all is a contract error — that is a type mismatch, not an
    /// ambitious request.
    private static func prefetchHint(_ dictionary: [String: JSONValue]) throws -> Int? {
        guard let value = dictionary["imagePrefetchConcurrency"] else { return nil }
        guard case .int(let requested) = value else {
            throw SourceDeclarationError.wrongType(path: "presentation.imagePrefetchConcurrency",
                                                   expected: "integer")
        }
        let range = SourceDeclarationLimits.imagePrefetchConcurrency
        return min(max(requested, range.lowerBound), range.upperBound)
    }

    // MARK: - Host API range

    private static func hostAPIRange(from root: [String: JSONValue]) throws -> HostAPIVersionRange {
        let dictionary = try object(root, "hostAPI", at: "")
        try rejectUnknownKeys(in: dictionary, allowed: ["minimum", "maximumExclusive"], at: "hostAPI")

        let minimum = try version(dictionary, "minimum")
        let maximumExclusive = try version(dictionary, "maximumExclusive")
        guard let range = HostAPIVersionRange(minimum: minimum, maximumExclusive: maximumExclusive) else {
            throw SourceDeclarationError.emptyHostAPIRange(minimum: minimum.description,
                                                           maximumExclusive: maximumExclusive.description)
        }
        return range
    }

    private static func version(_ dictionary: [String: JSONValue], _ key: String) throws -> HostAPIVersion {
        let raw = try string(dictionary, key, at: "hostAPI")
        guard let parsed = HostAPIVersion(parsing: raw) else {
            throw SourceDeclarationError.invalidHostAPIVersion(path: "hostAPI.\(key)", value: raw)
        }
        return parsed
    }

    // MARK: - Typed access

    private static func path(_ parent: String, _ key: String) -> String {
        parent.isEmpty ? key : "\(parent).\(key)"
    }

    private static func value(_ dictionary: [String: JSONValue],
                              _ key: String,
                              at parent: String) throws -> JSONValue {
        guard let value = dictionary[key] else {
            throw SourceDeclarationError.missingKey(path: path(parent, key))
        }
        return value
    }

    private static func string(_ dictionary: [String: JSONValue],
                               _ key: String,
                               at parent: String) throws -> String {
        guard let text = try value(dictionary, key, at: parent).stringValue else {
            throw SourceDeclarationError.wrongType(path: path(parent, key), expected: "string")
        }
        return text
    }

    private static func object(_ dictionary: [String: JSONValue],
                               _ key: String,
                               at parent: String) throws -> [String: JSONValue] {
        guard let nested = try value(dictionary, key, at: parent).objectValue else {
            throw SourceDeclarationError.wrongType(path: path(parent, key), expected: "object")
        }
        return nested
    }

    private static func array(_ dictionary: [String: JSONValue],
                              _ key: String,
                              at parent: String) throws -> [JSONValue] {
        guard let items = try value(dictionary, key, at: parent).arrayValue else {
            throw SourceDeclarationError.wrongType(path: path(parent, key), expected: "array")
        }
        return items
    }

    /// The asymmetry, in one place: everywhere this is called, an unrecognized key is
    /// fatal to the install. It is never called for `configuration`.
    private static func rejectUnknownKeys(in dictionary: [String: JSONValue],
                                          allowed: Set<String>,
                                          at path: String) throws {
        let unknown = dictionary.keys.filter { !allowed.contains($0) }.sorted()
        if let first = unknown.first {
            throw SourceDeclarationError.unknownKey(path: path, key: first)
        }
    }
}

/// A declared HTTPS origin.
///
/// The design's "URL policy" section allows only absolute HTTPS URLs and rejects
/// loopback, link-local, multicast and private destinations. Those destination checks
/// happen after DNS at request time, but a literal address in a declaration needs no DNS
/// to be caught, so it is caught here — the earliest point at which it is knowable.
///
/// The canonical form produced here (`https://host` with a non-default port appended)
/// matches the origin form `ExtensionDomainSchemas` compares asset URLs against, so a
/// declared origin and a validated cover URL agree on what "same origin" means.
enum DeclaredOrigin {

    enum Outcome: Equatable {
        case canonical(String)
        case rejected(String)
    }

    static func canonicalized(_ raw: String) -> Outcome {
        guard let components = URLComponents(string: raw) else {
            return .rejected("it is not a parsable URL")
        }
        guard let scheme = components.scheme, scheme.lowercased() == "https" else {
            return .rejected("only absolute https origins are allowed")
        }
        guard components.user == nil, components.password == nil else {
            return .rejected("an origin may not carry credentials")
        }
        guard components.query == nil, components.fragment == nil else {
            return .rejected("an origin may not carry a query or fragment")
        }
        guard components.path.isEmpty || components.path == "/" else {
            return .rejected("an origin may not carry a path")
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            return .rejected("it has no host")
        }
        if let reason = unreachableHostReason(host) {
            return .rejected(reason)
        }

        if let port = components.port, port != 443 {
            return .canonical("https://\(host):\(port)")
        }
        return .canonical("https://\(host)")
    }

    /// Literal destinations the URL policy refuses outright.
    private static func unreachableHostReason(_ host: String) -> String? {
        if host == "localhost" || host.hasSuffix(".localhost") {
            return "loopback destinations are not reachable by a Source"
        }
        if let reason = ipv6Reason(host) { return reason }
        return ipv4Reason(host)
    }

    private static func ipv6Reason(_ literal: String) -> String? {
        // Foundation has changed its mind about whether `URLComponents.host` keeps the
        // brackets around an IPv6 literal, so tolerate both spellings.
        let host = literal.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host.contains(":") else { return nil }

        let groups = host.split(separator: ":", omittingEmptySubsequences: true)
        if groups.count <= 1, groups.first.map({ UInt16($0, radix: 16) == 1 }) ?? false {
            return "loopback destinations are not reachable by a Source"
        }
        if groups.allSatisfy({ UInt16($0, radix: 16) != nil }),
           groups.dropLast().allSatisfy({ UInt16($0, radix: 16) == 0 }),
           groups.last.map({ UInt16($0, radix: 16) == 1 }) ?? false {
            return "loopback destinations are not reachable by a Source"
        }
        if host.hasPrefix("fc") || host.hasPrefix("fd") {
            return "unique-local destinations are not reachable by a Source"
        }
        if host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb") {
            return "link-local destinations are not reachable by a Source"
        }
        return nil
    }

    private static func ipv4Reason(_ host: String) -> String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }

        switch (octets[0], octets[1]) {
        case (0, _):
            return "the unspecified address is not reachable by a Source"
        case (127, _):
            return "loopback destinations are not reachable by a Source"
        case (10, _), (192, 168):
            return "private destinations are not reachable by a Source"
        case (172, 16...31):
            return "private destinations are not reachable by a Source"
        case (169, 254):
            return "link-local destinations are not reachable by a Source"
        case (224...239, _):
            return "multicast destinations are not reachable by a Source"
        case (255, 255):
            return "the broadcast address is not reachable by a Source"
        default:
            return nil
        }
    }
}

/// Well-formedness for the BCP 47 subset Host API v1 accepts.
///
/// The design says tags are "canonicalized BCP 47 strings" without naming a subset. This
/// implementation accepts `language[-Script][-REGION][-variant...]` and canonicalizes
/// case, which is not a substitution — `EN-us` and `en-US` are the same tag written two
/// ways. It refuses extension and private-use singletons (`x-`, `u-`, `t-`), because
/// Host API v1 assigns them no meaning, and restricts the primary subtag to the 2-3
/// alpha ISO forms, so that an unregistered word like `english` is refused rather than
/// mistaken for a registered 5-8 alpha language subtag.
enum BCP47 {

    static func canonicalized(_ raw: String) -> String? {
        let subtags = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = subtags.first,
              isAlpha(primary), (2...3).contains(primary.count) else {
            return nil
        }

        var canonical = [primary.lowercased()]
        var index = 1

        if index < subtags.count, isAlpha(subtags[index]), subtags[index].count == 4 {
            canonical.append(subtags[index].prefix(1).uppercased() + subtags[index].dropFirst().lowercased())
            index += 1
        }
        if index < subtags.count, isRegion(subtags[index]) {
            canonical.append(subtags[index].uppercased())
            index += 1
        }
        while index < subtags.count {
            guard isVariant(subtags[index]) else { return nil }
            canonical.append(subtags[index].lowercased())
            index += 1
        }
        return canonical.joined(separator: "-")
    }

    private static func isAlpha(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isRegion(_ text: Substring) -> Bool {
        (isAlpha(text) && text.count == 2) || (isDigits(text) && text.count == 3)
    }

    private static func isVariant(_ text: Substring) -> Bool {
        let alphanumeric = !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard alphanumeric else { return false }
        if (5...8).contains(text.count) { return true }
        return text.count == 4 && (text.first?.isNumber ?? false)
    }
}

// MARK: - The validated record

/// A Source declaration that has passed every rule in the Host API design and may be
/// registered.
///
/// An instance of this type is a Source the host has already agreed to register: its
/// capabilities satisfy the registration invariants, its origins are canonical HTTPS,
/// its adult class is stated, and its declared Host API range intersects this build's.
/// Nothing here is optional-because-we-were-unsure; everything absent has a stated
/// fail-closed meaning at the validator.
///
/// **There is no way to obtain one except from `SourceDeclarationValidator`.** The
/// initialiser is `fileprivate`, which is why the record is declared in this file rather
/// than beside its parts in `SourceDeclaration.swift`: ADR-0003 Amendment 4 (decision 4,
/// closing #161) turns "must already have passed validation" from a doc comment on
/// `SourceLifecycleRegistry.reinstall` into a fact the compiler enforces. A stored
/// declaration is therefore raw JSON, re-validated at every launch; a test that needs a
/// typed value goes through the validator from a JSON fixture.
struct SourceDeclaration: Equatable, Sendable {
    /// Supplied by the installer, never derived from anything in the declaration.
    let qualifiedId: QualifiedSourceID
    /// Immutable across updates. Identity, unlike `name`.
    let localId: String
    /// Display text. Not identity: nothing may key off it.
    let name: String
    let engine: String
    /// The engine's private vocabulary, carried verbatim. Unknown keys survive *here*
    /// and nowhere else in the record.
    let configuration: JSONValue
    let adult: AdultClassification
    let externalIds: [String]
    let capabilities: SourceCapabilities
    let languages: LanguagePolicy
    let network: NetworkPolicy
    let presentation: SourcePresentation
    let hostAPI: HostAPIVersionRange
    /// The highest version this build implements that lies inside `hostAPI`.
    let selectedHostAPIVersion: HostAPIVersion

    fileprivate init(qualifiedId: QualifiedSourceID,
                     localId: String,
                     name: String,
                     engine: String,
                     configuration: JSONValue,
                     adult: AdultClassification,
                     externalIds: [String],
                     capabilities: SourceCapabilities,
                     languages: LanguagePolicy,
                     network: NetworkPolicy,
                     presentation: SourcePresentation,
                     hostAPI: HostAPIVersionRange,
                     selectedHostAPIVersion: HostAPIVersion) {
        self.qualifiedId = qualifiedId
        self.localId = localId
        self.name = name
        self.engine = engine
        self.configuration = configuration
        self.adult = adult
        self.externalIds = externalIds
        self.capabilities = capabilities
        self.languages = languages
        self.network = network
        self.presentation = presentation
        self.hostAPI = hostAPI
        self.selectedHostAPIVersion = selectedHostAPIVersion
    }
}
