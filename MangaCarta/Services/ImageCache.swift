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

/// Signals the image fetcher hit a rate-limit response worth backing off on.
enum ImageFetchError: Error { case rateLimited }

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

    private let memory = NSCache<NSURL, UIImage>()
    private let disk: ImageDiskCache
    private let destinationPolicy: HostDestinationPolicy
    private let fetch: @Sendable (URL) async throws -> Data
    private let maxConcurrentPrefetch = 5
    private let retryBaseDelay: TimeInterval
    private let maxImageRetries: Int

    /// - Parameters:
    ///   - directory: Disk cache location (defaults to `Caches/PageImageCache`).
    ///   - memoryLimitBytes: `NSCache` total cost limit.
    ///   - diskLimitBytes: Disk cap enforced by `trim()`.
    ///   - retryBaseDelay: Base delay for exponential backoff on rate-limit retries.
    ///   - maxImageRetries: Maximum number of retries on rate-limit errors.
    ///   - fetcher: Network fetch (injectable for tests). Defaults to `URLSession.shared`.
    init(directory: URL? = nil,
         memoryLimitBytes: Int = 100 * 1024 * 1024,
         diskLimitBytes: Int = 500 * 1024 * 1024,
         retryBaseDelay: TimeInterval = 0.5,
         maxImageRetries: Int = 2,
         resolver: any HostNameResolving = SystemHostResolver(),
         fetcher: (@Sendable (URL) async throws -> Data)? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PageImageCache")
        self.disk = ImageDiskCache(directory: dir, maxBytes: diskLimitBytes)
        self.destinationPolicy = HostDestinationPolicy(resolver: resolver)
        self.memory.totalCostLimit = memoryLimitBytes
        self.retryBaseDelay = retryBaseDelay
        self.maxImageRetries = maxImageRetries
        self.fetch = fetcher ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 429 || http.statusCode == 503 {
                throw ImageFetchError.rateLimited
            }
            return data
        }
        Task { await disk.trim() }   // enforce the cap on startup
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
    func loadImage(for url: URL) async -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
            memory.setObject(img, forKey: url as NSURL, cost: data.count)
            return img
        }
        let key = Self.key(for: url)
        if let data = await disk.data(for: key), let img = UIImage(data: data) {
            memory.setObject(img, forKey: url as NSURL, cost: data.count)
            return img
        }
        guard (try? await destinationPolicy.validate(url)) != nil else { return nil }
        var attempt = 0
        while true {
            do {
                let data = try await fetch(url)
                guard let img = UIImage(data: data) else { return nil }
                memory.setObject(img, forKey: url as NSURL, cost: data.count)
                await disk.store(data, for: key)
                return img
            } catch ImageFetchError.rateLimited where attempt < maxImageRetries {
                try? await Task.sleep(for: .seconds(Self.imageBackoffDelay(attempt: attempt, base: retryBaseDelay)))
                attempt += 1
            } catch {
                return nil
            }
        }
    }

    func prefetch(_ urls: [URL], maxConcurrent: Int? = nil) {
        Task.detached(priority: .utility) { [self] in
            await prefetchAwaitable(urls, maxConcurrent: maxConcurrent)
        }
    }

    /// Awaitable form of `prefetch` (used by tests). `maxConcurrent` nil → default width.
    func prefetchAwaitable(_ urls: [URL], maxConcurrent: Int? = nil) async {
        let width = max(1, maxConcurrent ?? maxConcurrentPrefetch)
        await withTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask { [self] in
                    if memory.object(forKey: url as NSURL) != nil { return }
                    _ = await loadImage(for: url)
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
