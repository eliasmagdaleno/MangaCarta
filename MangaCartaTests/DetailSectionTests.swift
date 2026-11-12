//
//  DetailSectionTests.swift
//  MangaCartaTests
//

import XCTest
@testable import MangaCarta

final class DetailSectionTests: XCTestCase {
    func testChaptersIsAlwaysFirstAndAlwaysPresent() {
        XCTAssertEqual(DetailSectionAvailability(hasRelated: false, hasSimilar: false).sections,
                       [.chapters])
        XCTAssertEqual(DetailSectionAvailability(hasRelated: true, hasSimilar: true).sections.first,
                       .chapters)
    }

    func testEmptySectionsAreOmittedAndOrderIsFixed() {
        XCTAssertEqual(DetailSectionAvailability(hasRelated: false, hasSimilar: false).sections,
                       [.chapters])
        XCTAssertEqual(DetailSectionAvailability(hasRelated: true, hasSimilar: false).sections,
                       [.chapters, .related])
        XCTAssertEqual(DetailSectionAvailability(hasRelated: false, hasSimilar: true).sections,
                       [.chapters, .similar])
        XCTAssertEqual(DetailSectionAvailability(hasRelated: true, hasSimilar: true).sections,
                       [.chapters, .related, .similar])
    }

    func testPickerIsHiddenWithOnlyChapters() {
        XCTAssertFalse(DetailSectionAvailability(hasRelated: false, hasSimilar: false).showsPicker)
        XCTAssertTrue(DetailSectionAvailability(hasRelated: true, hasSimilar: false).showsPicker)
    }

    func testResolveFallsBackToChaptersAndKeepsAvailableSelection() {
        let availability = DetailSectionAvailability(hasRelated: true, hasSimilar: false)
        XCTAssertEqual(availability.resolve(.similar), .chapters)
        XCTAssertEqual(availability.resolve(.related), .related)
        XCTAssertEqual(availability.resolve(.chapters), .chapters)
    }
}
