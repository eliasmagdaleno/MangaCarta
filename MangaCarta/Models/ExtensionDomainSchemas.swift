//
//  ExtensionDomainSchemas.swift
//  MangaCarta
//
//  Host API v1 domain-wire validation and adapters. These types deliberately
//  accept `Any`: JavaScriptCore values arrive dynamically, and typed domain
//  values are created only after the complete result passes JSON and schema
//  validation.
//

import CoreFoundation
import Foundation

enum ExtensionHostErrorCode: String, Codable, Equatable {
    case cancelled
    case invalidRequest = "invalid_request"
    case invalidResponse = "invalid_response"
    case invalidResult = "invalid_result"
    case unsupported
    case unsupportedLanguage = "unsupported_language"
    case network
    case http
    case rateLimited = "rate_limited"
    case timeout
    case resourceLimit = "resource_limit"
    case policyDenied = "policy_denied"
    case interactionRequired = "interaction_required"
    case interactionDeclined = "interaction_declined"
    case interactionTimedOut = "interaction_timed_out"
    case navigation
    case script
    case storage
    case incompatibleVersion = "incompatible_version"
}

struct ExtensionSchemaError: LocalizedError, Equatable {
    let code: ExtensionHostErrorCode
    let fieldPath: String
    let reason: String

    init(fieldPath: String, reason: String) {
        code = .invalidResponse
        self.fieldPath = fieldPath
        self.reason = reason
    }

    var errorDescription: String? {
        "Extension response is invalid at \(fieldPath): \(reason)"
    }
}

enum ExtensionValidationWarningCode: String, Codable, Equatable {
    case missingRequiredField = "missing_required_field"
    case invalidField = "invalid_field"
    case malformedURL = "malformed_url"
    /// An optional cover URL that parsed but violated the declared asset policy. Distinct
    /// from `malformedURL` so a Source author can tell a typo from a policy breach — see
    /// ADR-0024, which is why this drops the field instead of rejecting the operation.
    case policyInvalidURL = "policy_invalid_url"
}

struct ExtensionValidationWarning: Codable, Equatable {
    let code: ExtensionValidationWarningCode
    let itemIndex: Int?
    let fieldPath: String
}

struct ExtensionValidatedResult<Value> {
    let value: Value
    let warnings: [ExtensionValidationWarning]
}

struct ExtensionValidatedPage<Item> {
    let items: [Item]
    let nextCursor: String?
    let exhausted: Bool
    let warnings: [ExtensionValidationWarning]
}

struct ExtensionListing: Equatable {
    let id: String
    let title: String
    let description: String?
    let coverURL: URL?
    let status: String?
    let year: Int?
    let externalIds: [String: String]
    let alternateTitles: [String]
    let contentRating: String?

    /// The invoked Source id is an adapter argument, never a wire field. Unknown
    /// external-id namespaces remain available on this wire value even though the
    /// current app model only understands MAL.
    func toManga(sourceID: String) -> Manga {
        Manga(
            id: id,
            sourceId: sourceID,
            title: title,
            description: description ?? "",
            status: status ?? "unknown",
            year: year,
            coverURL: coverURL,
            malId: externalIds["mal"].flatMap(Int.init),
            altTitles: alternateTitles.isEmpty ? nil : alternateTitles,
            contentRating: contentRating
        )
    }
}

struct ExtensionUpdate: Equatable {
    let chapterId: String
    let listing: ExtensionListing

    func toMangaUpdate(sourceID: String) -> MangaUpdate {
        MangaUpdate(chapterId: chapterId, manga: listing.toManga(sourceID: sourceID))
    }
}

struct ExtensionTag: Equatable {
    let id: String?
    let name: String
    let group: String?
}

struct ExtensionDetail: Equatable {
    let description: String
    let authors: [String]
    let tags: [ExtensionTag]
    let contentRating: String?

    func toMangaDetail() -> MangaDetail {
        MangaDetail(
            description: description,
            authors: authors,
            tags: tags.map { Tag(id: $0.id, name: $0.name, group: $0.group) },
            contentRating: contentRating
        )
    }
}

struct ExtensionChapter: Equatable {
    let id: String
    let number: String?
    let title: String?
    let publishedAt: Date?
    let language: String?
    let groups: [String]?

    func toChapter() -> Chapter {
        Chapter(id: id, number: number ?? "?", title: title, date: publishedAt)
    }
}

struct ExtensionPage: Equatable {
    let url: URL
}

struct ExtensionDomainValidator {
    private static let maximumSafeJSONInteger = 9_007_199_254_740_991.0
    private static let statuses: Set<String> = [
        "ongoing", "completed", "hiatus", "cancelled", "unknown"
    ]
    private static let contentRatings: Set<String> = [
        "safe", "suggestive", "erotica", "pornographic"
    ]

    private let currentYear: Int
    private let assetOrigins: Set<String>

    /// The clock is injected so the `current year + 1` wire bound remains stable in tests.
    init(currentDate: Date = Date(),
         calendar: Calendar = Calendar(identifier: .gregorian),
         assetOrigins: [String]) {
        currentYear = calendar.component(.year, from: currentDate)
        self.assetOrigins = Set(assetOrigins.compactMap(Self.normalizedOrigin))
    }

    // MARK: - Operation validators

    func validateListingPage(_ value: Any) throws -> ExtensionValidatedPage<ExtensionListing> {
        try validateJSON(value)
        let page = try pagination(from: value)
        var listings: [ExtensionListing] = []
        var warnings: [ExtensionValidationWarning] = []

        for (index, item) in page.items.enumerated() {
            let path = "items[\(index)]"
            guard let object = item as? [String: Any] else {
                throw invalid(path, "expected an object")
            }

            if let missingPath = missingListingIdentity(in: object, path: path) {
                warnings.append(warning(.missingRequiredField, index, missingPath))
                continue
            }

            let parsed = try listing(from: object, path: path, itemIndex: index)
            listings.append(parsed.value)
            warnings.append(contentsOf: parsed.warnings)
        }

        return ExtensionValidatedPage(items: listings,
                                      nextCursor: page.nextCursor,
                                      exhausted: page.exhausted,
                                      warnings: warnings)
    }

    func validateListing(_ value: Any) throws -> ExtensionValidatedResult<ExtensionListing> {
        try validateJSON(value)
        guard let object = value as? [String: Any] else {
            throw invalid("listing", "expected an object")
        }
        return try listing(from: object, path: "listing", itemIndex: nil)
    }

    func validateUpdatePage(_ value: Any) throws -> ExtensionValidatedPage<ExtensionUpdate> {
        try validateJSON(value)
        let page = try pagination(from: value)
        var updates: [ExtensionUpdate] = []
        var warnings: [ExtensionValidationWarning] = []

        for (index, item) in page.items.enumerated() {
            let path = "items[\(index)]"
            do {
                guard let object = item as? [String: Any] else {
                    throw invalid(path, "expected an object")
                }
                let chapterId = try requiredNonemptyString(object, key: "chapterId", path: path,
                                                            maximumUTF8Bytes: 512)
                guard let rawListing = object["listing"],
                      let listingObject = rawListing as? [String: Any] else {
                    throw invalid("\(path).listing", "expected an object")
                }
                if let missingPath = missingListingIdentity(in: listingObject,
                                                            path: "\(path).listing") {
                    throw invalid(missingPath, "missing required field")
                }
                let parsed = try listing(from: listingObject,
                                         path: "\(path).listing",
                                         itemIndex: index)
                updates.append(ExtensionUpdate(chapterId: chapterId, listing: parsed.value))
                warnings.append(contentsOf: parsed.warnings)
            } catch is ExtensionSchemaError {
                warnings.append(warning(.invalidField, index, path))
            }
        }

        return ExtensionValidatedPage(items: updates,
                                      nextCursor: page.nextCursor,
                                      exhausted: page.exhausted,
                                      warnings: warnings)
    }

    func validateDetail(_ value: Any) throws -> ExtensionValidatedResult<ExtensionDetail> {
        try validateJSON(value)
        guard let object = value as? [String: Any] else {
            throw invalid("detail", "expected an object")
        }

        let description = try optionalString(object, key: "description", path: "detail") ?? ""
        let authors = try stringArray(object, key: "authors", path: "detail") ?? []
        let contentRating = try enumString(object, key: "contentRating", path: "detail",
                                           allowed: Self.contentRatings)
        let rawTags = try optionalArray(object, key: "tags", path: "detail") ?? []
        var tags: [ExtensionTag] = []
        var warnings: [ExtensionValidationWarning] = []

        for (index, rawTag) in rawTags.enumerated() {
            let path = "tags[\(index)]"
            do {
                guard let tag = rawTag as? [String: Any] else {
                    throw invalid(path, "expected an object")
                }
                let name = try requiredNonemptyString(tag, key: "name", path: path)
                let id = try optionalString(tag, key: "id", path: path)
                let group = try optionalString(tag, key: "group", path: path)
                tags.append(ExtensionTag(id: id, name: name, group: group))
            } catch is ExtensionSchemaError {
                warnings.append(warning(.invalidField, index, path))
            }
        }

        return ExtensionValidatedResult(
            value: ExtensionDetail(description: description,
                                   authors: authors,
                                   tags: tags,
                                   contentRating: contentRating),
            warnings: warnings
        )
    }

    func validateChapters(_ value: Any) throws -> ExtensionValidatedResult<[ExtensionChapter]> {
        try validateJSON(value)
        let rawItems = try operationItems(value, operation: "chapters")
        var chapters: [ExtensionChapter] = []
        var warnings: [ExtensionValidationWarning] = []

        for (index, item) in rawItems.enumerated() {
            let path = "items[\(index)]"
            do {
                guard let object = item as? [String: Any] else {
                    throw invalid(path, "expected an object")
                }
                let id = try requiredNonemptyString(object, key: "id", path: path)
                let number = try optionalString(object, key: "number", path: path)
                let title = try optionalString(object, key: "title", path: path)
                let language = try optionalString(object, key: "language", path: path)
                let groups = try chapterGroups(object, path: path)

                var publishedAt: Date?
                if let rawDate = object["publishedAt"] {
                    if let string = rawDate as? String,
                       let date = Self.rfc3339Date(from: string) {
                        publishedAt = date
                    } else {
                        warnings.append(warning(.invalidField, index, "\(path).publishedAt"))
                    }
                }

                chapters.append(ExtensionChapter(id: id,
                                                  number: number,
                                                  title: title,
                                                  publishedAt: publishedAt,
                                                  language: language,
                                                  groups: groups))
            } catch is ExtensionSchemaError {
                warnings.append(warning(.invalidField, index, path))
            }
        }

        return ExtensionValidatedResult(value: chapters, warnings: warnings)
    }

    func validatePages(_ value: Any) throws -> ExtensionValidatedResult<[ExtensionPage]> {
        try validateJSON(value)
        let rawItems = try operationItems(value, operation: "pages")
        let pages = try rawItems.enumerated().map { index, item -> ExtensionPage in
            let path = "items[\(index)]"
            guard let object = item as? [String: Any] else {
                throw invalid(path, "expected an object")
            }
            let rawURL = try requiredString(object, key: "url", path: path)

            if let headers = object["headers"] {
                guard let dictionary = headers as? [String: Any], dictionary.isEmpty else {
                    throw invalid("\(path).headers", "per-image headers are reserved in Host API v1")
                }
            }

            switch assetURL(rawURL) {
            case .malformed:
                throw invalid("\(path).url", "expected an absolute network URL")
            case .policyInvalid:
                throw invalid("\(path).url", "URL violates the declared asset policy")
            case .valid(let url):
                return ExtensionPage(url: url)
            }
        }
        return ExtensionValidatedResult(value: pages, warnings: [])
    }

    // MARK: - Domain fields

    private func listing(from object: [String: Any],
                         path: String,
                         itemIndex: Int?) throws -> ExtensionValidatedResult<ExtensionListing> {
        let id = try requiredNonemptyString(object, key: "id", path: path,
                                            maximumUTF8Bytes: 512)
        let title = try requiredNonemptyString(object, key: "title", path: path,
                                               maximumUnicodeScalars: 512)
        let description = try optionalString(object, key: "description", path: path)
        let status = try enumString(object, key: "status", path: path, allowed: Self.statuses)
        let contentRating = try enumString(object, key: "contentRating", path: path,
                                           allowed: Self.contentRatings)
        let year = try listingYear(object, path: path)
        var externalIds = try stringDictionary(object, key: "externalIds", path: path) ?? [:]
        let alternateTitles = try alternateTitles(object, path: path)
        var coverURL: URL?
        var warnings: [ExtensionValidationWarning] = []

        if let mal = externalIds["mal"],
           (mal.isEmpty
            || mal.unicodeScalars.contains { $0.value < 48 || $0.value > 57 }
            || Int(mal).map({ $0 > 0 }) != true) {
            externalIds.removeValue(forKey: "mal")
            warnings.append(warning(.invalidField, itemIndex, "\(path).externalIds.mal"))
        }

        if let rawCover = try optionalString(object, key: "coverURL", path: path) {
            switch assetURL(rawCover) {
            case .malformed:
                warnings.append(warning(.malformedURL, itemIndex, "\(path).coverURL"))
            case .policyInvalid:
                warnings.append(warning(.policyInvalidURL, itemIndex, "\(path).coverURL"))
            case .valid(let url):
                coverURL = url
            }
        }

        return ExtensionValidatedResult(
            value: ExtensionListing(id: id,
                                    title: title,
                                    description: description,
                                    coverURL: coverURL,
                                    status: status,
                                    year: year,
                                    externalIds: externalIds,
                                    alternateTitles: alternateTitles,
                                    contentRating: contentRating),
            warnings: warnings
        )
    }

    private func missingListingIdentity(in object: [String: Any], path: String) -> String? {
        for key in ["id", "title"] {
            guard let raw = object[key] else { return "\(path).\(key)" }
            if let string = raw as? String,
               string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(path).\(key)"
            }
        }
        return nil
    }

    private func listingYear(_ object: [String: Any], path: String) throws -> Int? {
        guard let raw = object["year"] else { return nil }
        let year = try integer(raw, path: "\(path).year")
        guard (1000...(currentYear + 1)).contains(year) else {
            throw invalid("\(path).year", "year is outside the supported range")
        }
        return year
    }

    private func alternateTitles(_ object: [String: Any], path: String) throws -> [String] {
        guard let values = try optionalArray(object, key: "alternateTitles", path: path) else {
            return []
        }
        var seen = Set<String>()
        var output: [String] = []
        for (index, value) in values.enumerated() {
            guard let string = value as? String else {
                throw invalid("\(path).alternateTitles[\(index)]", "expected a string")
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                output.append(trimmed)
            }
        }
        return output
    }

    // MARK: - Pagination

    private struct PaginationValue {
        let items: [Any]
        let nextCursor: String?
        let exhausted: Bool
    }

    private func pagination(from value: Any) throws -> PaginationValue {
        guard let object = value as? [String: Any] else {
            throw invalid("page", "expected an object")
        }
        guard let items = object["items"] as? [Any] else {
            throw invalid("items", "expected an array")
        }
        guard let rawExhausted = object["exhausted"] else {
            throw invalid("exhausted", "missing required field")
        }
        let exhausted = try boolean(rawExhausted, path: "exhausted")

        var nextCursor: String?
        if let rawCursor = object["nextCursor"], !(rawCursor is NSNull) {
            guard let cursor = rawCursor as? String else {
                throw invalid("nextCursor", "expected a string or null")
            }
            guard cursor.utf8.count <= 2_048 else {
                throw invalid("nextCursor", "cursor exceeds 2 KiB")
            }
            nextCursor = cursor
        }

        guard (nextCursor != nil) != exhausted else {
            throw invalid("page", "requires exactly one of nextCursor or exhausted")
        }
        return PaginationValue(items: items, nextCursor: nextCursor, exhausted: exhausted)
    }

    private func operationItems(_ value: Any, operation: String) throws -> [Any] {
        guard let object = value as? [String: Any] else {
            throw invalid(operation, "expected an object")
        }
        guard let items = object["items"] as? [Any] else {
            throw invalid("items", "expected an array")
        }
        return items
    }

    // MARK: - URL policy

    private enum AssetURLResult {
        case malformed
        case policyInvalid
        case valid(URL)
    }

    private func assetURL(_ raw: String) -> AssetURLResult {
        guard let components = URLComponents(string: raw),
              let url = components.url else {
            return .malformed
        }
        guard let scheme = components.scheme else { return .malformed }
        guard scheme.lowercased() == "https" else { return .policyInvalid }
        guard let host = components.host, !host.isEmpty else { return .malformed }
        guard components.user == nil,
              components.password == nil,
              let origin = Self.normalizedOrigin(raw),
              assetOrigins.contains(origin) else {
            return .policyInvalid
        }
        return .valid(url)
    }

    private static func normalizedOrigin(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        if let port = components.port, port != 443 {
            return "https://\(host):\(port)"
        }
        return "https://\(host)"
    }

    // MARK: - JSON and scalar validation

    private func validateJSON(_ value: Any) throws {
        var ancestors = Set<ObjectIdentifier>()
        try validateJSON(value, path: "value", ancestors: &ancestors)
    }

    private func validateJSON(_ value: Any,
                              path: String,
                              ancestors: inout Set<ObjectIdentifier>) throws {
        if value is NSNull || value is String { return }

        if let number = value as? NSNumber {
            try validateJSONNumber(number, path: path)
            return
        }

        if let array = value as? NSArray {
            try validateJSONArray(array, path: path, ancestors: &ancestors)
            return
        }

        if let dictionary = value as? NSDictionary {
            try validateJSONObject(dictionary, path: path, ancestors: &ancestors)
            return
        }

        throw invalid(path, "value is not JSON-compatible")
    }

    private func validateJSONNumber(_ number: NSNumber, path: String) throws {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return }
        let double = number.doubleValue
        guard double.isFinite else {
            throw invalid(path, "non-finite numbers are not JSON values")
        }
        if double.rounded(.towardZero) == double,
           abs(double) > Self.maximumSafeJSONInteger {
            throw invalid(path, "integer is outside the safe JSON range")
        }
    }

    private func validateJSONArray(_ array: NSArray,
                                   path: String,
                                   ancestors: inout Set<ObjectIdentifier>) throws {
        let identity = ObjectIdentifier(array)
        guard ancestors.insert(identity).inserted else {
            throw invalid(path, "cyclic values are not JSON values")
        }
        defer { ancestors.remove(identity) }
        for index in 0..<array.count {
            try validateJSON(array[index], path: "\(path)[\(index)]", ancestors: &ancestors)
        }
    }

    private func validateJSONObject(_ dictionary: NSDictionary,
                                    path: String,
                                    ancestors: inout Set<ObjectIdentifier>) throws {
        let identity = ObjectIdentifier(dictionary)
        guard ancestors.insert(identity).inserted else {
            throw invalid(path, "cyclic values are not JSON values")
        }
        defer { ancestors.remove(identity) }
        for key in dictionary.allKeys {
            guard let stringKey = key as? String else {
                throw invalid(path, "JSON object keys must be strings")
            }
            guard let child = dictionary.object(forKey: key) else { continue }
            try validateJSON(child, path: "\(path).\(stringKey)", ancestors: &ancestors)
        }
    }

    private func requiredString(_ object: [String: Any],
                                key: String,
                                path: String) throws -> String {
        guard let raw = object[key], !(raw is NSNull) else {
            throw invalid("\(path).\(key)", "missing required field")
        }
        guard let string = raw as? String else {
            throw invalid("\(path).\(key)", "expected a string")
        }
        return string
    }

    private func requiredNonemptyString(_ object: [String: Any],
                                        key: String,
                                        path: String,
                                        maximumUTF8Bytes: Int? = nil,
                                        maximumUnicodeScalars: Int? = nil) throws -> String {
        let string = try requiredString(object, key: key, path: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else {
            throw invalid("\(path).\(key)", "expected a nonempty string")
        }
        if let maximumUTF8Bytes, string.utf8.count > maximumUTF8Bytes {
            throw invalid("\(path).\(key)", "string exceeds its UTF-8 byte limit")
        }
        if let maximumUnicodeScalars, string.unicodeScalars.count > maximumUnicodeScalars {
            throw invalid("\(path).\(key)", "string exceeds its Unicode scalar limit")
        }
        return string
    }

    private func optionalString(_ object: [String: Any],
                                key: String,
                                path: String) throws -> String? {
        guard let raw = object[key] else { return nil }
        guard let string = raw as? String else {
            throw invalid("\(path).\(key)", "expected a string")
        }
        return string
    }

    private func enumString(_ object: [String: Any],
                            key: String,
                            path: String,
                            allowed: Set<String>) throws -> String? {
        guard let value = try optionalString(object, key: key, path: path) else { return nil }
        guard allowed.contains(value) else {
            throw invalid("\(path).\(key)", "unsupported enum value")
        }
        return value
    }

    private func optionalArray(_ object: [String: Any],
                               key: String,
                               path: String) throws -> [Any]? {
        guard let raw = object[key] else { return nil }
        guard let array = raw as? [Any] else {
            throw invalid("\(path).\(key)", "expected an array")
        }
        return array
    }

    private func stringArray(_ object: [String: Any],
                             key: String,
                             path: String) throws -> [String]? {
        guard let array = try optionalArray(object, key: key, path: path) else { return nil }
        return try array.enumerated().map { index, value in
            guard let string = value as? String else {
                throw invalid("\(path).\(key)[\(index)]", "expected a string")
            }
            return string
        }
    }

    private func chapterGroups(_ object: [String: Any], path: String) throws -> [String]? {
        guard let array = try optionalArray(object, key: "groups", path: path) else { return nil }
        guard array.count <= 10 else {
            throw invalid("\(path).groups", "too many group names")
        }
        return try array.enumerated().map { index, value in
            guard let string = value as? String else {
                throw invalid("\(path).groups[\(index)]", "expected a string")
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw invalid("\(path).groups[\(index)]", "expected a nonempty string")
            }
            guard trimmed.unicodeScalars.count <= 200 else {
                throw invalid("\(path).groups[\(index)]", "string exceeds its Unicode scalar limit")
            }
            return trimmed
        }
    }

    private func stringDictionary(_ object: [String: Any],
                                  key: String,
                                  path: String) throws -> [String: String]? {
        guard let raw = object[key] else { return nil }
        guard let dictionary = raw as? [String: Any] else {
            throw invalid("\(path).\(key)", "expected an object")
        }
        var output: [String: String] = [:]
        for (namespace, value) in dictionary {
            guard let string = value as? String else {
                throw invalid("\(path).\(key).\(namespace)", "expected a string")
            }
            output[namespace] = string
        }
        return output
    }

    private func integer(_ value: Any, path: String) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw invalid(path, "expected an integer")
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              abs(double) <= Self.maximumSafeJSONInteger,
              let integer = Int(exactly: double) else {
            throw invalid(path, "expected a safe JSON integer")
        }
        return integer
    }

    private func boolean(_ value: Any, path: String) throws -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid(path, "expected a boolean")
        }
        return number.boolValue
    }

    private static func rfc3339Date(from value: String) -> Date? {
        let pattern = #"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let normalized = value.replacingOccurrences(of: "t", with: "T")
            .replacingOccurrences(of: "z", with: "Z")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = normalized.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    private func invalid(_ path: String, _ reason: String) -> ExtensionSchemaError {
        ExtensionSchemaError(fieldPath: path, reason: reason)
    }

    private func warning(_ code: ExtensionValidationWarningCode,
                         _ itemIndex: Int?,
                         _ path: String) -> ExtensionValidationWarning {
        ExtensionValidationWarning(code: code, itemIndex: itemIndex, fieldPath: path)
    }
}
