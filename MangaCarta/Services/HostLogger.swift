//
//  HostLogger.swift
//  MangaCarta
//
//  Bounded structured diagnostics. Sensitive fields are transformed before they ever
//  enter the buffer, so export cannot accidentally recover the original values.
//

import Foundation

struct HostLogEntry: Equatable, Sendable {
    let timestamp: Date
    let level: HostLogLevel
    let event: String
    let fields: [String: JSONValue]
    let sourceID: QualifiedSourceID
    let operation: SourceOperation
    let invocationID: UUID
    let durationSeconds: Double
    let hostAPIVersion: HostAPIVersion
}

actor HostDiagnosticBuffer {
    private let maximumEntries: Int
    private var entries: [HostLogEntry] = []

    init(maximumEntries: Int = HostCapabilityLimits.logEntries) {
        self.maximumEntries = max(0, maximumEntries)
    }

    func append(_ entry: HostLogEntry) {
        guard maximumEntries > 0 else { return }
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    /// Export is a host-owned, explicit reader action. Extension code receives no
    /// reference to the buffer and therefore cannot enumerate diagnostics.
    func export() -> [HostLogEntry] {
        entries
    }
}

struct HostLogger: Sendable {
    private static let redacted = JSONValue.string("<redacted>")
    private static let prohibitedNameFragments = [
        "query", "body", "cookie", "header", "storage", "search",
        "listingtitle", "chapterid", "reader", "identifier"
    ]

    private let sourceID: QualifiedSourceID
    private let operation: SourceOperation
    private let invocationID: UUID
    private let hostAPIVersion: HostAPIVersion
    private let buffer: HostDiagnosticBuffer
    private let startedAt: Date

    init(sourceID: QualifiedSourceID,
         operation: SourceOperation,
         invocationID: UUID,
         hostAPIVersion: HostAPIVersion,
         buffer: HostDiagnosticBuffer,
         startedAt: Date = Date()) {
        self.sourceID = sourceID
        self.operation = operation
        self.invocationID = invocationID
        self.hostAPIVersion = hostAPIVersion
        self.buffer = buffer
        self.startedAt = startedAt
    }

    func log(level: HostLogLevel,
             event: String,
             fields: [String: JSONValue] = [:]) async throws {
        guard Self.validEvent(event) else {
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "the log event is not a stable token")
        }
        guard fields.count <= HostCapabilityLimits.logFieldsPerCall else {
            throw HostCapabilityError(code: .resourceLimit,
                                      message: "the log field limit was exceeded")
        }

        var safe: [String: JSONValue] = [:]
        for (name, value) in fields {
            safe[name] = try Self.sanitize(value, named: name)
        }
        await buffer.append(HostLogEntry(timestamp: Date(),
                                         level: level,
                                         event: event,
                                         fields: safe,
                                         sourceID: sourceID,
                                         operation: operation,
                                         invocationID: invocationID,
                                         durationSeconds: max(0, Date().timeIntervalSince(startedAt)),
                                         hostAPIVersion: hostAPIVersion))
    }

    private static func sanitize(_ value: JSONValue, named name: String) throws -> JSONValue {
        let normalizedName = name.lowercased().filter(\.isLetter)
        if normalizedName.contains("url") {
            guard case .string(let raw) = value else { return redacted }
            return .string(redactedURL(raw))
        }
        if prohibitedNameFragments.contains(where: normalizedName.contains) {
            return redacted
        }

        switch value {
        case .null, .bool, .int:
            return value
        case .double(let number):
            guard number.isFinite else {
                throw HostCapabilityError(code: .invalidRequest,
                                          message: "log fields must be JSON scalars")
            }
            return value
        case .string(let string):
            guard string.utf8.count <= HostCapabilityLimits.logScalarBytes else {
                throw HostCapabilityError(code: .resourceLimit,
                                          message: "a log scalar exceeded the host limit")
            }
            if URL(string: string)?.scheme != nil {
                return .string(redactedURL(string))
            }
            return value
        case .array, .object:
            throw HostCapabilityError(code: .invalidRequest,
                                      message: "log fields must be JSON scalars")
        }
    }

    private static func redactedURL(_ raw: String) -> String {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return "<redacted>"
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            origin += ":\(port)"
        }
        let count = components.path.split(separator: "/", omittingEmptySubsequences: true).count
        return origin + String(repeating: "/<redacted>", count: count)
    }

    private static func validEvent(_ event: String) -> Bool {
        guard !event.isEmpty, event.utf8.count <= HostCapabilityLimits.logEventBytes else {
            return false
        }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return event.unicodeScalars.allSatisfy(allowed.contains)
    }
}
