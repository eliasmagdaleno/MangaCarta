//
//  HostJSONValueConverter.swift
//  MangaCarta
//
//  JSON-compatible structured cloning for browser results and durable host storage.
//  S4 owns the raw JSValue bridge; this converter deliberately starts at Foundation.
//

import Foundation

enum HostJSONValueConverter {
    static let maximumDepth = 128
    private static let maximumSafeInteger = 9_007_199_254_740_991.0

    static func convert(_ value: Any) throws -> JSONValue {
        try convert(value, depth: 0)
    }

    static func validate(_ value: JSONValue) throws {
        _ = try foundationValue(value, depth: 0)
    }

    static func foundationValue(_ value: JSONValue) throws -> Any {
        try foundationValue(value, depth: 0)
    }

    private static func convert(_ value: Any, depth: Int) throws -> JSONValue {
        guard depth <= maximumDepth else { throw invalid("the value is nested too deeply") }
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            return try convert(number)
        case let array as [Any]:
            return .array(try array.map { try convert($0, depth: depth + 1) })
        case let object as [String: Any]:
            return .object(try object.mapValues { try convert($0, depth: depth + 1) })
        default:
            throw invalid("the value is not JSON-compatible")
        }
    }

    private static func convert(_ number: NSNumber) throws -> JSONValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        let raw = number.doubleValue
        guard raw.isFinite else { throw invalid("non-finite numbers are not JSON values") }
        if raw.rounded(.towardZero) == raw {
            guard abs(raw) <= maximumSafeInteger, let integer = Int(exactly: raw) else {
                throw invalid("an integer is outside the safe JSON range")
            }
            return .int(integer)
        }
        return .double(raw)
    }

    private static func foundationValue(_ value: JSONValue, depth: Int) throws -> Any {
        guard depth <= maximumDepth else { throw invalid("the value is nested too deeply") }
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .int(let integer):
            guard abs(Double(integer)) <= maximumSafeInteger else {
                throw invalid("an integer is outside the safe JSON range")
            }
            return NSNumber(value: integer)
        case .double(let number):
            guard number.isFinite else { throw invalid("non-finite numbers are not JSON values") }
            return NSNumber(value: number)
        case .string(let string): return string
        case .array(let items):
            return try items.map { try foundationValue($0, depth: depth + 1) }
        case .object(let fields):
            return try fields.mapValues { try foundationValue($0, depth: depth + 1) }
        }
    }

    private static func invalid(_ message: String) -> HostCapabilityError {
        HostCapabilityError(code: .invalidResponse, message: message)
    }
}
