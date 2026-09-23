import Compression
import Foundation

public enum ZipArchiveError: Error, Equatable {
    case truncated
    case corrupt
    case zip64
    case encrypted(String)
    case unsupportedCompression(method: UInt16, name: String)
    case pathTraversal(String)
    case sizeLimit(String)
    case compressionBomb(String)
    case invalidImage(String)
}

public struct ZipArchiveReader: Sendable {
    public struct Limits: Sendable {
        public var maxEntryCount: Int
        public var maxTotalUncompressedSize: UInt64
        public var maxEntryUncompressedSize: UInt64
        public var maxCompressionRatio: UInt64
        public var maxArchiveSize: UInt64

        public init(maxEntryCount: Int = 10_000, maxTotalUncompressedSize: UInt64 = 512 * 1024 * 1024,
                    maxEntryUncompressedSize: UInt64 = 128 * 1024 * 1024,
                    maxCompressionRatio: UInt64 = 10_000,
                    maxArchiveSize: UInt64 = 512 * 1024 * 1024) {
            self.maxEntryCount = maxEntryCount
            self.maxTotalUncompressedSize = maxTotalUncompressedSize
            self.maxEntryUncompressedSize = maxEntryUncompressedSize
            self.maxCompressionRatio = maxCompressionRatio
            self.maxArchiveSize = maxArchiveSize
        }
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let compressionMethod: UInt16
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let crc32: UInt32
        fileprivate let localHeaderOffset: UInt64
        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public struct Chapter: Sendable, Equatable {
        public let name: String
        public let pages: [Entry]
    }

    private let bytes: Data
    public let limits: Limits
    private let entries: [Entry]

    public init(data: Data, limits: Limits = Limits()) throws {
        guard UInt64(data.count) <= limits.maxArchiveSize else { throw ZipArchiveError.sizeLimit("archive") }
        self.bytes = data
        self.limits = limits
        self.entries = try Self.parse(data: data, limits: limits)
    }

    public init(url: URL, limits: Limits = Limits()) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, UInt64(fileSize) <= limits.maxArchiveSize else {
            throw ZipArchiveError.sizeLimit("archive")
        }
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), limits: limits)
    }

    public func listEntries() -> [Entry] { entries }

    public func data(for entry: Entry) throws -> Data {
        guard !entry.isDirectory else { return Data() }
        guard entry.uncompressedSize <= limits.maxEntryUncompressedSize else { throw ZipArchiveError.sizeLimit(entry.name) }
        guard entry.compressedSize > 0 || entry.uncompressedSize == 0 else { throw ZipArchiveError.truncated }
        let local = try readUInt32(at: entry.localHeaderOffset)
        guard local == 0x04034b50 else { throw ZipArchiveError.corrupt }
        guard entry.localHeaderOffset <= UInt64(bytes.count), entry.localHeaderOffset + 30 <= UInt64(bytes.count) else {
            throw ZipArchiveError.truncated
        }
        let nameLength = Int(try readUInt16(at: entry.localHeaderOffset + 26))
        let extraLength = Int(try readUInt16(at: entry.localHeaderOffset + 28))
        let start = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        let end = start + entry.compressedSize
        guard end <= UInt64(bytes.count), start <= end else { throw ZipArchiveError.truncated }
        let compressed = bytes[Int(start)..<Int(end)]
        if entry.uncompressedSize == 0 {
            guard entry.crc32 == CRC32.checksum(Data()) else { throw ZipArchiveError.corrupt }
            return Data()
        }
        let output: Data
        switch entry.compressionMethod {
        case 0:
            output = Data(compressed)
        case 8:
            guard entry.compressedSize == 0 || entry.uncompressedSize / entry.compressedSize <= limits.maxCompressionRatio else {
                throw ZipArchiveError.compressionBomb(entry.name)
            }
            var result = Data(count: Int(entry.uncompressedSize))
            let decoded = result.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(destinationBase, Int(entry.uncompressedSize), sourceBase,
                                                     Int(entry.compressedSize), nil, COMPRESSION_ZLIB)
                }
            }
            guard decoded == entry.uncompressedSize else { throw ZipArchiveError.corrupt }
            output = result
        default:
            throw ZipArchiveError.unsupportedCompression(method: entry.compressionMethod, name: entry.name)
        }
        guard CRC32.checksum(output) == entry.crc32 else { throw ZipArchiveError.corrupt }
        return output
    }

    public func extract(_ selected: [Entry], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in selected where !entry.isDirectory {
            try Self.validatePath(entry.name)
            let destination = directory.appendingPathComponent(entry.name)
            let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
            let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
            let directoryPrefix = resolvedDirectory.path.hasSuffix("/") ? resolvedDirectory.path : resolvedDirectory.path + "/"
            guard resolvedDestination.path.hasPrefix(directoryPrefix) else { throw ZipArchiveError.pathTraversal(entry.name) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data(for: entry).write(to: destination, options: .atomic)
        }
    }

    public func chapters() throws -> [Chapter] {
        let pages = try PageSelector.chapters(entries: entries) { try self.prefixData(for: $0, maxLength: 16) }
        return pages
    }

    private func prefixData(for entry: Entry, maxLength: Int) throws -> Data {
        if entry.uncompressedSize == 0 { return Data() }
        if entry.compressionMethod == 0 {
            let full = try data(for: entry)
            return Data(full.prefix(maxLength))
        }
        // Header sniffing only needs a few bytes; avoid allocating the declared output size.
        guard entry.compressionMethod == 8 else { throw ZipArchiveError.unsupportedCompression(method: entry.compressionMethod, name: entry.name) }
        guard entry.compressedSize > 0, entry.uncompressedSize / entry.compressedSize <= limits.maxCompressionRatio else {
            throw ZipArchiveError.compressionBomb(entry.name)
        }
        let local = try readUInt32(at: entry.localHeaderOffset)
        guard local == 0x04034b50 else { throw ZipArchiveError.corrupt }
        let nameLength = Int(try readUInt16(at: entry.localHeaderOffset + 26))
        let extraLength = Int(try readUInt16(at: entry.localHeaderOffset + 28))
        let start = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        let end = start + entry.compressedSize
        guard end <= UInt64(bytes.count), start <= end else { throw ZipArchiveError.truncated }
        let source = bytes[Int(start)..<Int(end)]
        var output = Data(count: min(maxLength, Int(entry.uncompressedSize)))
        let outputLength = output.count
        let emptyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let emptySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { emptyDestination.deallocate(); emptySource.deallocate() }
        var stream = compression_stream(dst_ptr: emptyDestination, dst_size: 0, src_ptr: emptySource, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipArchiveError.corrupt }
        defer { compression_stream_destroy(&stream) }
        return try output.withUnsafeMutableBytes { destination in
            try source.withUnsafeBytes { compressed in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = compressed.bindMemory(to: UInt8.self).baseAddress else { throw ZipArchiveError.corrupt }
                stream.dst_ptr = dst; stream.dst_size = outputLength; stream.src_ptr = src; stream.src_size = source.count
                while stream.dst_size > 0 {
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if status == COMPRESSION_STATUS_ERROR { throw ZipArchiveError.corrupt }
                    if status == COMPRESSION_STATUS_END || stream.dst_size == 0 { break }
                    if stream.src_size == 0 { throw ZipArchiveError.truncated }
                }
                return Data(bytes: dst, count: outputLength - stream.dst_size)
            }
        }
    }

    private func readUInt16(at offset: UInt64) throws -> UInt16 {
        guard offset + 2 <= UInt64(bytes.count) else { throw ZipArchiveError.truncated }
        let i = Int(offset); return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
    }
    private func readUInt32(at offset: UInt64) throws -> UInt32 {
        guard offset + 4 <= UInt64(bytes.count) else { throw ZipArchiveError.truncated }
        let i = Int(offset); return UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }

    private static func parse(data: Data, limits: Limits) throws -> [Entry] {
        let min = max(0, data.count - 65_557); var eocd: Int?
        if data.count >= 22 {
            for i in stride(from: data.count - 22, through: min, by: -1)
                where data[i] == 0x50 && data[i + 1] == 0x4b && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                eocd = i; break
            }
        }
        guard let e = eocd else { throw ZipArchiveError.truncated }
        func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24 }
        let commentLength = Int(u16(e + 20))
        guard e + 22 + commentLength == data.count else { throw ZipArchiveError.truncated }
        guard commentLength == 0 else { throw ZipArchiveError.corrupt }
        let count = Int(u16(e + 10)); let size = UInt64(u32(e + 12)); let offset = UInt64(u32(e + 16))
        guard count != 0xffff && size != 0xffff_ffff && offset != 0xffff_ffff else { throw ZipArchiveError.zip64 }
        guard count <= limits.maxEntryCount else { throw ZipArchiveError.sizeLimit("archive") }
        guard offset + size <= UInt64(e) else { throw ZipArchiveError.truncated }
        var cursor = Int(offset); var result: [Entry] = []; var total: UInt64 = 0
        for _ in 0..<count {
            guard cursor + 46 <= data.count, u32(cursor) == 0x02014b50 else { throw ZipArchiveError.corrupt }
            let flags = u16(cursor + 8); let method = u16(cursor + 10); let crc = u32(cursor + 16)
            let compressed = UInt64(u32(cursor + 20)); let uncompressed = UInt64(u32(cursor + 24))
            let nameLength = Int(u16(cursor + 28)); let extraLength = Int(u16(cursor + 30)); let commentLength = Int(u16(cursor + 32))
            let localOffset = UInt64(u32(cursor + 42)); let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= data.count else { throw ZipArchiveError.truncated }
            let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if flags & 1 != 0 { throw ZipArchiveError.encrypted(name) }
            if compressed == 0xffff_ffff || uncompressed == 0xffff_ffff || localOffset == 0xffff_ffff { throw ZipArchiveError.zip64 }
            try validatePath(name)
            guard method == 0 || method == 8 else { throw ZipArchiveError.unsupportedCompression(method: method, name: name) }
            guard uncompressed <= limits.maxEntryUncompressedSize else { throw ZipArchiveError.sizeLimit(name) }
            total += uncompressed; guard total <= limits.maxTotalUncompressedSize else { throw ZipArchiveError.sizeLimit(name) }
            result.append(Entry(name: name, compressionMethod: method, compressedSize: compressed, uncompressedSize: uncompressed, crc32: crc, localHeaderOffset: localOffset)); cursor = end
        }
        return result
    }

    private static func validatePath(_ name: String) throws {
        let components = name.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let hasDriveLetter = components.contains {
            $0.count >= 2 && $0[$0.index($0.startIndex, offsetBy: 1)] == ":" && $0.first?.isLetter == true
        }
        if name.unicodeScalars.contains(where: { $0.value == 0 }) || name.hasPrefix("/") || name.hasPrefix("\\") || hasDriveLetter || components.contains("..") {
            throw ZipArchiveError.pathTraversal(name)
        }
    }
}

public enum PageSelector {
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif"]

    public static func chapters(entries: [ZipArchiveReader.Entry], data: (ZipArchiveReader.Entry) throws -> Data) throws -> [ZipArchiveReader.Chapter] {
        let candidates = try entries.filter { entry in
            guard !entry.isDirectory else { return false }
            let components = entry.name.split(separator: "/").map(String.init)
            guard !components.contains(where: { $0 == "__MACOSX" || $0 == ".DS_Store" || $0 == "Thumbs.db" || $0.hasPrefix(".") }) else { return false }
            guard let extPart = components.last?.split(separator: ".").last else { return false }
            let ext = String(extPart).lowercased()
            guard extensions.contains(ext) else { return false }
            return magicMatches(data: try data(entry), extension: ext)
        }.sorted { naturalCompare($0.name, $1.name) }
        let groups = Dictionary(grouping: candidates) { entry -> String in
            let parts = entry.name.split(separator: "/"); return parts.count > 1 ? String(parts[0]) : ""
        }
        return groups.keys.sorted { naturalCompare($0, $1) }.compactMap { key in
            guard let values = groups[key], !values.isEmpty else { return nil }
            return ZipArchiveReader.Chapter(name: key.isEmpty ? "Root" : key, pages: values)
        }
    }

    private static func magicMatches(data: Data, extension ext: String) -> Bool {
        if ext == "jpg" || ext == "jpeg" { return data.count >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff }
        if ext == "png" { return data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) }
        if ext == "gif" { return data.starts(with: [0x47, 0x49, 0x46, 0x38]) }
        if ext == "webp" { return data.count >= 12 && data[0..<4] == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8) }
        if ext == "avif" { return data.count >= 12 && data[4..<8] == Data("ftyp".utf8) }
        return false
    }

    private static func naturalCompare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 } }
        return crc ^ 0xffff_ffff
    }
}
