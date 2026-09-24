//
//  HostHTTPClient.swift
//  MangaCarta
//
//  Bounded, Source-scoped HTTP. Transport performs exactly one hop; this module owns
//  redirects so no destination can bypass origin membership or DNS validation.
//

import Foundation

struct HostHTTPClient: Sendable {
    private static let prohibitedHeaders: Set<String> = [
        "host", "cookie", "authorization", "proxy-authorization", "user-agent"
    ]
    private static let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "te", "trailer",
        "transfer-encoding", "upgrade", "content-length"
    ]
    private static let responseHeaders: Set<String> = [
        "cache-control", "content-language", "content-type", "etag", "expires",
        "last-modified", "retry-after"
    ]
    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    private let policy: HostURLPolicy
    private let transport: any HostHTTPTransport
    private let cookies: HostHTTPCookieJar
    private let sourceID: QualifiedSourceID

    init(sourceID: QualifiedSourceID,
         allowedOrigins: [String],
         transport: any HostHTTPTransport = URLSessionHostHTTPTransport(),
         resolver: any HostNameResolving = SystemHostResolver()) {
        self.init(sourceID: sourceID,
                  allowedOrigins: allowedOrigins,
                  transport: transport,
                  resolver: resolver,
                  cookies: HostHTTPCookieJar(sourceID: sourceID))
    }

    /// Takes a jar rather than making one, so a caller serving several Sources can keep each
    /// Source's cookies alive across invocations. `sourceID` is required alongside it because
    /// the jar checks the two agree: handing one Source's jar to another Source's client
    /// yields no cookies instead of silently pooling them.
    init(sourceID: QualifiedSourceID,
         allowedOrigins: [String],
         transport: any HostHTTPTransport,
         resolver: any HostNameResolving,
         cookies: HostHTTPCookieJar) {
        policy = HostURLPolicy(allowedOrigins: allowedOrigins, resolver: resolver)
        self.transport = transport
        self.cookies = cookies
        self.sourceID = sourceID
    }

    func request(_ input: HostHTTPRequest) async throws -> HostHTTPResponse {
        let authorHeaders = try await validatedHeaders(input.headers)
        let body = try requestBody(input.body)
        var url = input.url
        var method = input.method
        var redirects = 0

        while true {
            try Task.checkCancellation()
            try await policy.validate(url)

            var request = URLRequest(url: url)
            request.httpMethod = method.rawValue
            request.timeoutInterval = input.timeoutClass.interval
            request.httpBody = method == .post ? body : nil
            for (name, value) in authorHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if let cookie = await cookies.header(for: url, sourceID: sourceID) {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }

            let response = try await send(request)
            if let peer = response.connectedPeerAddress, !HostIPAddress.isPublic(peer) {
                throw HostCapabilityError(code: .policyDenied,
                                          message: "the connected destination was non-public")
            }
            try await policy.validate(response.url)

            guard response.body.count <= HostCapabilityLimits.responseBodyBytes else {
                throw HostCapabilityError(code: .resourceLimit,
                                          message: "the HTTP response exceeded the host limit")
            }
            await cookies.store(responseHeaders: response.headers, for: url, sourceID: sourceID)

            if Self.redirectStatuses.contains(response.statusCode),
               let location = header("location", in: response.headers) {
                guard redirects < HostCapabilityLimits.maximumRedirects else {
                    throw HostCapabilityError(code: .resourceLimit,
                                              message: "the HTTP redirect limit was exceeded")
                }
                guard let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw HostCapabilityError(code: .policyDenied,
                                              message: "the HTTP redirect target is invalid")
                }
                try await policy.validate(next)
                redirects += 1
                if response.statusCode == 303 ||
                    ((response.statusCode == 301 || response.statusCode == 302) && method == .post) {
                    method = .get
                }
                url = next
                continue
            }

            return try makeResponse(response, requestedType: input.responseType)
        }
    }

    private func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw HostCapabilityError(code: .cancelled, message: "the HTTP request was cancelled")
        } catch let error as URLError {
            throw transportError(error)
        } catch let error as HostCapabilityError {
            throw error
        } catch {
            throw HostCapabilityError(code: .network, message: "the HTTP transport failed")
        }
    }

    private func validatedHeaders(_ headers: [String: String]) async throws -> [String: String] {
        var lowered: [String: String] = [:]
        for (name, value) in headers {
            let lowercased = name.lowercased()
            guard lowered[lowercased] == nil else {
                throw HostCapabilityError(code: .policyDenied,
                                          message: "the request contains a duplicate header")
            }
            lowered[lowercased] = value
        }
        if lowered.keys.contains(where: Self.prohibitedHeaders.contains) {
            throw HostCapabilityError(code: .policyDenied,
                                      message: "the request contains a host-owned header")
        }

        for name in ["referer", "origin"] {
            guard let value = lowered[name] else { continue }
            guard let url = URL(string: value) else {
                throw HostCapabilityError(code: .policyDenied,
                                          message: "the request contains an invalid \(name) header")
            }
            try await policy.validate(url)
        }

        var stripped = Self.hopByHopHeaders
        if let connection = lowered["connection"] {
            for name in connection.split(separator: ",") {
                stripped.insert(name.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }

        var result: [String: String] = [:]
        for (name, value) in headers where !stripped.contains(name.lowercased()) {
            guard Self.validHeaderName(name),
                  !value.contains("\r"), !value.contains("\n") else {
                throw HostCapabilityError(code: .policyDenied,
                                          message: "the request contains an invalid header")
            }
            result[name] = value
        }
        return result
    }

    private static func validHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return name.unicodeScalars.allSatisfy(token.contains)
    }

    private func requestBody(_ body: HostHTTPBody?) throws -> Data? {
        let data: Data?
        switch body {
        case .none: data = nil
        case .text(let text): data = Data(text.utf8)
        case .base64(let encoded):
            guard let decoded = Data(base64Encoded: encoded) else {
                throw HostCapabilityError(code: .invalidRequest,
                                          message: "the request body is not valid base64")
            }
            data = decoded
        }
        guard (data?.count ?? 0) <= HostCapabilityLimits.requestBodyBytes else {
            throw HostCapabilityError(code: .resourceLimit,
                                      message: "the HTTP request body exceeded the host limit")
        }
        return data
    }

    private func makeResponse(_ response: HostHTTPTransportResponse,
                              requestedType: HostHTTPResponseType) throws -> HostHTTPResponse {
        let body: HostHTTPResponseBody
        switch requestedType {
        case .text:
            guard let text = String(data: response.body, encoding: .utf8) else {
                throw HostCapabilityError(code: .network,
                                          message: "the HTTP response is not valid UTF-8 text")
            }
            body = .text(text)
        case .base64:
            body = .base64(response.body.base64EncodedString())
        }

        var selected: [String: String] = [:]
        for (name, value) in response.headers where Self.responseHeaders.contains(name.lowercased()) {
            selected[name] = value
        }
        return HostHTTPResponse(status: response.statusCode,
                                finalURL: response.url,
                                headers: selected,
                                body: body,
                                retryAfterSeconds: retryAfter(from: response.headers))
    }

    private func retryAfter(from headers: [String: String]) -> Double? {
        guard let raw = header("retry-after", in: headers) else { return nil }
        if let seconds = Double(raw), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func transportError(_ error: URLError) -> HostCapabilityError {
        switch error.code {
        case .cancelled:
            return HostCapabilityError(code: .cancelled, message: "the HTTP request was cancelled")
        case .timedOut:
            return HostCapabilityError(code: .timeout, message: "the HTTP request timed out")
        default:
            return HostCapabilityError(code: .network, message: "the HTTP transport failed")
        }
    }
}

/// One Source's HTTP cookies. Isolation used to rest entirely on each Source being handed a
/// distinct jar, with `sourceID` stored and then discarded — so pooling every Source into one
/// jar compiled clean and passed the whole suite. Each call now names the Source it is acting
/// for and the jar refuses to answer for any other.
actor HostHTTPCookieJar {
    private let sourceID: QualifiedSourceID
    private var cookiesByOrigin: [String: [HTTPCookie]] = [:]

    init(sourceID: QualifiedSourceID) {
        self.sourceID = sourceID
    }

    func header(for url: URL, sourceID: QualifiedSourceID) -> String? {
        guard sourceID == self.sourceID else { return nil }
        guard let origin = HostURLPolicy.canonicalOrigin(for: url) else { return nil }
        let now = Date()
        let path = url.path.isEmpty ? "/" : url.path
        let cookies = (cookiesByOrigin[origin] ?? []).filter { cookie in
            (cookie.expiresDate == nil || cookie.expiresDate! > now) &&
                path.hasPrefix(cookie.path) && cookie.isSecure
        }
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    func store(responseHeaders: [String: String], for url: URL, sourceID: QualifiedSourceID) {
        guard sourceID == self.sourceID else { return }
        guard let origin = HostURLPolicy.canonicalOrigin(for: url) else { return }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url)
        guard !parsed.isEmpty else { return }
        var current = cookiesByOrigin[origin] ?? []
        for cookie in parsed {
            current.removeAll {
                $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
            }
            if cookie.expiresDate == nil || cookie.expiresDate! > Date() {
                current.append(cookie)
            }
        }
        cookiesByOrigin[origin] = current
    }
}

final class URLSessionHostHTTPTransport: NSObject, HostHTTPTransport,
                                         @unchecked Sendable {
    private let fetcher: any URLSessionDataFetching

    override init() {
        let configuration = Self.sessionConfiguration()
        fetcher = URLSessionDataFetcher(configuration: configuration) { _ in nil }
        super.init()
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    init(fetcher: any URLSessionDataFetching) {
        self.fetcher = fetcher
        super.init()
    }

    func send(_ request: URLRequest) async throws -> HostHTTPTransportResponse {
        let result = try await fetcher.fetch(request)
        let data = result.data
        let response = result.response
        guard let http = response as? HTTPURLResponse,
              let url = http.url else {
            throw HostCapabilityError(code: .network,
                                      message: "the HTTP transport returned no HTTP response")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name] = String(describing: value)
        }
        return HostHTTPTransportResponse(statusCode: http.statusCode,
                                         url: url,
                                         headers: headers,
                                         body: data,
                                         connectedPeerAddress: result.connectedPeerAddress)
    }
}
