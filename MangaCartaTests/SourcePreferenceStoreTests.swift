//
//  SourcePreferenceStoreTests.swift
//  MangaCartaTests
//
//  Two preferences that compose: a primary source the reader picks once, and a
//  per-Work choice that overrides it when they deliberately switch on a title.
//

import XCTest
@testable import MangaCarta

@MainActor
final class SourcePreferenceStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = makeTestDefaults("SourcePreferenceStoreTests")
    }

    override func tearDown() async throws {
    }

    private let workID = WorkID()
    private let weebCentral = ListingKey(sourceId: "weebcentral", mangaId: "one-piece")

    /// Until the reader says otherwise there is no preference — and `nil` is the
    /// answer, not a guessed source. The router already has a sensible default and
    /// inventing one here would put the same decision in two places.
    func testNoPrimarySourceUntilOneIsChosen() {
        let store = SourcePreferenceStore(defaults: defaults)

        XCTAssertNil(store.primarySourceId)
    }

    func testChosenPrimarySourceIsRemembered() {
        let store = SourcePreferenceStore(defaults: defaults)

        store.primarySourceId = "weebcentral"

        XCTAssertEqual(SourcePreferenceStore(defaults: defaults).primarySourceId,
                       "weebcentral")
    }

    /// The per-title override. Deliberately switching source on one manga is a
    /// statement about that manga, and it has to outlive the visit or it reads as
    /// the app forgetting.
    func testAPerWorkChoiceSurvivesARelaunch() {
        let store = SourcePreferenceStore(defaults: defaults)

        store.choose(weebCentral, for: workID)

        XCTAssertEqual(SourcePreferenceStore(defaults: defaults).choice(for: workID),
                       weebCentral)
    }

    /// Choosing on one Work says nothing about another. The global preference is
    /// the place for "always prefer this source"; a per-title pick is narrower on
    /// purpose.
    func testAPerWorkChoiceDoesNotLeakToOtherWorks() {
        let store = SourcePreferenceStore(defaults: defaults)

        store.choose(weebCentral, for: workID)

        XCTAssertNil(store.choice(for: WorkID()))
    }

    /// A reader who switches back to the ranked pick is telling us to stop
    /// overriding, not to pin the ranking's current answer — those differ the
    /// moment a better Listing appears.
    func testClearingAChoiceReturnsTheWorkToTheRanking() {
        let store = SourcePreferenceStore(defaults: defaults)
        store.choose(weebCentral, for: workID)

        store.clearChoice(for: workID)

        XCTAssertNil(store.choice(for: workID))
    }
}
