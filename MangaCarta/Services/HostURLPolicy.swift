//
//  HostURLPolicy.swift
//  MangaCarta
//
//  Runtime URL policy shared by HTTP and browser navigation. Manifest membership is
//  necessary but not sufficient: each hop is resolved again before it reaches transport.
//

import Foundation
import Darwin

/// Where the app will send a request at all, independent of whose request it is: an
/// absolute HTTPS URL without credentials whose host resolves only to public addresses.
/// `HostURLPolicy` adds a Source's declared origins on top; repository fetches, which have
/// no declared origins, use this alone.
struct HostDestinationPolicy: Sendable {
    private let resolver: any HostNameResolving

    init(resolver: any HostNameResolving = SystemHostResolver()) {
        self.resolver = resolver
    }

    @discardableResult
    func validate(_ url: URL) async throws -> URL {
        try await validateResolution(of: Self.validatedHost(url))
        return url
    }

    /// The URL-shape half: returns the lowercased host, touching no network.
    static func validatedHost(_ url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !url.isFileURL else {
            throw HostCapabilityError(code: .policyDenied,
                                      message: "only absolute HTTPS URLs without credentials are allowed")
        }
        return host
    }

    /// The DNS half: every address the host resolves to must be public.
    func validateResolution(of host: String) async throws {
        let addresses: [String]
        do {
            addresses = try await resolver.addresses(for: host)
        } catch let error as HostCapabilityError {
            throw error
        } catch {
            throw HostCapabilityError(code: .network,
                                      message: "the destination name could not be resolved")
        }
        guard !addresses.isEmpty else {
            throw HostCapabilityError(code: .network,
                                      message: "the destination name resolved to no addresses")
        }
        guard addresses.allSatisfy(HostIPAddress.isPublic) else {
            throw HostCapabilityError(code: .policyDenied,
                                      message: "the destination resolved to a non-public address")
        }
    }
}

struct HostURLPolicy: Sendable {
    private let origins: Set<String>
    private let destinations: HostDestinationPolicy

    init(allowedOrigins: [String], resolver: any HostNameResolving = SystemHostResolver()) {
        origins = Set(allowedOrigins)
        destinations = HostDestinationPolicy(resolver: resolver)
    }

    /// Shape, then origin membership, then DNS — so a host outside the declared origins is
    /// refused without ever being resolved.
    @discardableResult
    func validate(_ url: URL) async throws -> URL {
        let host = try HostDestinationPolicy.validatedHost(url)
        guard let origin = Self.canonicalOrigin(for: url), origins.contains(origin) else {
            throw HostCapabilityError(code: .policyDenied,
                                      message: "the destination is outside this Source's declared origins")
        }
        try await destinations.validateResolution(of: host)
        return url
    }

    static func canonicalOrigin(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return canonicalOrigin(from: components)
    }

    private static func canonicalOrigin(from components: URLComponents) -> String? {
        guard components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if let port = components.port, port != 443 {
            return "https://\(host):\(port)"
        }
        return "https://\(host)"
    }
}

struct HostBrowserNavigationGuard: Sendable {
    private let policy: HostURLPolicy

    init(allowedOrigins: [String], resolver: any HostNameResolving = SystemHostResolver()) {
        policy = HostURLPolicy(allowedOrigins: allowedOrigins, resolver: resolver)
    }

    func decision(for url: URL) async -> HostBrowserNavigationDecision {
        do {
            try await policy.validate(url)
            return .allow
        } catch let error as HostCapabilityError {
            return .cancel(error)
        } catch {
            return .cancel(HostCapabilityError(code: .network,
                                               message: "browser navigation validation failed"))
        }
    }
}

struct SystemHostResolver: HostNameResolving {
    func addresses(for host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_flags = AI_ADDRCONFIG
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP

                var head: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &head)
                guard status == 0, let first = head else {
                    continuation.resume(throwing: HostCapabilityError(
                        code: .network,
                        message: "the destination name could not be resolved"
                    ))
                    return
                }
                defer { freeaddrinfo(first) }

                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let current = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(current.pointee.ai_addr,
                                   current.pointee.ai_addrlen,
                                   &buffer,
                                   socklen_t(buffer.count),
                                   nil,
                                   0,
                                   NI_NUMERICHOST) == 0 {
                        let address = String(cString: buffer)
                        if !addresses.contains(address) { addresses.append(address) }
                    }
                    cursor = current.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}

enum HostIPAddress {
    private static let nonPublicIPv4Ranges: [ClosedRange<UInt32>] = [
        0x0000_0000...0x00FF_FFFF, // 0.0.0.0/8
        0x0A00_0000...0x0AFF_FFFF, // 10.0.0.0/8
        0x6440_0000...0x647F_FFFF, // 100.64.0.0/10
        0x7F00_0000...0x7FFF_FFFF, // 127.0.0.0/8
        0xA9FE_0000...0xA9FE_FFFF, // 169.254.0.0/16
        0xAC10_0000...0xAC1F_FFFF, // 172.16.0.0/12
        0xC000_0000...0xC000_00FF, // 192.0.0.0/24
        0xC000_0200...0xC000_02FF, // 192.0.2.0/24
        0xC0A8_0000...0xC0A8_FFFF, // 192.168.0.0/16
        0xC612_0000...0xC613_FFFF, // 198.18.0.0/15
        0xC633_6400...0xC633_64FF, // 198.51.100.0/24
        0xCB00_7100...0xCB00_71FF, // 203.0.113.0/24
        0xE000_0000...0xFFFF_FFFF  // multicast and reserved
    ]

    static func isPublic(_ string: String) -> Bool {
        if let bytes = ipv4(string) { return isPublicIPv4(bytes) }
        if let bytes = ipv6(string) { return isPublicIPv6(bytes) }
        return false
    }

    private static func ipv4(_ string: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6(_ string: String) -> [UInt8]? {
        let addressOnly = string.split(separator: "%", maxSplits: 1).first.map(String.init) ?? string
        var address = in6_addr()
        guard inet_pton(AF_INET6, addressOnly, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let address = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return !nonPublicIPv4Ranges.contains { $0.contains(address) }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        if bytes[0] & 0xFE == 0xFC { return false }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
        if bytes[0] == 0xFF { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
            return false
        }
        return true
    }
}
