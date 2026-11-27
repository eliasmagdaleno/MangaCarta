import Foundation

enum LocalMatchStatus: String, Codable { case confirmed, rejected, unmatched }

struct LocalMatchEvidence: Codable, Equatable {
    var titleSpelling: String
    var candidateID: String
    var score: Double
    var sourceID: String?

    init(titleSpelling: String = "", candidateID: String = "", score: Double = 0, sourceID: String? = nil) {
        self.titleSpelling = titleSpelling; self.candidateID = candidateID
        self.score = score; self.sourceID = sourceID
    }

    private enum CodingKeys: String, CodingKey { case titleSpelling, candidateID, score, sourceID }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleSpelling = try c.decodeIfPresent(String.self, forKey: .titleSpelling) ?? ""
        candidateID = try c.decodeIfPresent(String.self, forKey: .candidateID) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
    }
}

struct LocalMatchRecord: Codable, Equatable {
    var localWorkID: WorkID
    var confirmedAt: Date
    var status: LocalMatchStatus
    var malID: Int?
    var aniListID: Int?
    var remoteListing: ListingKey?
    var evidence: [LocalMatchEvidence]

    init(localWorkID: WorkID, confirmedAt: Date = Date(), status: LocalMatchStatus,
         malID: Int? = nil, aniListID: Int? = nil, remoteListing: ListingKey? = nil,
         evidence: [LocalMatchEvidence] = []) {
        self.localWorkID = localWorkID; self.confirmedAt = confirmedAt; self.status = status
        self.malID = malID; self.aniListID = aniListID; self.remoteListing = remoteListing; self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey { case localWorkID, confirmedAt, status, malID, aniListID, remoteListing, evidence }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localWorkID = try c.decode(WorkID.self, forKey: .localWorkID)
        confirmedAt = try c.decodeIfPresent(Date.self, forKey: .confirmedAt) ?? .distantPast
        status = try c.decodeIfPresent(LocalMatchStatus.self, forKey: .status) ?? .unmatched
        malID = try c.decodeIfPresent(Int.self, forKey: .malID)
        aniListID = try c.decodeIfPresent(Int.self, forKey: .aniListID)
        remoteListing = try c.decodeIfPresent(ListingKey.self, forKey: .remoteListing)
        evidence = try c.decodeIfPresent([LocalMatchEvidence].self, forKey: .evidence) ?? []
    }
}
