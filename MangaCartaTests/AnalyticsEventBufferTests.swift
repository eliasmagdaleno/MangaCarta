import Foundation

// swiftlint:disable:next blanket_disable_command
// swiftlint:disable line_length
import XCTest
@testable import MangaCarta

@MainActor
final class AnalyticsEventBufferTests: XCTestCase {
    func testCapDropsOldest() throws {
        let directory = makeTestDirectory("analytics-buffer")
        let id = UUID()
        for index in 0..<505 {
            let buffer = index == 0 ? AnalyticsEventBuffer(directory: directory) : AnalyticsEventBuffer(directory: directory)
            buffer.append(AnalyticsEnvelope(install: id, date: Date(timeIntervalSince1970: TimeInterval(index)), app: "app", event: .forYouShown(count: index)))
        }
        let buffer = AnalyticsEventBuffer(directory: directory)
        XCTAssertEqual(buffer.events.count, 500)
        XCTAssertEqual(buffer.events.first?.event, .forYouShown(count: 5))
        XCTAssertEqual(buffer.events.last?.event, .forYouShown(count: 504))
    }

    func testCorruptFileStartsEmpty() throws {
        let directory = makeTestDirectory("analytics-buffer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("buffer.json"))
        let buffer = AnalyticsEventBuffer(directory: directory)
        XCTAssertTrue(buffer.events.isEmpty)
        buffer.append(AnalyticsEnvelope(install: UUID(), date: Date(), app: "app", event: .appActive))
        XCTAssertNoThrow(try JSONDecoder().decode([AnalyticsEnvelope].self, from: Data(contentsOf: directory.appendingPathComponent("buffer.json"))))
    }

    func testInstallIDIsNotMintedUntilAsked() {
        let directory = makeTestDirectory("analytics-buffer")
        let buffer = AnalyticsEventBuffer(directory: directory)
        XCTAssertNil(buffer.installID)
        let id = buffer.mintInstallIDIfNeeded()
        XCTAssertEqual(buffer.installID, id)
        XCTAssertEqual(buffer.mintInstallIDIfNeeded(), id)
    }

    func testEraseAllRemovesEveryFile() {
        let directory = makeTestDirectory("analytics-buffer")
        let buffer = AnalyticsEventBuffer(directory: directory)
        buffer.append(AnalyticsEnvelope(install: UUID(), date: Date(), app: "app", event: .appActive))
        _ = buffer.mintInstallIDIfNeeded()
        try? Data("ledger".utf8).write(to: directory.appendingPathComponent("ledger.json"))
        buffer.eraseAll()
        XCTAssertTrue(buffer.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("buffer.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("install.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ledger.json").path))
    }
}
