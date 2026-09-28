//
//  ImageCache.swift
//  MangaCarta
//
//  A small dependency-free image cache for reader pages: an in-memory `NSCache`
//  of decoded images backed by a persistent on-disk byte cache, plus a prefetch
//  API used to warm the current chapter so scrolling is instant.
//
//  Lookup order is memory → disk → network, populating the faster tiers on the
//  way back. The disk tier is an `actor` so file I/O stays off the main thread.
//
//  This is URL-keyed, which serves any source that hands the reader real image
//  URLs (MangaDex, and later WeebCentral / other sources). A future source whose pages
//  are transformed on-device (comix.to's descrambled bitmaps) will cache its
//  final image through the same memory tier, keyed by a post-transform identity.
//

import Foundation
import UIKit
import CryptoKit
import os

/// Signals the image fetcher hit a rate-limit response worth backing off on.
enum ImageFetchError: Error {
    case rateLimited
    case destinationRefused
    case invalidResponse
}

/// One network retrieval's bytes, plus what an image-load report needs from its response.
struct ImageFetchOutcome: Sendable {
    let data: Data
    /// The response's `X-Cache` starts with `HIT` (MangaDex's definition of `cached`).
    let cacheHit: Bool
}

// MARK: - Disk tier

/// Persistent on-disk byte cache with a size cap. Keys are opaque strings
/// (SHA-256 of the URL); values are raw image bytes. Actor-isolated so all file
/// I/O is serialized off the main thread.
actor ImageDiskCache {
    private let directory: URL
    private let maxBytes: Int
    private let fm = FileManager.default

    init(directory: URL, maxBytes: Int) {
        self.directory = directory
        self.maxBytes = maxBytes
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(key)
    }

    func has(_ key: String) -> Bool {
        fm.fileExists(atPath: fileURL(key).path)
    }

    /// Returns the bytes for `key`, touching its modification date so recently
    /// read files are treated as fresh by `trim()`.
    func data(for key: String) -> Data? {
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func store(_ data: Data, for key: String) {
        try? data.write(to: fileURL(key), options: .atomic)
    }

    func clear() {
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Total bytes currently on disk (test/introspection helper).
    func totalBytes() -> Int {
        contents().reduce(0) { $0 + $1.size }
    }

    /// If over the cap, delete oldest-by-modification-date files until under 80%.
    func trim() {
        var files = contents()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        let target = maxBytes * 8 / 10
        files.sort { $0.modified < $1.modified }   // oldest first
        for file in files {
            if total <= target { break }
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }

    private struct Entry { let url: URL; let size: Int; let modified: Date }

    private func contents() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let size = v.fileSize,
                  let modified = v.contentModificationDate else { return nil }
            return Entry(url: url, size: size, modified: modified)
        }
    }
}

// MARK: - Image cache

/// Memory + disk image cache with a prefetch API. Thread-safe by construction
/// (`NSCache` is thread-safe, disk I/O is actor-isolated, `fetch` is immutable),
/// so it is safe to treat as `@unchecked Sendable`.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private static let log = Logger(subsystem: "Elias-Magdaleno.Manga-Reader", category: "ImageCache")

    private let memory = NSCache<NSURL, UIImage>()
    private let disk: ImageDiskCache
    private let destinationPolicy: HostDestinationPolicy
    private let fetch: @Sendable (URL) async throws -> ImageFetchOutcome
    private let reporter: any ImageLoadReporting
    /// Monotonic seconds, injected so a report's duration is testable.
    private let uptime: @Sendable () -> TimeInterval
    private let decode: @Sendable (Data) -> UIImage?
    private let maxConcurrentPrefetch = 5
    private let retryBaseDelay: TimeInterval
    private let maxImageRetries: Int

    /// - Parameters:
    ///   - directory: Disk cache location (defaults to `Caches/PageImageCache`).
    ///   - memoryLimitBytes: `NSCache` total cost limit.
    ///   - diskLimitBytes: Disk cap enforced by `trim()`.
    ///   - retryBaseDelay: Base delay for exponential backoff on rate-limit retries.
    ///   - maxImageRetries: Maximum number of retries on rate-limit errors.
    ///   - fetcher: Raw network fetch override for existing tests.
    ///   - sessionFetcher: URLSession transport override for peer-policy tests.
    ///   - reporter: Receives image-load reports (ADR-0003 Amendment 9).
    ///   - uptime: Monotonic clock for report durations.
    init(directory: URL? = nil,
         memoryLimitBytes: Int = 100 * 1024 * 1024,
         diskLimitBytes: Int = 500 * 1024 * 1024,
         retryBaseDelay: TimeInterval = 0.5,
         maxImageRetries: Int = 2,
         resolver: any HostNameResolving = SystemHostResolver(),
         fetcher: (@Sendable (URL) async throws -> Data)? = nil,
         sessionFetcher: (any URLSessionDataFetching)? = nil,
         reporter: any ImageLoadReporting = NoImageLoadReports(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         decoder: @escaping @Sendable (Data) -> UIImage? = { UIImage(data: $0) }) {
        let dir = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PageImageCache")
        self.disk = ImageDiskCache(directory: dir, maxBytes: diskLimitBytes)
        self.destinationPolicy = HostDestinationPolicy(resolver: resolver)
        self.memory.totalCostLimit = memoryLimitBytes
        self.retryBaseDelay = retryBaseDelay
        self.maxImageRetries = maxImageRetries
        self.decode = decoder
        self.reporter = reporter
        self.uptime = uptime
        let guardedFetcher = sessionFetcher ?? URLSessionDataFetcher(
            configuration: Self.sessionConfiguration(),
            redirectHandler: URLSessionDataFetcher.httpsOnlyRedirectHandler)
        if let fetcher {
            // The raw-bytes test seam carries no response headers, so nothing it returns is a hit.
            self.fetch = { ImageFetchOutcome(data: try await fetcher($0), cacheHit: false) }
        } else {
            self.fetch = { url in
                let result = try await guardedFetcher.fetch(URLRequest(url: url))
                guard result.resourceFetchType != .localCache,
                      let peer = result.connectedPeerAddress,
                      HostIPAddress.isPublic(peer) else {
                    throw ImageFetchError.destinationRefused
                }
                guard let http = result.response as? HTTPURLResponse, http.url == url else {
                    throw ImageFetchError.invalidResponse
                }
                if http.statusCode == 429 || http.statusCode == 503 {
                    throw ImageFetchError.rateLimited
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ImageFetchError.invalidResponse
                }
                let xCache = http.value(forHTTPHeaderField: "X-Cache") ?? ""
                return ImageFetchOutcome(data: result.data,
                                         cacheHit: xCache.uppercased().hasPrefix("HIT"))
            }
        }
        Task { await disk.trim() }   // enforce the cap on startup
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Exponential backoff schedule for image retries: `base * 2^attempt`.
    static func imageBackoffDelay(attempt: Int, base: TimeInterval) -> TimeInterval {
        base * pow(2.0, Double(attempt))
    }

    /// Stable disk key for a URL.
    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Memory-only peek — non-blocking; returns a decoded image if already resident.
    func image(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Full resolve: memory → disk → network, populating the faster tiers.
    /// - Parameter reportTarget: the Source this load is for, when it wants image-load
    ///   reports. Only network retrievals of a URL the target covers are reported.
    func loadImage(for url: URL, reportTarget: ImageLoadReportTarget? = nil) async -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url), let img = decode(data) else { return nil }
            memory.setObject(img, forKey: url as NSURL, cost: data.count)
            return img
        }
        let key = Self.key(for: url)
        if let data = await disk.data(for: key), let img = decode(data) {
            memory.setObject(img, forKey: url as NSURL, cost: data.count)
            return img
        }
        guard (try? await destinationPolicy.validate(url)) != nil else {
#if DEBUG
            Self.log.debug("Image load refused by destination policy: \(url.absoluteString, privacy: .public)")
#endif
            return nil
        }
        let reportTarget = reportTarget.flatMap { $0.covers(url) ? $0 : nil }
        var attempt = 0
        while true {
            let started = uptime()
            do {
                let outcome = try await fetch(url)
                // Reported before decoding: `success` is the retrieval, not the image.
                report(url, to: reportTarget, outcome: outcome, started: started)
                guard let img = decode(outcome.data) else { return nil }
                memory.setObject(img, forKey: url as NSURL, cost: outcome.data.count)
                await disk.store(outcome.data, for: key)
                return img
            } catch ImageFetchError.rateLimited where attempt < maxImageRetries {
                report(url, to: reportTarget, outcome: nil, started: started)
                try? await Task.sleep(for: .seconds(Self.imageBackoffDelay(attempt: attempt, base: retryBaseDelay)))
                attempt += 1
            } catch {
                if Self.isNodeFailure(error) {
                    report(url, to: reportTarget, outcome: nil, started: started)
                }
                return nil
            }
        }
    }

    /// `outcome` is the retrieval's result, or `nil` when the attempt failed.
    private func report(_ url: URL, to target: ImageLoadReportTarget?,
                        outcome: ImageFetchOutcome?, started: TimeInterval) {
        guard let target else { return }
        let milliseconds = Int(((uptime() - started) * 1000).rounded())
        reporter.report(ImageLoadReport(url: url, success: outcome != nil,
                                        cached: outcome?.cacheHit ?? false,
                                        bytes: outcome?.data.count ?? 0,
                                        durationMilliseconds: max(0, milliseconds)),
                        to: target)
    }

    /// A failure that says something about the image server. Cancellation is the reader
    /// moving on, and a refused peer is the host's own policy firing; neither is the node's.
    private static func isNodeFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        if case ImageFetchError.destinationRefused = error { return false }
        return true
    }

    func prefetch(_ urls: [URL], maxConcurrent: Int? = nil,
                  reportTarget: ImageLoadReportTarget? = nil) {
        Task.detached(priority: .utility) { [self] in
            await prefetchAwaitable(urls, maxConcurrent: maxConcurrent, reportTarget: reportTarget)
        }
    }

    /// Awaitable form of `prefetch` (used by tests). `maxConcurrent` nil → default width.
    func prefetchAwaitable(_ urls: [URL], maxConcurrent: Int? = nil,
                           reportTarget: ImageLoadReportTarget? = nil) async {
        let width = max(1, maxConcurrent ?? maxConcurrentPrefetch)
        await withTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask { [self] in
                    if memory.object(forKey: url as NSURL) != nil { return }
                    _ = await loadImage(for: url, reportTarget: reportTarget)
                }
            }
            for _ in 0..<width { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    /// Drop everything (memory immediately, disk asynchronously).
    func clear() {
        memory.removeAllObjects()
        Task { await disk.clear() }
    }

    /// Test hook: run a disk trim and wait for it.
    func trimDiskNow() async { await disk.trim() }
}
