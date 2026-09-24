//
//  RepositoryTransport.swift
//  MangaCarta
//
//  The network the installer does not own. `RepositoryIndex` and its parser are S2's,
//  in `Models/RepositoryIndex.swift`; this file is only the boundary the installer
//  fetches through. Production composes URLSession with `RepositoryIndexValidator`;
//  tests hand the installer an index directly.
//

import Foundation

enum RepositoryTransportError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case scriptTooLarge(actualBytes: Int, maximumBytes: Int)
    case network(String)
    /// The URL is not one the app will fetch from: not HTTPS, carries credentials, or its
    /// host resolves to a loopback, private, link-local or otherwise non-public address.
    case destinationRefused(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The repository returned an invalid response."
        case .httpStatus(let status):
            return "The repository answered with HTTP status \(status)."
        case .scriptTooLarge(let actual, let maximum):
            return "Bundle script at 'script' is \(actual) bytes; the maximum is \(maximum) bytes."
        case .network:
            return "Couldn't reach the repository. Check the URL and your connection, then try again."
        case .destinationRefused(let reason):
            return "This repository address can't be used: \(reason)."
        }
    }
}

/// What an index fetch came back with.
enum RepositoryIndexFetchOutcome: Equatable, Sendable {
    case index(RepositoryIndex)
    /// The host answered a permanent redirect (301/308). Per the design's "What keeps an
    /// identity" table the installer applies nothing until the reader confirms the new
    /// URL is theirs to trust; the stored URL is unchanged and the redirected index is not
    /// applied.
    case movedPermanently(to: URL)
}

/// Bounds on index and script size are the transport's — `RepositoryFormatLimits`, which
/// are tunables under the design's "Bounds" evidence gate.
protocol RepositoryTransport: Sendable {
    /// Fetches and parses the index at exactly `url` — nothing appended or guessed. An
    /// index-level rejection is thrown as the parser's own located error.
    func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome
    /// Fetches a bundle's script bytes as served. The digest check is the installer's.
    func fetchScript(at url: URL) async throws -> Data
}

/// Production repository fetcher. Parsing stays at the transport boundary so the
/// installer never receives an unchecked index; bundle hashes remain the installer's job.
final class URLSessionRepositoryTransport: RepositoryTransport, @unchecked Sendable {
    private let fetcher: any URLSessionDataFetching
    private let destinations: HostDestinationPolicy
    let sessionConfiguration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration? = nil,
         resolver: any HostNameResolving = SystemHostResolver(),
         fetcher: (any URLSessionDataFetching)? = nil) {
        self.destinations = HostDestinationPolicy(resolver: resolver)
        let base = configuration ?? Self.sessionConfiguration()
        let sessionConfiguration = base.copy() as! URLSessionConfiguration
        sessionConfiguration.connectionProxyDictionary = [:]
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpCookieStorage = nil
        self.sessionConfiguration = sessionConfiguration
        self.fetcher = fetcher ?? URLSessionDataFetcher(
            configuration: sessionConfiguration,
            redirectHandler: URLSessionDataFetcher.httpsOnlyRedirectHandler)
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return configuration
    }

    func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome {
        let (data, response) = try await fetch(url)
        if response.statusCode == 301 || response.statusCode == 308,
           let location = response.value(forHTTPHeaderField: "Location"),
           let destination = URL(string: location, relativeTo: url)?.absoluteURL {
            return .movedPermanently(to: destination)
        }
        try requireSuccess(response)
        switch RepositoryIndexValidator.validate(json: data, indexURL: url) {
        case .success(let index): return .index(index)
        case .failure(let error): throw error
        }
    }

    func fetchScript(at url: URL) async throws -> Data {
        let (data, response) = try await fetch(url)
        try requireSuccess(response)
        guard data.count <= RepositoryFormatLimits.maximumScriptBytes else {
            throw RepositoryTransportError.scriptTooLarge(
                actualBytes: data.count,
                maximumBytes: RepositoryFormatLimits.maximumScriptBytes)
        }
        return data
    }

    /// Every fetch passes the destination policy first — the index URL the reader typed or
    /// confirmed, and every script URL an index names. Redirects are never followed by the
    /// transport, so the URL checked here is the only one requested; a
    /// permanent redirect's target is checked when the confirmed URL is fetched in turn.
    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            try await destinations.validate(url)
        } catch let error as HostCapabilityError where error.code == .policyDenied {
            throw RepositoryTransportError.destinationRefused(error.message)
        } catch {
            throw RepositoryTransportError.network(error.localizedDescription)
        }
        do {
            let result = try await fetcher.fetch(URLRequest(url: url))
            let data = result.data
            let response = result.response
            guard let response = response as? HTTPURLResponse else {
                throw RepositoryTransportError.invalidResponse
            }
            guard let peer = result.connectedPeerAddress, HostIPAddress.isPublic(peer) else {
                throw RepositoryTransportError.destinationRefused(
                    "the connected destination was non-public")
            }
            return (data, response)
        } catch let error as RepositoryTransportError {
            throw error
        } catch {
            throw RepositoryTransportError.network(error.localizedDescription)
        }
    }

    private func requireSuccess(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw RepositoryTransportError.httpStatus(response.statusCode)
        }
    }
}
