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

    func testSliceOneLocalMatchesFileDecodesWithoutReviewFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = WorkID()
        let legacyRecord: [String: Any] = [
            "localWorkID": try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(id)) as? [String: Any]),
            "confirmedAt": 0,
            "status": "confirmed",
            "malID": 123,
            "aniListID": NSNull(),
            "remoteListing": NSNull(),
            "evidence": []
        ]
        let payload: [String: Any] = ["version": 1, "records": [legacyRecord]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: directory.appendingPathComponent("local-matches.json"))

        let decoded = try XCTUnwrap(LocalMatchStore(directory: directory).record(for: id))
        XCTAssertEqual(decoded.status, .confirmed)
        XCTAssertEqual(decoded.originalLocalWorkID, id)
        XCTAssertNil(decoded.introducedMalID)
        XCTAssertNil(decoded.introducedAniListID)
    }
}
