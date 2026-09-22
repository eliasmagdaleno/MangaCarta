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

    private func makeArchive(name: String, payload: Data, method: UInt16) -> Data {
        let nameData = Data(name.utf8); let crc = crc32(payload); var out = Data()
        func put16(_ value: UInt16) { out.append(UInt8(value & 255)); out.append(UInt8(value >> 8)) }
        func put32(_ value: UInt32) { put16(UInt16(value & 0xffff)); put16(UInt16(value >> 16)) }
        put32(0x04034b50); put16(20); put16(0); put16(method); put16(0); put16(0); put32(crc); put32(UInt32(payload.count)); put32(UInt32(payload.count)); put16(UInt16(nameData.count)); put16(0); out.append(nameData); out.append(payload)
        let central = out.count; put32(0x02014b50); put16(20); put16(20); put16(0); put16(method); put16(0); put16(0); put32(crc); put32(UInt32(payload.count)); put32(UInt32(payload.count)); put16(UInt16(nameData.count)); put16(0); put16(0); put16(0); put16(0); put32(0); put32(0); out.append(nameData)
        let size = out.count - central; put32(0x06054b50); put16(0); put16(0); put16(1); put16(1); put32(UInt32(size)); put32(UInt32(central)); put16(0)
        return out
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 } }
        return crc ^ 0xffff_ffff
    }
}
