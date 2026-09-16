//
//  JSONValue.swift
//  MangaCarta
//
//  The inert JSON value a Source declaration is read from. The Host API design's
//  "Envelope and value rules" section says only JSON-compatible values cross the
//  boundary: no `undefined`, functions, symbols, cycles, non-finite numbers, dates,
//  typed arrays, or host objects, and integers must be safe JSON integers.
//
//  This type exists so a declaration — including an engine's private `configuration`,
//  where unknown keys survive — can be carried and compared as data with nothing
//  anywhere in reach that could evaluate it. `ManifestValidationCodeFreeTests` is the
//  structural guard on that claim, so keep this file's imports at Foundation alone.
//
//  Note for the Host API runtime slices: `ExtensionDomainSchemas` validates operation
//  *results* straight off dynamic `Any` values, because those arrive from a live
//  JavaScript context. A declaration is different — it is bytes on disk, read before
//  any context exists — so it is parsed once into this closed enum instead.
//

import Foundation

/// A parsed JSON value. `int` and `double` stay apart because the declaration's integer
/// fields (the image-prefetch hint) must not silently accept `4.5`.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let integer = try? container.decode(Int.self) {
            self = .int(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .double(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Why a payload could not be read as JSON at all.
    struct ParseFailure: Error, Equatable {
        let reason: String
    }

    /// Parses UTF-8 JSON text. Duplicate object keys resolve to one occurrence, which no
    /// rule here relies on: a declaration that repeats a key is malformed either way.
    init(parsing data: Data) throws {
        do {
            self = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ParseFailure(reason: error.localizedDescription)
        }
    }
}

extension JSONValue: Encodable {

    /// The inverse of `init(from:)`, so a raw declaration can be persisted as ordinary
    /// JSON by the installer (the repository format design's "What the installer
    /// persists": the declaration is stored as served, not as a typed value).
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .int(let integer): try container.encode(integer)
        case .double(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let items): try container.encode(items)
        case .object(let dictionary): try container.encode(dictionary)
        }
    }
}

extension JSONValue {

    var objectValue: [String: JSONValue]? {
        if case .object(let dictionary) = self { return dictionary }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }
}
