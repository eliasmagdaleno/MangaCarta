//
//  HostCapabilityTypes.swift
//  MangaCarta
//
//  The typed Swift interface behind context.host. ExtensionRuntime owns conversion at
//  the JavaScript seam; these values own host-capability semantics after conversion.
//

import Foundation

struct HostCapabilityError: Error, Equatable, Sendable {
    let code: ExtensionHostErrorCode
    let message: String
    let retryAfterSeconds: Double?
    let details: JSONValue?

    init(code: ExtensionHostErrorCode,
         message: String,
         retryAfterSeconds: Double? = nil,
         details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
        self.details = details
    }
}

/// OPEN EVIDENCE GATE. These conservative implementation tunables live together so
/// profiling can replace them without changing the Host API contract. The design's
/// "Scheduling, budgets, and cancellation" section names the required corpus: the
/// WeebCentral port, Madara across three sites, one JSON API Source, low-memory devices,
/// slow networks, Cloudflare, and background expiration.
enum HostCapabilityLimits {
    static let maximumRedirects = 5
    static let requestBodyBytes = 1 * 1_024 * 1_024
    static let responseBodyBytes = 5 * 1_024 * 1_024
    static let interactiveTimeout: TimeInterval = 30
    static let backgroundTimeout: TimeInterval = 15
    static let browserNavigationTimeout: TimeInterval = 30
    static let browserScriptTimeout: TimeInterval = 15
    static let browserInteractionTimeout: TimeInterval = 120
    static let storageKeyBytes = 256
    static let storageTotalBytes = 256 * 1_024
    static let logEventBytes = 128
    static let logFieldsPerCall = 32
    static let logScalarBytes = 1_024
    static let logEntries = 500
}

enum HostHTTPMethod: String, Equatable, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

enum HostHTTPTimeoutClass: Equatable, Sendable {
    case interactive
    case background

    var interval: TimeInterval {
        switch self {
        case .interactive: return HostCapabilityLimits.interactiveTimeout
        case .background: return HostCapabilityLimits.backgroundTimeout
        }
    }
}

enum HostHTTPResponseType: Equatable, Sendable {
    case text
    case base64
}

enum HostHTTPBody: Equatable, Sendable {
    case text(String)
    case base64(String)
}

struct HostHTTPRequest: Equatable, Sendable {
    let url: URL
    let method: HostHTTPMethod
    let headers: [String: String]
    let body: HostHTTPBody?
    let timeoutClass: HostHTTPTimeoutClass
    let responseType: HostHTTPResponseType

    init(url: URL,
         method: HostHTTPMethod = .get,
         headers: [String: String] = [:],
         body: HostHTTPBody? = nil,
         timeoutClass: HostHTTPTimeoutClass = .interactive,
         responseType: HostHTTPResponseType = .text) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutClass = timeoutClass
        self.responseType = responseType
    }
}

enum HostHTTPResponseBody: Equatable, Sendable {
    case text(String)
    case base64(String)
}

struct HostHTTPResponse: Equatable, Sendable {
    let status: Int
    let finalURL: URL
    let headers: [String: String]
    let body: HostHTTPResponseBody
    let retryAfterSeconds: Double?
}

struct HostHTTPTransportResponse: Sendable {
    let statusCode: Int
    let url: URL
    let headers: [String: String]
    let body: Data
}

protocol HostHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse
}

protocol HostNameResolving: Sendable {
    func addresses(for host: String) async throws -> [String]
}

enum HostBrowserInteraction: String, Equatable, Sendable {
    case allowForeground
    case never
}

enum HostInvocationContext: Equatable, Sendable {
    case foreground
    case background
}

struct HostBrowserRequest: Equatable, Sendable {
    let url: URL
    let script: String
    let interaction: HostBrowserInteraction

    init(url: URL,
         script: String,
         interaction: HostBrowserInteraction = .allowForeground) {
        self.url = url
        self.script = script
        self.interaction = interaction
    }
}

struct HostBrowserResult: Equatable, Sendable {
    let value: JSONValue
    let finalURL: URL
    let warnings: [ExtensionValidationWarning]
}

enum HostBrowserNavigationDecision: Equatable, Sendable {
    case allow
    case cancel(HostCapabilityError)
}

enum HostLogLevel: String, Equatable, Sendable {
    case debug
    case info
    case warning
    case error
}

/// The Source-scoped capability facade S4 adapts into `context.host`.
struct ExtensionHostCapabilities {
    let http: HostHTTPClient
    let browser: HostBrowserCapability
    let storage: HostStorage
    let log: HostLogger
}
