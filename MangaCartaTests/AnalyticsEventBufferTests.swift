import Foundation
import XCTest
@testable import MangaCarta

@MainActor
final class AnalyticsEventBufferTests: XCTestCase {
    func testCapDropsOldest() throws {
        let directory = makeTestDirectory("analytics-buffer")
        let id = UUID()
        let buffer = AnalyticsEventBuffer(directory: directory)
        for index in 0..<505 {
            buffer.append(AnalyticsEnvelope(
                install: id, date: Date(timeIntervalSince1970: TimeInterval(index)), app: "app",
                event: .forYouShown(count: index)
            ))
        }
        let reloaded = AnalyticsEventBuffer(directory: directory)
        XCTAssertEqual(reloaded.events.count, 500)
        XCTAssertEqual(reloaded.events.first?.event, AnalyticsEvent.forYouShown(count: 5))
        XCTAssertEqual(reloaded.events.last?.event, AnalyticsEvent.forYouShown(count: 504))
    }

    func testCorruptFileStartsEmpty() throws {
        let directory = makeTestDirectory("analytics-buffer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("buffer.json"))
        let buffer = AnalyticsEventBuffer(directory: directory)
        XCTAssertTrue(buffer.events.isEmpty)
        buffer.append(AnalyticsEnvelope(install: UUID(), date: Date(), app: "app", event: .appActive))
        let data = try Data(contentsOf: directory.appendingPathComponent("buffer.json"))
        XCTAssertNoThrow(try JSONDecoder().decode(
            [AnalyticsEnvelope].self,
            from: data
        ))
    }

    func testInstallIDIsNotMintedUntilAsked() {
        let directory = makeTestDirectory("analytics-buffer")
        let buffer = AnalyticsEventBuffer(directory: directory)
        XCTAssertNil(buffer.installID)
        let id = buffer.mintInstallIDIfNeeded()
        XCTAssertEqual(buffer.installID, id)
        XCTAssertEqual(buffer.mintInstallIDIfNeeded(), id)
    }

    func testEveryEventSurvivesReload() {
        let directory = makeTestDirectory("analytics-buffer")
        let install = UUID()
        let ids = CatalogueIDs(mal: 21, anilist: 30013)
        let events: [AnalyticsEvent] = [
            .workSaved(ids), .workUnsaved(ids), .chapterCompleted(ids, progress: 12),
            .recNotInterested(ids), .recMoreLikeThis(ids), .forYouOpened(ids, rank: 2, reason: .tag),
            .forYouShown(count: 6), .mltOpened(from: ids, to: CatalogueIDs(mal: 30, anilist: nil)),
            .appActive, .readerOpened(.rtl), .searchUsed, .localImportFinished(.twoToNine),
            .sourceInstalled(.mixed), .settingChanged(.notifications, .on(true)),
            .settingChanged(.malSync, .on(false)), .settingChanged(.readingModeDefault, .readingMode(.vertical)),
            .analyticsEnabled
        ]
        let buffer = AnalyticsEventBuffer(directory: directory)
        events.forEach { buffer.append(AnalyticsEnvelope(install: install, date: Date(), app: "app", event: $0)) }
        XCTAssertEqual(AnalyticsEventBuffer(directory: directory).events.map(\.event), events)
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
