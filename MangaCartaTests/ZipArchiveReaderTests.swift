import Foundation
import XCTest
@testable import MangaCarta

final class ZipArchiveReaderTests: XCTestCase {
    func testStoredRoundTripAndListing() throws {
        let payload = Data([0xff, 0xd8, 0xff, 1, 2, 3])
        let archive = makeArchive(name: "2.jpg", payload: payload, method: 0)
        let reader = try ZipArchiveReader(data: archive)
        XCTAssertEqual(try reader.data(for: reader.listEntries()[0]), payload)
    }

    func testZeroLengthDeflatedEntryReturnsEmptyData() throws {
        let archive = makeArchive(name: "empty.txt", payload: Data(), method: 8, compressedPayload: Data([0x03, 0x00]))
        let reader = try ZipArchiveReader(data: archive)
        XCTAssertEqual(try reader.data(for: reader.listEntries()[0]), Data())
    }

    func testBundledFixturesDecodeAndPreservePageBytes() throws {
        for name in ["deflated.cbz", "stored.zip", "archive-utility.cbz", "zip-command.zip"] {
            let baseName = name.replacingOccurrences(of: ".cbz", with: "").replacingOccurrences(of: ".zip", with: "")
            let extensionName = name.hasSuffix("cbz") ? "cbz" : "zip"
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: baseName, withExtension: extensionName))
            let reader = try ZipArchiveReader(url: url)
            let pages = try reader.chapters().flatMap(\.pages)
            let expectedNames = ["2.jpg", "10.jpg"].sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            XCTAssertEqual(pages.map { URL(fileURLWithPath: $0.name).lastPathComponent }, expectedNames)
            let firstPage = try XCTUnwrap(pages.first)
            for page in [firstPage] + Array(pages.dropFirst()) {
                let expectedPayload: Data
                switch (name, URL(fileURLWithPath: page.name).lastPathComponent) {
                case ("deflated.cbz", _), ("stored.zip", _):
                    expectedPayload = Data([0xff, 0xd8, 0xff] + Array(repeating: 0, count: 64))
                case ("archive-utility.cbz", "2.jpg"), ("zip-command.zip", "2.jpg"):
                    expectedPayload = Data([0xff, 0xd8, 0xff, 1, 2, 3])
                case ("archive-utility.cbz", "10.jpg"), ("zip-command.zip", "10.jpg"):
                    expectedPayload = Data([0xff, 0xd8, 0xff, 4, 5, 6])
                default:
                    XCTFail("unexpected fixture page: \(name)/\(page.name)")
                    continue
                }
                XCTAssertEqual(try reader.data(for: page), expectedPayload)
            }
            if name == "deflated.cbz" {
                XCTAssertTrue(pages.allSatisfy { $0.compressionMethod == 8 })
            } else if name == "stored.zip" {
                XCTAssertTrue(pages.allSatisfy { $0.compressionMethod == 0 })
            }
        }
    }

    func testExtractWritesExactBytesAndRejectsSymlinkEscape() throws {
        let payload = Data([0xff, 0xd8, 0xff, 0x00, 0x7f])
        let reader = try ZipArchiveReader(data: makeArchive(name: "pages/1.jpg", payload: payload, method: 0))
        let entry = try XCTUnwrap(reader.listEntries().first)
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try reader.extract([entry], to: temporaryDirectory)
        XCTAssertEqual(try Data(contentsOf: temporaryDirectory.appendingPathComponent("pages/1.jpg")), payload)

        let outsideDirectory = temporaryDirectory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let symlinkDirectory = temporaryDirectory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: outsideDirectory)
        let escapingReader = try ZipArchiveReader(data: makeArchive(name: "page.jpg", payload: payload, method: 0))
        let escapingEntry = try XCTUnwrap(escapingReader.listEntries().first)

        assertError({ try escapingReader.extract([escapingEntry], to: symlinkDirectory) }, equals: .pathTraversal("page.jpg"))
    }

    func testRequiredArchiveFailures() throws {
        var encrypted = makeArchive(name: "page.jpg", payload: Data([1]), method: 0)
        encrypted[6] = 1; encrypted[7] = 0; encrypted[encrypted.count - 22 - 46 - 8 + 8] = 1
        assertError({ try ZipArchiveReader(data: encrypted) }, equals: .encrypted("page.jpg"))
        var zip64 = makeArchive(name: "page.jpg", payload: Data([1]), method: 0)
        zip64[zip64.count - 22 + 10] = 0xff; zip64[zip64.count - 22 + 11] = 0xff
        assertError({ try ZipArchiveReader(data: zip64) }, equals: .zip64)
        let archive = makeArchive(name: "page.jpg", payload: Data([1]), method: 0)
        assertError({ try ZipArchiveReader(data: Data(archive.dropLast())) }, equals: .truncated)
        var commented = archive; commented[commented.count - 2] = 1; commented.append(0x78)
        assertError({ try ZipArchiveReader(data: commented) }, equals: .corrupt)
        let bombLimits = ZipArchiveReader.Limits(maxCompressionRatio: 1)
        let bomb = makeArchive(name: "page.jpg", payload: Data(repeating: 1, count: 100), method: 8, compressedPayload: Data([3, 0]))
        let bombReader = try ZipArchiveReader(data: bomb, limits: bombLimits)
        assertError({ try bombReader.data(for: bombReader.listEntries()[0]) }, equals: .compressionBomb("page.jpg"))
        let small = ZipArchiveReader.Limits(maxEntryCount: 0)
        assertError({ try ZipArchiveReader(data: archive, limits: small) }, equals: .sizeLimit("archive"))
        let sizeLimit = ZipArchiveReader.Limits(maxEntryUncompressedSize: 0)
        assertError({ try ZipArchiveReader(data: archive, limits: sizeLimit) }, equals: .sizeLimit("page.jpg"))
        let unsupported = makeArchive(name: "page.jpg", payload: Data([1]), method: 99)
        assertError({ try ZipArchiveReader(data: unsupported) }, equals: .unsupportedCompression(method: 99, name: "page.jpg"))
    }

    func testPathValidationRejectsDriveLettersAndNUL() throws {
        for name in ["C:page.jpg", "folder/C:page.jpg", "page\0.jpg"] {
            XCTAssertThrowsError(try ZipArchiveReader(data: makeArchive(name: name, payload: Data([1]), method: 0))) { error in
                guard case ZipArchiveError.pathTraversal(name) = error else { return XCTFail("unexpected error: \(error)") }
            }
        }
    }

    private func assertError<T>(_ result: () throws -> T, equals expected: ZipArchiveError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try result(), file: file, line: line) { error in
            XCTAssertEqual(error as? ZipArchiveError, expected, file: file, line: line)
        }
    }

    func testCRCAndTraversalAreRejected() throws {
        var archive = makeArchive(name: "page.jpg", payload: Data([0xff, 0xd8, 0xff]), method: 0)
        archive[57] ^= 1 // central-directory CRC for the 8-byte "page.jpg" name
        let corrupted = try ZipArchiveReader(data: archive)
        XCTAssertThrowsError(try corrupted.data(for: corrupted.listEntries()[0])) { error in
            guard case ZipArchiveError.corrupt = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try ZipArchiveReader(data: makeArchive(name: "../page.jpg", payload: Data([1]), method: 0))) { error in
            guard case ZipArchiveError.pathTraversal = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testPageFilteringAndChapterGrouping() throws {
        let entries = [
            try entry(name: "chapter 2/10.jpg", payload: [0xff, 0xd8, 0xff]),
            try entry(name: "chapter 2/2.jpg", payload: [0xff, 0xd8, 0xff]),
            try entry(name: "chapter 1/1.JPG", payload: [0xff, 0xd8, 0xff]),
            try entry(name: "__MACOSX/._1.jpg", payload: [0xff, 0xd8, 0xff]),
            try entry(name: ".DS_Store", payload: [0xff, 0xd8, 0xff]),
            try entry(name: "notes.txt", payload: [1, 2])
        ]
        let payloads = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, Data([0xff, 0xd8, 0xff])) })
        let chapters = try PageSelector.chapters(entries: entries) { payloads[$0.name]! }
        XCTAssertEqual(chapters.map(\.name), ["chapter 1", "chapter 2"])
        XCTAssertEqual(chapters[1].pages.map(\.name), ["chapter 2/2.jpg", "chapter 2/10.jpg"])
    }

    private func entry(name: String, payload: [UInt8]) throws -> ZipArchiveReader.Entry {
        try ZipArchiveReader(data: makeArchive(name: name, payload: Data(payload), method: 0)).listEntries()[0]
    }

    private func makeArchive(name: String, payload: Data, method: UInt16, compressedPayload: Data? = nil) -> Data {
        let nameData = Data(name.utf8); let crc = crc32(payload); var out = Data()
        let compressedData = compressedPayload ?? payload
        func put16(_ value: UInt16) { out.append(UInt8(value & 255)); out.append(UInt8(value >> 8)) }
        func put32(_ value: UInt32) { put16(UInt16(value & 0xffff)); put16(UInt16(value >> 16)) }
        put32(0x04034b50); put16(20); put16(0); put16(method); put16(0); put16(0)
        put32(crc); put32(UInt32(compressedData.count)); put32(UInt32(payload.count))
        put16(UInt16(nameData.count)); put16(0); out.append(nameData); out.append(compressedData)
        let central = out.count; put32(0x02014b50); put16(20); put16(20); put16(0)
        put16(method); put16(0); put16(0); put32(crc); put32(UInt32(compressedData.count))
        put32(UInt32(payload.count)); put16(UInt16(nameData.count)); put16(0); put16(0)
        put16(0); put16(0); put32(0); put32(0); out.append(nameData)
        let size = out.count - central; put32(0x06054b50); put16(0); put16(0); put16(1); put16(1); put32(UInt32(size)); put32(UInt32(central)); put16(0)
        return out
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 } }
        return crc ^ 0xffff_ffff
    }
}
