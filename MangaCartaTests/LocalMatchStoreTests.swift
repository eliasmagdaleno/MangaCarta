import XCTest
@testable import MangaCarta

@MainActor
final class LocalMatchStoreTests: XCTestCase {
    func testConfirmedMatchRoundTripsAndUnmatchKeepsLocalWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = WorkID()
        let record = LocalMatchRecord(localWorkID: id, status: .confirmed, malID: 123,
                                      remoteListing: ListingKey(sourceId: "src", mangaId: "m"),
                                      evidence: [LocalMatchEvidence(titleSpelling: "Title", candidateID: "123", score: 1)])
        LocalMatchStore(directory: directory).save(record)
        let reloaded = LocalMatchStore(directory: directory)
        XCTAssertEqual(reloaded.record(for: id), record)
        reloaded.markUnmatched(workID: id)
        let tombstone = LocalMatchStore(directory: directory).record(for: id)
        XCTAssertEqual(tombstone?.status, .unmatched)
        XCTAssertNil(tombstone?.malID)
        XCTAssertNil(tombstone?.remoteListing)
        XCTAssertEqual(tombstone?.localWorkID, id)
    }

    func testMissingFileReadsEmptyAndOptionalCodableDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(LocalMatchStore(directory: directory).records.isEmpty)
        let id = WorkID()
        let json = "{\"localWorkID\":{\"raw\":\"\(id.raw.uuidString)\"}}"
        let decoded = try JSONDecoder().decode(LocalMatchRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .unmatched)
        XCTAssertNil(decoded.malID)
        XCTAssertTrue(decoded.evidence.isEmpty)
    }
}
