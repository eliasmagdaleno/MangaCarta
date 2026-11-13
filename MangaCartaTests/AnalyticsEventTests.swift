import CoreFoundation
import Foundation
import XCTest
@testable import MangaCarta

final class AnalyticsEventTests: XCTestCase {
    private let install = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testWireFormHasOnlyClosedStrings() throws {
        let manga = Manga(id: "listing-abc-123", sourceId: "zz-sensitive-source", title: "Zyxwv Secret Title",
                          description: "", status: "", year: nil, coverURL: nil, malId: 21,
                          altTitles: nil, contentRating: "safe")
        let work = Work(id: WorkID(), displayTitle: manga.title, knownTitles: [manga.title],
                        externalIds: ExternalIDs(mal: 21, anilist: 30013), listings: [ListingKey(manga)])
        let ids = try XCTUnwrap(AnalyticsEligibility.catalogueIDs(work: work, manga: manga))
        var envelopes: [[String: Any]] = []
        for event in allEvents(ids: ids) {
            let data = try JSONEncoder().encode(AnalyticsEnvelope(
                install: install, date: Date(timeIntervalSince1970: 1_794_000_000),
                app: "1.0 (42)", event: event
            ))
            envelopes.append(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }
        let allowedKeys = Set([
            "v", "install", "day", "app", "name", "ids", "mal", "anilist", "progress",
            "rank", "reason", "count", "from", "to", "mode", "files", "adult", "key", "on", "value"
        ])
        let closedStrings = Set(allEvents(ids: ids).flatMap { event -> [String] in
            [event.name] + ForYouReasonKind.allCases.map(\.rawValue) + ReaderModeKind.allCases.map(\.rawValue) +
                ImportFileBucket.allCases.map(\.rawValue) + AnalyticsSettingKey.allCases.map(\.rawValue) +
                [AdultClassification.none.rawValue, AdultClassification.mixed.rawValue, AdultClassification.adultOnly.rawValue]
        } + [install.uuidString, AnalyticsEnvelope.day(for: Date(timeIntervalSince1970: 1_794_000_000)), "1.0 (42)"])

        for envelope in envelopes {
            XCTAssertTrue(Set(envelope.keys).isSubset(of: allowedKeys))
            var strings: [String] = []
            collectStrings(envelope, into: &strings)
            XCTAssertFalse(strings.contains("Zyxwv Secret Title"))
            XCTAssertFalse(strings.contains("zz-sensitive-source"))
            XCTAssertFalse(strings.contains("listing-abc-123"))
            XCTAssertTrue(strings.allSatisfy(closedStrings.contains), "Unexpected wire string: \(strings)")
        }
    }

    func testEveryCaseRoundTrips() throws {
        for event in allEvents(ids: CatalogueIDs(mal: 21, anilist: 30013)) {
            let envelope = AnalyticsEnvelope(install: install, date: Date(), app: "app", event: event)
            let data = try JSONEncoder().encode(envelope)
            XCTAssertEqual(try JSONDecoder().decode(AnalyticsEnvelope.self, from: data), envelope)
        }
    }

    func testDayIsUTC() {
        let date = ISO8601DateFormatter().date(from: "2026-11-12T23:30:00-08:00")!
        XCTAssertEqual(AnalyticsEnvelope.day(for: date), "2026-11-13")
    }

    func allEvents(ids: CatalogueIDs) -> [AnalyticsEvent] {
        [
            .workSaved(ids), .workUnsaved(ids), .chapterCompleted(ids, progress: 12),
            .recNotInterested(ids), .recMoreLikeThis(ids), .forYouOpened(ids, rank: 2, reason: .tag),
            .forYouShown(count: 6), .mltOpened(from: ids, to: CatalogueIDs(mal: 30, anilist: nil)),
            .appActive, .readerOpened(.rtl), .searchUsed, .localImportFinished(.twoToNine),
            .sourceInstalled(.mixed), .settingChanged(.notifications, .on(true)),
            .settingChanged(.malSync, .on(false)), .settingChanged(.readingModeDefault, .readingMode(.vertical)),
            .analyticsEnabled
        ].map(exhaustive)
    }

    private func exhaustive(_ event: AnalyticsEvent) -> AnalyticsEvent {
        switch event {
        case .workSaved, .workUnsaved, .chapterCompleted, .recNotInterested, .recMoreLikeThis,
             .forYouOpened, .forYouShown, .mltOpened, .appActive, .readerOpened, .searchUsed,
             .localImportFinished, .sourceInstalled, .settingChanged, .analyticsEnabled:
            return event
        }
    }

    func testSettingOnIsAJSONBoolean() throws {
        let event = AnalyticsEvent.settingChanged(.notifications, .on(true))
        let data = try JSONEncoder().encode(AnalyticsEnvelope(install: install, date: Date(), app: "app", event: event))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try XCTUnwrap(object["on"] as CFTypeRef?)
        XCTAssertEqual(CFGetTypeID(value), CFBooleanGetTypeID())
    }

    private func collectStrings(_ value: Any, into result: inout [String]) {
        if let string = value as? String {
            result.append(string)
        } else if let dictionary = value as? [String: Any] {
            dictionary.values.forEach { collectStrings($0, into: &result) }
        } else if let array = value as? [Any] {
            array.forEach { collectStrings($0, into: &result) }
        }
    }
}
